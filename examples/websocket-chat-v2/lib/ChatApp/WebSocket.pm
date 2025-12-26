package ChatApp::WebSocket;

#
# WebSocket Chat Handler using PAGI::WebSocket
#
# Compare with examples/10-chat-showcase/lib/ChatApp/WebSocket.pm
# to see how PAGI::WebSocket simplifies the code:
#
# - No manual websocket.connect/accept handling (just $ws->accept)
# - No manual websocket.disconnect handling (use $ws->on_close)
# - No manual JSON encoding (use $ws->send_json, each_json)
# - Cleaner message loop (each_json instead of raw receive loop)
#

use strict;
use warnings;

use Future::AsyncAwait;
use URI::Escape qw(uri_unescape);
use IO::Async::Loop;
use IO::Async::Timer::Periodic;
use Scalar::Util qw(weaken);

use PAGI::WebSocket;

use ChatApp::State qw(
    get_session create_session update_session
    get_session_by_name set_session_connected set_session_disconnected
    cancel_disconnect_timer is_session_connected
    get_room add_room get_all_rooms
    add_user_to_room remove_user_from_room get_room_users
    add_message get_room_messages get_messages_since
    sanitize_username sanitize_room_name set_event_loop
);

sub handler {
    return async sub {
        my ($scope, $receive, $send) = @_;

        # Create WebSocket wrapper - handles all protocol details
        my $ws = PAGI::WebSocket->new($scope, $receive, $send);

        # Set up the event loop reference for State module
        my $loop = IO::Async::Loop->new;
        set_event_loop($loop);

        # Extract session info from query string
        my $qs = $scope->{query_string} // '';
        my ($session_id) = $qs =~ /(?:^|&)session=([^&]*)/;
        my ($raw_name) = $qs =~ /(?:^|&)name=([^&]*)/;
        my ($last_msg_id) = $qs =~ /(?:^|&)lastMsgId=(\d+)/;

        $session_id = uri_unescape($session_id // '');
        $raw_name = uri_unescape($raw_name // '');
        $last_msg_id = int($last_msg_id // 0);

        # Accept connection - one line vs manual protocol handling
        await $ws->accept;

        # Check if this is a resume (existing session)
        my $session = $session_id ? get_session($session_id) : undef;

        if ($session) {
            # Resume existing session
            set_session_connected($session_id, sub { $ws->send_json($_[0]) });

            # Send resumed message with missed messages
            my %missed_messages;
            for my $room_name (keys %{$session->{rooms}}) {
                $missed_messages{$room_name} = get_messages_since($room_name, $last_msg_id);
            }

            await $ws->send_json({
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

            $session = create_session($session_id, $username, sub { $ws->send_json($_[0]) });

            await $ws->send_json({
                type       => 'connected',
                session_id => $session_id,
                name       => $username,
                rooms      => [sort keys %{get_all_rooms()}],
            });

            # Auto-join general room
            await _join_room($ws, $session_id, 'general');
        }

        # Set up ping timer
        my $connected = 1;
        my $weak_ws = $ws;
        weaken($weak_ws);

        my $ping_timer = IO::Async::Timer::Periodic->new(
            interval => 25,
            on_tick  => sub {
                return unless $connected && $weak_ws;
                eval { $weak_ws->try_send_json({ type => 'ping', ts => time() }) };
            },
        );
        $loop->add($ping_timer);
        $ping_timer->start;

        # Register cleanup callback - runs on ANY disconnect
        # This replaces manual disconnect handling in the message loop
        $ws->on_close(sub {
            my ($code, $reason) = @_;
            $connected = 0;
            $ping_timer->stop;
            $loop->remove($ping_timer);

            # Broadcast leave callback for grace period
            my $broadcast_leave = sub {
                my ($room_name, $username) = @_;
                my $room_users = get_room_users($room_name);
                for my $other (@$room_users) {
                    my $other_session = get_session($other->{id});
                    next unless $other_session && $other_session->{send_cb};
                    eval {
                        $other_session->{send_cb}->({
                            type  => 'user_left',
                            room  => $room_name,
                            user  => $username,
                            users => get_room_users($room_name),
                        });
                    };
                }
            };

            set_session_disconnected($session_id, $broadcast_leave);
        });

        # Message loop - each_json handles JSON decode and disconnect
        # Compare to raw: while(1) { my $event = await $receive->(); ... }
        await $ws->each_json(async sub {
            my ($msg) = @_;
            await _handle_message($ws, $session_id, $msg);
        });
    };
}

sub _generate_session_id {
    require Digest::SHA;
    return Digest::SHA::sha256_hex(time() . $$ . rand());
}

async sub _handle_message {
    my ($ws, $session_id, $msg) = @_;

    my $session = get_session($session_id);
    return unless $session;

    my $type = $msg->{type} // 'message';

    if ($type eq 'message') {
        await _handle_chat_message($ws, $session_id, $msg);
    }
    elsif ($type eq 'join') {
        await _join_room($ws, $session_id, $msg->{room});
    }
    elsif ($type eq 'leave') {
        await _leave_room($ws, $session_id, $msg->{room});
    }
    elsif ($type eq 'typing') {
        await _handle_typing($session_id, $msg);
    }
    elsif ($type eq 'pm') {
        await _handle_private_message($ws, $session_id, $msg);
    }
    elsif ($type eq 'set_nick') {
        await _handle_nick_change($ws, $session_id, $msg);
    }
    elsif ($type eq 'get_rooms') {
        await _send_room_list($ws, $session_id);
    }
    elsif ($type eq 'get_users') {
        await _send_user_list($ws, $session_id, $msg->{room});
    }
    elsif ($type eq 'get_history') {
        await _send_history($ws, $session_id, $msg->{room});
    }
    elsif ($type eq 'ping') {
        update_session($session_id, { last_seen => time() });
        await $ws->send_json({ type => 'pong', ts => $msg->{ts} });
    }
    elsif ($type eq 'pong') {
        update_session($session_id, { last_seen => time() });
    }
}

async sub _handle_chat_message {
    my ($ws, $session_id, $msg) = @_;

    my $session = get_session($session_id) or return;
    my $room_name = $msg->{room} // 'general';
    my $text = $msg->{text} // '';

    unless ($session->{rooms}{$room_name}) {
        return await $ws->send_json({
            type    => 'error',
            message => "You are not in room: $room_name",
        });
    }

    # Handle slash commands
    if ($text =~ m{^/(\w+)(?:\s+(.*))?$}) {
        return await _handle_command($ws, $session_id, $1, $2, $room_name);
    }

    return unless length $text;

    my $stored = add_message($room_name, $session->{name}, $text, 'message');
    update_session($session_id, { last_message_id => $stored->{id} });

    # Clear typing indicator
    if ($session->{typing_in}) {
        update_session($session_id, { typing_in => undef });
        await _broadcast_to_room($room_name, {
            type   => 'typing',
            room   => $room_name,
            user   => $session->{name},
            typing => 0,
        }, $session_id);
    }

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
    my ($ws, $session_id, $cmd, $args, $room_name) = @_;

    my $session = get_session($session_id) or return;
    $args //= '';

    if ($cmd eq 'help') {
        await $ws->send_json({
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
        await _send_room_list($ws, $session_id);
    }
    elsif ($cmd eq 'users') {
        await _send_user_list($ws, $session_id, $room_name);
    }
    elsif ($cmd eq 'join' && $args) {
        my $new_room = sanitize_room_name($args);
        await _join_room($ws, $session_id, $new_room);
    }
    elsif ($cmd eq 'leave') {
        await _leave_room($ws, $session_id, $room_name);
    }
    elsif ($cmd eq 'pm' && $args =~ /^(\S+)\s+(.+)$/) {
        await _handle_private_message($ws, $session_id, { to => $1, text => $2 });
    }
    elsif ($cmd eq 'nick' && $args) {
        await _handle_nick_change($ws, $session_id, { name => $args });
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
        await $ws->send_json({
            type    => 'error',
            message => "Unknown command: /$cmd. Type /help for available commands.",
        });
    }
}

async sub _join_room {
    my ($ws, $session_id, $room_name) = @_;

    my $session = get_session($session_id) or return;
    $room_name = sanitize_room_name($room_name);

    if ($session->{rooms}{$room_name}) {
        return await $ws->send_json({
            type    => 'error',
            message => "You are already in room: $room_name",
        });
    }

    add_user_to_room($session_id, $room_name);

    await $ws->send_json({
        type    => 'joined',
        room    => $room_name,
        history => get_room_messages($room_name, 50),
        users   => get_room_users($room_name),
    });

    await _broadcast_to_room($room_name, {
        type  => 'user_joined',
        room  => $room_name,
        user  => $session->{name},
        users => get_room_users($room_name),
    }, $session_id);
}

async sub _leave_room {
    my ($ws, $session_id, $room_name) = @_;

    my $session = get_session($session_id) or return;

    if ($room_name eq 'general') {
        return await $ws->send_json({
            type    => 'error',
            message => "You cannot leave the general room",
        });
    }

    unless ($session->{rooms}{$room_name}) {
        return await $ws->send_json({
            type    => 'error',
            message => "You are not in room: $room_name",
        });
    }

    remove_user_from_room($session_id, $room_name);

    await $ws->send_json({
        type => 'left',
        room => $room_name,
    });

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
    my ($ws, $session_id, $msg) = @_;

    my $session = get_session($session_id) or return;
    my $to_name = $msg->{to} // '';
    my $text = $msg->{text} // '';

    return unless length $to_name && length $text;

    my $target = get_session_by_name($to_name);

    unless ($target) {
        return await $ws->send_json({
            type    => 'error',
            message => "User not found: $to_name",
        });
    }

    if ($target->{send_cb}) {
        eval {
            $target->{send_cb}->({
                type => 'pm',
                from => $session->{name},
                text => $text,
                ts   => time(),
            });
        };
    }

    await $ws->send_json({
        type => 'pm_sent',
        to   => $to_name,
        text => $text,
        ts   => time(),
    });
}

async sub _handle_nick_change {
    my ($ws, $session_id, $msg) = @_;

    my $session = get_session($session_id) or return;
    my $new_name = sanitize_username($msg->{name} // '');
    my $old_name = $session->{name};

    return if $new_name eq $old_name;

    update_session($session_id, { name => $new_name });

    await $ws->send_json({
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
    my ($ws, $session_id) = @_;

    my $rooms = get_all_rooms();
    await $ws->send_json({
        type  => 'room_list',
        rooms => [
            map {
                { name => $_->{name}, users => scalar(keys %{$_->{users}}) }
            }
            sort { $a->{name} cmp $b->{name} }
            values %$rooms
        ],
    });
}

async sub _send_user_list {
    my ($ws, $session_id, $room_name) = @_;

    my $users = get_room_users($room_name);
    await $ws->send_json({
        type  => 'user_list',
        room  => $room_name,
        users => $users,
    });
}

async sub _send_history {
    my ($ws, $session_id, $room_name) = @_;

    my $messages = get_room_messages($room_name, 100);
    await $ws->send_json({
        type     => 'history',
        room     => $room_name,
        messages => $messages,
    });
}

async sub _broadcast_to_room {
    my ($room_name, $data, $exclude_id) = @_;

    my $room_users = get_room_users($room_name);

    for my $room_user (@$room_users) {
        next if defined $exclude_id && $room_user->{id} eq $exclude_id;

        my $session = get_session($room_user->{id});
        next unless $session && $session->{send_cb};

        eval { $session->{send_cb}->($data) };
    }
}

1;

__END__

# NAME

ChatApp::WebSocket - WebSocket chat handler using PAGI::WebSocket

# DESCRIPTION

This module handles WebSocket connections for real-time chat using the
PAGI::WebSocket convenience wrapper. Compare with the original at
`examples/10-chat-showcase/lib/ChatApp/WebSocket.pm` to see how
PAGI::WebSocket simplifies the code.

## Key Improvements

- **No manual protocol handling** - `$ws->accept` replaces waiting for websocket.connect and sending websocket.accept
- **Clean disconnect handling** - `$ws->on_close` callback runs on any disconnect, no need to handle websocket.disconnect in the message loop
- **JSON methods** - `$ws->send_json` and `$ws->each_json` handle encoding/decoding automatically
- **try_send_json** - Safe send that returns false on closed connection instead of throwing

# SEE ALSO

PAGI::WebSocket, examples/10-chat-showcase/lib/ChatApp/WebSocket.pm
