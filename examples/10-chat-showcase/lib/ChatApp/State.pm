package ChatApp::State;

use strict;
use warnings;

use Exporter 'import';
use Time::HiRes qw(time);
use Scalar::Util qw(weaken);

our @EXPORT_OK = qw(
    get_session create_session update_session remove_session
    get_session_by_name set_session_connected set_session_disconnected
    cancel_disconnect_timer is_session_connected
    get_room add_room remove_room get_all_rooms
    add_user_to_room remove_user_from_room get_room_users
    add_message get_room_messages get_messages_since
    add_sse_subscriber remove_sse_subscriber get_sse_subscribers
    add_system_event get_recent_system_events
    get_stats generate_id sanitize_username sanitize_room_name
    set_event_loop
);

# Shared state across all connections
my %sessions;        # session_id => { id, name, rooms => {}, send_cb, connected, disconnected_at, disconnect_timer, last_seen, last_message_id }
my %rooms;           # room_name => { name, users => {}, messages => [], created_at, created_by }
my %sse_subscribers; # client_id => { send_cb, last_event_id }
my @system_events;   # Recent system events for SSE catch-up
my $message_counter = 0;
my $event_counter = 0;
my $start_time = time();
my $event_loop;      # IO::Async loop reference for timers

use constant MAX_MESSAGES_PER_ROOM => 100;
use constant MAX_SYSTEM_EVENTS => 50;
use constant PRESENCE_GRACE_PERIOD => 30;  # seconds before broadcasting "user left"
use constant SESSION_EXPIRY => 86400;       # 24 hours

# Set the event loop reference (called from WebSocket handler)
sub set_event_loop {
    my ($loop) = @_;

    $event_loop = $loop;
}

# Initialize default rooms
sub init_default_rooms {
    add_room('general', 'system') unless exists $rooms{general};
    add_room('random', 'system') unless exists $rooms{random};
    add_room('help', 'system') unless exists $rooms{help};
}

# ID generation
sub generate_id {
    return sprintf("%s-%s", time(), int(rand(100000)));
}

sub sanitize_username {
    my ($name) = @_;

    $name =~ s/[^\w]/_/g;
    $name = substr($name, 0, 20);
    $name = 'User' . int(rand(1000)) if length($name) < 2;

    # Ensure uniqueness among connected sessions
    my $base = $name;
    my $suffix = 1;
    while (grep { $_->{name} eq $name && $_->{connected} } values %sessions) {
        $name = $base . $suffix++;
    }
    return $name;
}

sub sanitize_room_name {
    my ($name) = @_;

    $name =~ s/[^\w-]/_/g;
    $name = lc(substr($name, 0, 30));
    $name = 'room' . int(rand(1000)) if length($name) < 2;
    return $name;
}

# Session management (replaces user management)
sub get_session {
    my ($session_id) = @_;

    my $session = $sessions{$session_id};
    return unless $session;

    # Check for session expiry
    if (!$session->{connected} && $session->{disconnected_at}) {
        if (time() - $session->{disconnected_at} > SESSION_EXPIRY) {
            _expire_session($session_id);
            return;
        }
    }

    return $session;
}

sub get_session_by_name {
    my ($name) = @_;

    for my $session (values %sessions) {
        return $session if $session->{name} eq $name && $session->{connected};
    }
    return;
}

sub create_session {
    my ($session_id, $name, $send_cb) = @_;

    # Check if session already exists (resume case)
    if (my $existing = $sessions{$session_id}) {
        # This is a resume - update the send callback
        $existing->{send_cb} = $send_cb;
        $existing->{connected} = 1;
        $existing->{last_seen} = time();
        delete $existing->{disconnected_at};

        # Cancel any pending disconnect timer
        if ($existing->{disconnect_timer}) {
            $existing->{disconnect_timer}->stop;
            $event_loop->remove($existing->{disconnect_timer}) if $event_loop;
            delete $existing->{disconnect_timer};
        }

        return $existing;
    }

    # New session
    $sessions{$session_id} = {
        id              => $session_id,
        name            => $name,
        send_cb         => $send_cb,
        rooms           => {},
        connected       => 1,
        joined_at       => time(),
        last_seen       => time(),
        last_message_id => 0,
        typing_in       => undef,
    };

    add_system_event('user_connected', {
        user  => $name,
        count => scalar(grep { $_->{connected} } values %sessions),
    });

    return $sessions{$session_id};
}

