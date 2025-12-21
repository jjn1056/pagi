package PAGI::App::WebSocket::Chat;

use strict;
use warnings;
use Future::AsyncAwait;
use JSON::PP ();

=head1 NAME

PAGI::App::WebSocket::Chat - Multi-room chat application

=head1 SYNOPSIS

    use PAGI::App::WebSocket::Chat;

    my $app = PAGI::App::WebSocket::Chat->new->to_app;

=cut

# Shared state
my %rooms;      # room => { users => { id => { send => cb, name => str } } }
my %user_rooms; # user_id => { room => 1 }
my $next_id = 1;

sub new {
    my ($class, %args) = @_;

    return bless {
        default_room => $args{default_room} // 'lobby',
        max_rooms    => $args{max_rooms} // 100,
    }, $class;
}

sub to_app {
    my ($self) = @_;

    my $default_room = $self->{default_room};
    my $max_rooms = $self->{max_rooms};

    return async sub  {
        my ($scope, $receive, $send) = @_;
        die "Unsupported scope type: $scope->{type}" if $scope->{type} ne 'websocket';

        await $send->({ type => 'websocket.accept' });

        my $user_id = $next_id++;
        my $username = "user_$user_id";
        $user_rooms{$user_id} = {};

        # Join default room
        _join_room($user_id, $username, $send, $default_room);

        # Send welcome message
        await $send->({
            type => 'websocket.send',
            text => _encode({
                type => 'welcome',
                user_id => $user_id,
                username => $username,
                room => $default_room,
            }),
        });

        eval {
            while (1) {
                my $event = await $receive->();

                if ($event->{type} eq 'websocket.receive') {
                    my $data = eval { JSON::PP::decode_json($event->{text} // '{}') } // {};
                    my $cmd = $data->{type} // 'message';

                    if ($cmd eq 'message') {
                        # Broadcast to current room(s)
                        my $msg = $data->{message} // '';
                        my $target_room = $data->{room};

                        my @target_rooms = $target_room
                            ? ($target_room)
                            : keys %{$user_rooms{$user_id}};

                        for my $room (@target_rooms) {
                            next unless $user_rooms{$user_id}{$room};
                            await _broadcast_to_room($room, {
                                type => 'message',
                                room => $room,
                                user_id => $user_id,
                                username => $username,
                                message => $msg,
                                timestamp => time(),
                            }, $user_id);
                        }
                    } elsif ($cmd eq 'join') {
                        my $room = $data->{room} // $default_room;
                        if (keys(%rooms) >= $max_rooms && !$rooms{$room}) {
                            await $send->({
                                type => 'websocket.send',
                                text => _encode({ type => 'error', message => 'Max rooms reached' }),
                            });
                        } else {
                            _join_room($user_id, $username, $send, $room);
                            await $send->({
                                type => 'websocket.send',
                                text => _encode({ type => 'joined', room => $room }),
                            });
                        }
                    } elsif ($cmd eq 'leave') {
                        my $room = $data->{room};
                        if ($room && $user_rooms{$user_id}{$room}) {
                            await _leave_room($user_id, $username, $room);
                            await $send->({
                                type => 'websocket.send',
                                text => _encode({ type => 'left', room => $room }),
                            });
                        }
                    } elsif ($cmd eq 'nick') {
                        my $new_name = $data->{username} // $username;
                        $new_name =~ s/[^\w\-]//g;
                        $new_name = substr($new_name, 0, 20) if length($new_name) > 20;

                        # Update in all rooms
                        for my $room (keys %{$user_rooms{$user_id}}) {
                            if ($rooms{$room}{users}{$user_id}) {
                                $rooms{$room}{users}{$user_id}{name} = $new_name;
                            }
                        }
                        $username = $new_name;
                        await $send->({
                            type => 'websocket.send',
                            text => _encode({ type => 'nick', username => $username }),
                        });
                    } elsif ($cmd eq 'list') {
                        my $room = $data->{room};
                        if ($room && $rooms{$room}) {
                            my @users = map { $_->{name} } values %{$rooms{$room}{users}};
                            await $send->({
                                type => 'websocket.send',
                                text => _encode({ type => 'users', room => $room, users => \@users }),
                            });
                        }
                    } elsif ($cmd eq 'rooms') {
                        my @room_list = map {
                            { name => $_, count => scalar keys %{$rooms{$_}{users}} }
                        } keys %rooms;
                        await $send->({
                            type => 'websocket.send',
                            text => _encode({ type => 'rooms', rooms => \@room_list }),
                        });
                    }
                } elsif ($event->{type} eq 'websocket.disconnect') {
                    last;
                }
            }
        };

        # Cleanup - leave all rooms
        for my $room (keys %{$user_rooms{$user_id}}) {
            eval { _leave_room($user_id, $username, $room) };
        }
        delete $user_rooms{$user_id};
    };
}

sub _encode {
    my ($data) = @_;

    return JSON::PP::encode_json($data);
}

sub _join_room {
    my ($user_id, $username, $send, $room) = @_;

    $rooms{$room} //= { users => {} };
    $rooms{$room}{users}{$user_id} = { send => $send, name => $username };
    $user_rooms{$user_id}{$room} = 1;

    # Notify others
    _broadcast_to_room($room, {
        type => 'user_joined',
        room => $room,
        user_id => $user_id,
        username => $username,
    }, $user_id);
}

async sub _leave_room {
    my ($user_id, $username, $room) = @_;

    return unless $rooms{$room};

    delete $rooms{$room}{users}{$user_id};
    delete $user_rooms{$user_id}{$room};

    # Notify others
    await _broadcast_to_room($room, {
        type => 'user_left',
        room => $room,
        user_id => $user_id,
        username => $username,
    });

    # Cleanup empty room
    delete $rooms{$room} if !keys %{$rooms{$room}{users}};
}

async sub _broadcast_to_room {
    my ($room, $data, $exclude_id) = @_;
    $exclude_id //= undef;

    return unless $rooms{$room};

    my $json = _encode($data);
    my $users = $rooms{$room}{users};

    for my $id (keys %$users) {
        next if defined $exclude_id && $id eq $exclude_id;
        eval {
            await $users->{$id}{send}->({
                type => 'websocket.send',
                text => $json,
            });
        };
        delete $users->{$id} if $@;
    }
}

1;

__END__

=head1 DESCRIPTION

Multi-room WebSocket chat application. Supports joining/leaving rooms,
setting nicknames, and listing users and rooms.

=head1 OPTIONS

=over 4

=item * C<default_room> - Room to join on connect (default: 'lobby')

=item * C<max_rooms> - Maximum number of rooms allowed (default: 100)

=back

=head1 MESSAGE PROTOCOL

All messages are JSON objects with a C<type> field.

=head2 Client Messages

=over 4

=item * C<{ type: "message", message: "...", room: "..." }> - Send message

=item * C<{ type: "join", room: "..." }> - Join a room

=item * C<{ type: "leave", room: "..." }> - Leave a room

=item * C<{ type: "nick", username: "..." }> - Change nickname

=item * C<{ type: "list", room: "..." }> - List users in room

=item * C<{ type: "rooms" }> - List all rooms

=back

=head2 Server Messages

=over 4

=item * C<welcome> - Initial connection info

=item * C<message> - Chat message

=item * C<user_joined> - User joined room

=item * C<user_left> - User left room

=item * C<joined/left> - Confirmation of join/leave

=item * C<users> - User list response

=item * C<rooms> - Room list response

=item * C<error> - Error message

=back

=cut
