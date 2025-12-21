package PAGI::App::WebSocket::Broadcast;

use strict;
use warnings;
use Future::AsyncAwait;

=head1 NAME

PAGI::App::WebSocket::Broadcast - Pub/sub WebSocket broadcast

=head1 SYNOPSIS

    use PAGI::App::WebSocket::Broadcast;

    my $app = PAGI::App::WebSocket::Broadcast->new->to_app;

=cut

# Shared state for all connections
my %channels;  # channel => { clients => { id => send_cb } }
my $next_id = 1;

sub new {
    my ($class, %args) = @_;

    return bless {
        default_channel => $args{channel} // 'default',
        echo_self       => $args{echo_self} // 0,
    }, $class;
}

sub to_app {
    my ($self) = @_;

    my $default_channel = $self->{default_channel};
    my $echo_self = $self->{echo_self};

    return async sub  {
        my ($scope, $receive, $send) = @_;
        die "Unsupported scope type: $scope->{type}" if $scope->{type} ne 'websocket';

        # Accept the connection
        await $send->({ type => 'websocket.accept' });

        my $client_id = $next_id++;
        my $channel = $default_channel;

        # Register client
        $channels{$channel} //= { clients => {} };
        $channels{$channel}{clients}{$client_id} = $send;

        eval {
            while (1) {
                my $event = await $receive->();

                if ($event->{type} eq 'websocket.receive') {
                    my $message = $event->{text} // $event->{bytes};
                    my $is_text = exists $event->{text};

                    # Broadcast to all clients in the channel
                    my $clients = $channels{$channel}{clients};
                    for my $id (keys %$clients) {
                        next if $id eq $client_id && !$echo_self;
                        my $client_send = $clients->{$id};
                        eval {
                            if ($is_text) {
                                await $client_send->({
                                    type => 'websocket.send',
                                    text => $message,
                                });
                            } else {
                                await $client_send->({
                                    type => 'websocket.send',
                                    bytes => $message,
                                });
                            }
                        };
                        # Remove dead clients
                        if ($@) {
                            delete $clients->{$id};
                        }
                    }
                } elsif ($event->{type} eq 'websocket.disconnect') {
                    last;
                }
            }
        };

        # Cleanup
        delete $channels{$channel}{clients}{$client_id};
        delete $channels{$channel} if !keys %{$channels{$channel}{clients}};
    };
}

# Class method to broadcast to a channel
sub broadcast {
    my ($class, $channel, $message, %opts) = @_;

    return unless $channels{$channel};

    my $is_text = !$opts{binary};
    my $clients = $channels{$channel}{clients};

    for my $id (keys %$clients) {
        my $send = $clients->{$id};
        eval {
            if ($is_text) {
                $send->({ type => 'websocket.send', text => $message });
            } else {
                $send->({ type => 'websocket.send', bytes => $message });
            }
        };
        delete $clients->{$id} if $@;
    }
}

# Get connected client count
sub client_count {
    my ($class, $channel) = @_;
    $channel //= undef;

    if ($channel) {
        return 0 unless $channels{$channel};
        return scalar keys %{$channels{$channel}{clients}};
    }
    my $total = 0;
    $total += scalar keys %{$_->{clients}} for values %channels;
    return $total;
}

1;

__END__

=head1 DESCRIPTION

WebSocket broadcast/pub-sub server. Messages from any client are
broadcast to all other connected clients in the same channel.

=head1 OPTIONS

=over 4

=item * C<channel> - Default channel name (default: 'default')

=item * C<echo_self> - Whether to echo messages back to sender (default: 0)

=back

=head1 CLASS METHODS

=head2 broadcast($channel, $message, %opts)

Broadcast a message to all clients in a channel from server-side code.

=head2 client_count($channel)

Get number of connected clients, optionally filtered by channel.

=cut