sub update_session {
    my ($session_id, $updates) = @_;

    return unless $sessions{$session_id};
    $sessions{$session_id}{$_} = $updates->{$_} for keys %$updates;
    $sessions{$session_id}{last_seen} = time();
    return $sessions{$session_id};
}

sub is_session_connected {
    my ($session_id) = @_;

    my $session = $sessions{$session_id};
    return $session && $session->{connected};
}

sub set_session_connected {
    my ($session_id, $send_cb) = @_;

    my $session = $sessions{$session_id} or return;

    # Cancel any pending disconnect timer
    cancel_disconnect_timer($session_id);

    $session->{send_cb} = $send_cb;
    $session->{connected} = 1;
    $session->{last_seen} = time();
    delete $session->{disconnected_at};

    return $session;
}

sub set_session_disconnected {
    my ($session_id, $broadcast_callback) = @_;
    $broadcast_callback //= undef;

    my $session = $sessions{$session_id} or return;

    $session->{connected} = 0;
    $session->{disconnected_at} = time();
    $session->{send_cb} = undef;

    # Start grace period timer
    if ($event_loop && !$session->{disconnect_timer}) {
        require IO::Async::Timer::Countdown;

        my $timer = IO::Async::Timer::Countdown->new(
            delay     => PRESENCE_GRACE_PERIOD,
            on_expire => sub {
                # Grace period expired - user didn't reconnect
                _finalize_disconnect($session_id, $broadcast_callback);
            },
        );

        $event_loop->add($timer);
        $timer->start;
        $session->{disconnect_timer} = $timer;
    }

    return $session;
}

sub cancel_disconnect_timer {
    my ($session_id) = @_;

    my $session = $sessions{$session_id} or return;

    if ($session->{disconnect_timer}) {
        $session->{disconnect_timer}->stop;
        $event_loop->remove($session->{disconnect_timer}) if $event_loop;
        delete $session->{disconnect_timer};
    }
}

sub _finalize_disconnect {
    my ($session_id, $broadcast_callback) = @_;

    my $session = $sessions{$session_id};
    return unless $session;
    return if $session->{connected};  # User reconnected, don't finalize

    # Clean up timer reference
    delete $session->{disconnect_timer};

    my $username = $session->{name};

    # Broadcast "user left" to all rooms
    if ($broadcast_callback) {
        for my $room_name (keys %{$session->{rooms}}) {
            $broadcast_callback->($room_name, $username);
        }
    }

    # Remove from all rooms
    for my $room_name (keys %{$session->{rooms}}) {
        _remove_session_from_room($session_id, $room_name, 1);
    }

    # Remove session entirely
    delete $sessions{$session_id};

    add_system_event('user_disconnected', {
        user  => $username,
        count => scalar(grep { $_->{connected} } values %sessions),
    });
}

sub _expire_session {
    my ($session_id) = @_;

    my $session = delete $sessions{$session_id};
    return unless $session;

    # Remove from all rooms silently
    for my $room_name (keys %{$session->{rooms}}) {
        _remove_session_from_room($session_id, $room_name, 1);
    }
}

sub remove_session {
    my ($session_id) = @_;

    my $session = delete $sessions{$session_id};
    return unless $session;

    cancel_disconnect_timer($session_id);

    for my $room_name (keys %{$session->{rooms}}) {
        _remove_session_from_room($session_id, $room_name, 1);
    }

    add_system_event('user_disconnected', {
        user  => $session->{name},
        count => scalar(grep { $_->{connected} } values %sessions),
    });

    return $session;
}

# Room management
sub get_room {
    my ($name) = @_;

    return $rooms{$name};
}

sub add_room {
    my ($name, $created_by) = @_;
    $created_by //= 'system';

    return $rooms{$name} if exists $rooms{$name};

    $rooms{$name} = {
        name       => $name,
        users      => {},
        messages   => [],
        created_at => time(),
        created_by => $created_by,
    };

    add_system_event('room_created', {
        room       => $name,
        created_by => $created_by,
    });

    return $rooms{$name};
}

sub remove_room {
    my ($name) = @_;

    return if $name eq 'general';
    my $room = delete $rooms{$name};
    return unless $room;

    add_system_event('room_deleted', { room => $name });
    return $room;
}

sub get_all_rooms {
    return \%rooms;
}

