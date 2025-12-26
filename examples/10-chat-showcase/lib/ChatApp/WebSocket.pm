package ChatApp::WebSocket;

use strict;
use warnings;

use Future::AsyncAwait;
use JSON::MaybeXS;
use URI::Escape qw(uri_unescape);
use IO::Async::Loop;
use IO::Async::Timer::Periodic;
use Scalar::Util qw(weaken);

use ChatApp::State qw(
    get_session create_session update_session
    get_session_by_name set_session_connected set_session_disconnected
    cancel_disconnect_timer is_session_connected
    get_room add_room get_all_rooms
    add_user_to_room remove_user_from_room get_room_users
    add_message get_room_messages get_messages_since
    sanitize_username sanitize_room_name set_event_loop
);

my $JSON = JSON::MaybeXS->new->utf8->allow_nonref;

sub handler {
    return async sub  {
        my ($scope, $receive, $send) = @_;
        # Wait for connection event
        my $event = await $receive->();
        return unless $event->{type} eq 'websocket.connect';

        # Set up the event loop reference for State module
        my $loop = IO::Async::Loop->new;
        set_event_loop($loop);

        # Extract session ID and username from query string
        my $qs = $scope->{query_string} // '';
        my ($session_id) = $qs =~ /(?:^|&)session=([^&]*)/;
        my ($raw_name) = $qs =~ /(?:^|&)name=([^&]*)/;
        my ($last_msg_id) = $qs =~ /(?:^|&)lastMsgId=(\d+)/;

        $session_id = uri_unescape($session_id // '');
        $raw_name = uri_unescape($raw_name // '');
        $last_msg_id = int($last_msg_id // 0);

        # Accept connection
        await $send->({ type => 'websocket.accept' });

        # Check if this is a resume (existing session)
        my $session = $session_id ? get_session($session_id) : undef;
        my $is_resume = 0;

        if ($session) {
            # Resume existing session
            $is_resume = 1;
            set_session_connected($session_id, $send);

            # Send resumed message with missed messages
            my %missed_messages;
            for my $room_name (keys %{$session->{rooms}}) {
                $missed_messages{$room_name} = get_messages_since($room_name, $last_msg_id);
            }

            await _send_json($send, {
                type           => 'resumed',
                session_id     => $session_id,
                name           => $session->{name},
                rooms          => [keys %{$session->{rooms}}],
                missedMessages => \%missed_messages,
            });
        }
        else {
            # New session
            my $username = sanitize_username($raw_name || 'Anonymous');
            $session_id ||= _generate_session_id();

            $session = create_session($session_id, $username, $send);

            # Send welcome message
            await _send_json($send, {
                type       => 'connected',
                session_id => $session_id,
                name       => $username,
                rooms      => [sort keys %{get_all_rooms()}],
            });

            # Auto-join general room
            await _join_room($session_id, 'general', $send);
        }

        # Set up server-side ping timer
        my $connected = 1;
        my $weak_send = $send;
        weaken($weak_send);

        my $ping_timer = IO::Async::Timer::Periodic->new(
            interval => 25,  # Ping every 25 seconds (under typical 30s proxy timeout)
            on_tick  => sub {
                return unless $connected && $weak_send;
                eval {
                    $weak_send->({
                        type => 'websocket.send',
                        text => $JSON->encode({ type => 'ping', ts => time() }),
                    });
                };
            },
        );
        $loop->add($ping_timer);
        $ping_timer->start;

        # Create broadcast callback for disconnect handling
        my $broadcast_leave = sub  {
        my ($room_name, $username) = @_;
            my $room_users = get_room_users($room_name);
            for my $other (@$room_users) {
                my $other_session = get_session($other->{id});
                next unless $other_session && $other_session->{send_cb};
                eval {
                    _send_json_sync($other_session->{send_cb}, {
                        type  => 'user_left',
                        room  => $room_name,
                        user  => $username,
                        users => get_room_users($room_name),
                    });
                };
            }
        };

        # Message loop
        eval {
            while (1) {
                my $event = await $receive->();

                if ($event->{type} eq 'websocket.receive') {
                    if (defined $event->{text}) {
                        await _handle_message($session_id, $event->{text}, $send);
                    }
                }
                elsif ($event->{type} eq 'websocket.disconnect') {
                    last;
                }
            }
        };
        my $error = $@;

        # Cleanup
        $connected = 0;
        $ping_timer->stop;
        $loop->remove($ping_timer);

        # Start grace period (don't immediately broadcast "left")
        set_session_disconnected($session_id, $broadcast_leave);

        die $error if $error && $error !~ /disconnect|closed/i;
    };
}

sub _generate_session_id {
    require Digest::SHA;
    return Digest::SHA::sha256_hex(time() . $$ . rand());
}

async sub _handle_message {
    my ($session_id, $text, $send) = @_;

    my $session = get_session($session_id);
    return unless $session;

    my $msg = eval { $JSON->decode($text) };
    return unless $msg && ref $msg eq 'HASH';

    my $type = $msg->{type} // 'message';

    if ($type eq 'message') {
        await _handle_chat_message($session_id, $msg, $send);
    }
    elsif ($type eq 'join') {
        await _join_room($session_id, $msg->{room}, $send);
    }
    elsif ($type eq 'leave') {
        await _leave_room($session_id, $msg->{room}, $send);
    }
    elsif ($type eq 'typing') {
        await _handle_typing($session_id, $msg);
    }
    elsif ($type eq 'pm') {
        await _handle_private_message($session_id, $msg, $send);
    }
    elsif ($type eq 'set_nick') {
        await _handle_nick_change($session_id, $msg, $send);
    }
    elsif ($type eq 'get_rooms') {
        await _send_room_list($session_id, $send);
    }
    elsif ($type eq 'get_users') {
        await _send_user_list($session_id, $msg->{room}, $send);
    }
    elsif ($type eq 'get_history') {
        await _send_history($session_id, $msg->{room}, $send);
    }
    elsif ($type eq 'ping') {
        # Client heartbeat - respond with pong
        update_session($session_id, { last_seen => time() });
        await _send_json($send, { type => 'pong', ts => $msg->{ts} });
    }
    elsif ($type eq 'pong') {
        # Response to our server ping - just update last_seen
        update_session($session_id, { last_seen => time() });
    }
}

async sub _handle_chat_message {
    my ($session_id, $msg, $send) = @_;

    my $session = get_session($session_id) or return;
    my $room_name = $msg->{room} // 'general';
    my $text = $msg->{text} // '';

    # Validate user is in room
    unless ($session->{rooms}{$room_name}) {
        return await _send_json($send, {
            type    => 'error',
            message => "You are not in room: $room_name",
        });
    }

    # Handle slash commands
    if ($text =~ m{^/(\w+)(?:\s+(.*))?$}) {
        return await _handle_command($session_id, $1, $2, $room_name, $send);
    }

    # Empty messages ignored
    return unless length $text;

    # Store message
    my $stored = add_message($room_name, $session->{name}, $text, 'message');

    # Update session's last message ID
    update_session($session_id, { last_message_id => $stored->{id} });

    # Clear typing indicator and notify room
    if ($session->{typing_in}) {
        update_session($session_id, { typing_in => undef });
        await _broadcast_to_room($room_name, {
            type   => 'typing',
            room   => $room_name,
            user   => $session->{name},
            typing => 0,
        }, $session_id);
    }

    # Broadcast message to room
    await _broadcast_to_room($room_name, {
        type => 'message',
        room => $room_name,
        from => $session->{name},
        text => $text,
        ts   => $stored->{ts},
        id   => $stored->{id},
    });
}

async sub _handle_command {
    my ($session_id, $cmd, $args, $room_name, $send) = @_;

    my $session = get_session($session_id) or return;
    $args //= '';

    if ($cmd eq 'help') {
        await _send_json($send, {
            type    => 'system',
            room    => $room_name,
            text    => "Available commands:\n" .
                       "/help - Show this help\n" .
                       "/rooms - List all rooms\n" .
                       "/users - List users in current room\n" .
                       "/join <room> - Join or create a room\n" .
                       "/leave - Leave current room\n" .
                       "/pm <user> <message> - Send private message\n" .
                       "/nick <name> - Change your nickname\n" .
                       "/me <action> - Send action message",
        });
    }
    elsif ($cmd eq 'rooms') {
        await _send_room_list($session_id, $send);
    }
    elsif ($cmd eq 'users') {
        await _send_user_list($session_id, $room_name, $send);
    }
    elsif ($cmd eq 'join' && $args) {
        my $new_room = sanitize_room_name($args);
        await _join_room($session_id, $new_room, $send);
    }
    elsif ($cmd eq 'leave') {
        await _leave_room($session_id, $room_name, $send);
    }
    elsif ($cmd eq 'pm' && $args =~ /^(\S+)\s+(.+)$/) {
        await _handle_private_message($session_id, { to => $1, text => $2 }, $send);
    }
    elsif ($cmd eq 'nick' && $args) {
        await _handle_nick_change($session_id, { name => $args }, $send);
    }
    elsif ($cmd eq 'me' && $args) {
        my $action_text = "* $session->{name} $args";
        my $stored = add_message($room_name, $session->{name}, $action_text, 'action');
        await _broadcast_to_room($room_name, {
            type => 'action',
            room => $room_name,
            from => $session->{name},
            text => $action_text,
            ts   => $stored->{ts},
            id   => $stored->{id},
        });
    }
    else {
        await _send_json($send, {
            type    => 'error',
            message => "Unknown command: /$cmd. Type /help for available commands.",
        });
    }
}

async sub _join_room {
    my ($session_id, $room_name, $send) = @_;

    my $session = get_session($session_id) or return;
    $room_name = sanitize_room_name($room_name);

    # Already in room?
    if ($session->{rooms}{$room_name}) {
        return await _send_json($send, {
            type    => 'error',
            message => "You are already in room: $room_name",
        });
    }

    # Add to room
    add_user_to_room($session_id, $room_name);

    # Send confirmation with history
    await _send_json($send, {
        type    => 'joined',
        room    => $room_name,
        history => get_room_messages($room_name, 50),
        users   => get_room_users($room_name),
    });

    # Notify others in room
    await _broadcast_to_room($room_name, {
        type  => 'user_joined',
        room  => $room_name,
        user  => $session->{name},
        users => get_room_users($room_name),
    }, $session_id);
}

async sub _leave_room {
    my ($session_id, $room_name, $send) = @_;

    my $session = get_session($session_id) or return;

    # Can't leave general
    if ($room_name eq 'general') {
        return await _send_json($send, {
            type    => 'error',
            message => "You cannot leave the general room",
        });
    }

    # Not in room?
    unless ($session->{rooms}{$room_name}) {
        return await _send_json($send, {
            type    => 'error',
            message => "You are not in room: $room_name",
        });
    }

    # Remove from room
    remove_user_from_room($session_id, $room_name);

    # Send confirmation
    await _send_json($send, {
        type => 'left',
        room => $room_name,
    });

    # Notify others in room
    await _broadcast_to_room($room_name, {
        type  => 'user_left',
        room  => $room_name,
        user  => $session->{name},
        users => get_room_users($room_name),
    });
}

async sub _handle_typing {
    my ($session_id, $msg) = @_;

    my $session = get_session($session_id) or return;
    my $room_name = $msg->{room} // 'general';
    my $typing = $msg->{typing} ? 1 : 0;

    update_session($session_id, { typing_in => $typing ? $room_name : undef });

    await _broadcast_to_room($room_name, {
        type   => 'typing',
        room   => $room_name,
        user   => $session->{name},
        typing => $typing,
    }, $session_id);
}

async sub _handle_private_message {
    my ($session_id, $msg, $send) = @_;

    my $session = get_session($session_id) or return;
    my $to_name = $msg->{to} // '';
    my $text = $msg->{text} // '';

    return unless length $to_name && length $text;

    # Find target user
    my $target = get_session_by_name($to_name);

    unless ($target) {
        return await _send_json($send, {
            type    => 'error',
            message => "User not found: $to_name",
        });
    }

    # Send to target
    if ($target->{send_cb}) {
        eval {
            await _send_json($target->{send_cb}, {
                type => 'pm',
                from => $session->{name},
                text => $text,
                ts   => time(),
            });
        };
    }

    # Confirm to sender
    await _send_json($send, {
        type => 'pm_sent',
        to   => $to_name,
        text => $text,
        ts   => time(),
    });
}

async sub _handle_nick_change {
    my ($session_id, $msg, $send) = @_;

    my $session = get_session($session_id) or return;
    my $new_name = sanitize_username($msg->{name} // '');

    my $old_name = $session->{name};

    if ($new_name eq $old_name) {
        return;
    }

    update_session($session_id, { name => $new_name });

    await _send_json($send, {
        type     => 'nick_changed',
        old_name => $old_name,
        new_name => $new_name,
    });

    for my $room_name (keys %{$session->{rooms}}) {
        add_message($room_name, 'system', "$old_name is now known as $new_name", 'system');
        await _broadcast_to_room($room_name, {
            type     => 'nick_changed',
            room     => $room_name,
            old_name => $old_name,
            new_name => $new_name,
            users    => get_room_users($room_name),
        }, $session_id);
    }
}

async sub _send_room_list {
    my ($session_id, $send) = @_;

    my $rooms = get_all_rooms();
    await _send_json($send, {
        type  => 'room_list',
        rooms => [
            map {
                {
                    name  => $_->{name},
                    users => scalar(keys %{$_->{users}}),
                }
            }
            sort { $a->{name} cmp $b->{name} }
            values %$rooms
        ],
    });
}

async sub _send_user_list {
    my ($session_id, $room_name, $send) = @_;

    my $users = get_room_users($room_name);
    await _send_json($send, {
        type  => 'user_list',
        room  => $room_name,
        users => $users,
    });
}

async sub _send_history {
    my ($session_id, $room_name, $send) = @_;

    my $messages = get_room_messages($room_name, 100);
    await _send_json($send, {
        type     => 'history',
        room     => $room_name,
        messages => $messages,
    });
}

async sub _broadcast_to_room {
    my ($room_name, $data, $exclude_id) = @_;
    $exclude_id //= undef;

    my $room_users = get_room_users($room_name);

    for my $room_user (@$room_users) {
        next if defined $exclude_id && $room_user->{id} eq $exclude_id;

        my $session = get_session($room_user->{id});
        next unless $session && $session->{send_cb};

        eval {
            await _send_json($session->{send_cb}, $data);
        };
    }
}

async sub _send_json {
    my ($send, $data) = @_;

    await $send->({
        type => 'websocket.send',
        text => $JSON->encode($data),
    });
}

sub _send_json_sync {
    my ($send, $data) = @_;

    $send->({
        type => 'websocket.send',
        text => $JSON->encode($data),
    });
}

1;

__END__

# NAME

ChatApp::WebSocket - WebSocket chat handler with session management

# DESCRIPTION

Handles WebSocket connections for real-time chat functionality.
Supports session resumption for reliable presence.

## Session Management

Clients should:
- Store sessionId in localStorage
- Send sessionId on reconnection
- Send lastMsgId for message catch-up

## Connection Parameters

- **session** - Session ID for resume
- **name** - Username (for new sessions)
- **lastMsgId** - Last received message ID (for catch-up)