sub add_user_to_room {
    my ($session_id, $room_name) = @_;

    my $session = $sessions{$session_id} or return;
    my $room = $rooms{$room_name} //= add_room($room_name, $session->{name});

    return if $room->{users}{$session_id};

    $room->{users}{$session_id} = 1;
    $session->{rooms}{$room_name} = 1;

    # Add system message to room
    add_message($room_name, 'system', "$session->{name} joined the room", 'system');

    return $room;
}

sub remove_user_from_room {
    my ($session_id, $room_name, $silent) = @_;
    $silent //= 0;

    return _remove_session_from_room($session_id, $room_name, $silent);
}

sub _remove_session_from_room {
    my ($session_id, $room_name, $silent) = @_;
    $silent //= 0;

    my $session = $sessions{$session_id};
    my $room = $rooms{$room_name};
    return unless $room;

    delete $room->{users}{$session_id};
    delete $session->{rooms}{$room_name} if $session;

    unless ($silent) {
        my $name = $session ? $session->{name} : 'Unknown';
        add_message($room_name, 'system', "$name left the room", 'system');
    }

    # Auto-delete empty non-default rooms
    if (!keys %{$room->{users}} && $room_name !~ /^(general|random|help)$/) {
        remove_room($room_name);
    }

    return $room;
}

sub get_room_users {
    my ($room_name) = @_;

    my $room = $rooms{$room_name} or return [];
    return [
        map {
            my $s = $sessions{$_};
            ($s && $s->{connected}) ? {
                id     => $s->{id},
                name   => $s->{name},
                typing => ($s->{typing_in} // '') eq $room_name
            } : ()
        }
        keys %{$room->{users}}
    ];
}

# Message management
sub add_message {
    my ($room_name, $from, $text, $type) = @_;
    $type //= 'message';

    my $room = $rooms{$room_name} or return;

    my $msg = {
        id   => ++$message_counter,
        from => $from,
        text => $text,
        type => $type,
        ts   => time(),
    };

    push @{$room->{messages}}, $msg;

    if (@{$room->{messages}} > MAX_MESSAGES_PER_ROOM) {
        shift @{$room->{messages}};
    }

    return $msg;
}

sub get_room_messages {
    my ($room_name, $limit) = @_;
    $limit //= 50;

    my $room = $rooms{$room_name} or return [];
    my @msgs = @{$room->{messages}};
    return [ @msgs > $limit ? @msgs[-$limit..-1] : @msgs ];
}

sub get_messages_since {
    my ($room_name, $since_id, $limit) = @_;
    $limit //= 100;

    my $room = $rooms{$room_name} or return [];
    my @msgs = grep { $_->{id} > $since_id } @{$room->{messages}};
    return [ @msgs > $limit ? @msgs[-$limit..-1] : @msgs ];
}

# SSE subscriber management
sub add_sse_subscriber {
    my ($id, $send_cb, $last_event_id) = @_;
    $last_event_id //= 0;

    $sse_subscribers{$id} = {
        send_cb       => $send_cb,
        last_event_id => $last_event_id,
    };
    return $sse_subscribers{$id};
}

sub remove_sse_subscriber {
    my ($id) = @_;

    return delete $sse_subscribers{$id};
}

sub get_sse_subscribers {
    return \%sse_subscribers;
}

# System events for SSE
sub add_system_event {
    my ($event_type, $data) = @_;

    my $event = {
        id   => ++$event_counter,
        type => $event_type,
        data => $data,
        ts   => time(),
    };

    push @system_events, $event;

    if (@system_events > MAX_SYSTEM_EVENTS) {
        shift @system_events;
    }

    return $event;
}

sub get_recent_system_events {
    my ($since_id) = @_;
    $since_id //= 0;

    return [ grep { $_->{id} > $since_id } @system_events ];
}

# Statistics
sub get_stats {
    my $total_messages = 0;
    $total_messages += @{$_->{messages}} for values %rooms;

    return {
        uptime          => int(time() - $start_time),
        users_online    => scalar(grep { $_->{connected} } values %sessions),
        rooms_count     => scalar(keys %rooms),
        messages_total  => $total_messages,
        sse_subscribers => scalar(keys %sse_subscribers),
    };
}

# Initialize on load
init_default_rooms();

1;

__END__

# NAME

ChatApp::State - Shared state management for the chat application

# DESCRIPTION

This module manages all shared state for the multi-user chat application,
including sessions (users), rooms, messages, and SSE subscribers.

Key features:
- Session-based identity (persists across reconnections)
- 30-second grace period before broadcasting "user left"
- Message catch-up support for reconnections
