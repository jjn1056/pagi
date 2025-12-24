package PAGI::WebSocket;
use strict;
use warnings;
use Carp qw(croak);
use Hash::MultiValue;
use Future::AsyncAwait;
use Future;
use JSON::MaybeXS ();
use Scalar::Util qw(blessed);

our $VERSION = '0.01';

sub new {
    my ($class, $scope, $receive, $send) = @_;

    croak "PAGI::WebSocket requires scope hashref"
        unless $scope && ref($scope) eq 'HASH';
    croak "PAGI::WebSocket requires receive coderef"
        unless $receive && ref($receive) eq 'CODE';
    croak "PAGI::WebSocket requires send coderef"
        unless $send && ref($send) eq 'CODE';
    croak "PAGI::WebSocket requires scope type 'websocket', got '$scope->{type}'"
        unless ($scope->{type} // '') eq 'websocket';

    return bless {
        scope   => $scope,
        receive => $receive,
        send    => $send,
        _state  => 'connecting',  # connecting -> connected -> closed
        _close_code   => undef,
        _close_reason => undef,
        _on_close     => [],
        _on_error     => [],
        _on_message   => [],
    }, $class;
}

# Scope property accessors
sub scope        { shift->{scope} }
sub path         { shift->{scope}{path} }
sub raw_path     { my $s = shift; $s->{scope}{raw_path} // $s->{scope}{path} }
sub query_string { shift->{scope}{query_string} // '' }
sub scheme       { shift->{scope}{scheme} // 'ws' }
sub http_version { shift->{scope}{http_version} // '1.1' }
sub subprotocols { shift->{scope}{subprotocols} // [] }
sub client       { shift->{scope}{client} }
sub server       { shift->{scope}{server} }

# Per-connection storage - lives in scope, shared across Request/Response/WebSocket/SSE
# See PAGI::Request for detailed design notes on why stash is scope-based.
sub stash {
    my $self = shift;
    return $self->{scope}{'pagi.stash'} //= {};
}

# Application state (injected by PAGI::Lifespan, read-only)
sub state {
    my $self = shift;
    return $self->{scope}{'pagi.state'} // {};
}

# Path parameter accessors - captured from URL path by router
# Stored in scope->{path_params} for router-agnostic access
sub path_params {
    my ($self) = @_;
    return $self->{scope}{path_params} // {};
}

sub path_param {
    my ($self, $name) = @_;
    my $params = $self->{scope}{path_params} // {};
    return $params->{$name};
}

# Single header lookup (case-insensitive, returns last value)
sub header {
    my ($self, $name) = @_;
    $name = lc($name);
    my $value;
    for my $pair (@{$self->{scope}{headers} // []}) {
        if (lc($pair->[0]) eq $name) {
            $value = $pair->[1];
        }
    }
    return $value;
}

# All headers as Hash::MultiValue (cached)
sub headers {
    my $self = shift;
    return $self->{_headers} if $self->{_headers};

    my @pairs;
    for my $pair (@{$self->{scope}{headers} // []}) {
        push @pairs, lc($pair->[0]), $pair->[1];
    }

    $self->{_headers} = Hash::MultiValue->new(@pairs);
    return $self->{_headers};
}

# All values for a header
sub header_all {
    my ($self, $name) = @_;
    return $self->headers->get_all(lc($name));
}

# State accessors
sub connection_state { shift->{_state} }

sub is_connected {
    my $self = shift;
    return $self->{_state} eq 'connected';
}

sub is_closed {
    my $self = shift;
    return $self->{_state} eq 'closed';
}

sub close_code   { shift->{_close_code} }
sub close_reason { shift->{_close_reason} }

# Internal state setters
sub _set_state {
    my ($self, $state) = @_;
    $self->{_state} = $state;
}

sub _set_closed {
    my ($self, $code, $reason) = @_;
    $self->{_state} = 'closed';
    $self->{_close_code} = $code // 1005;
    $self->{_close_reason} = $reason // '';
}

# Register callback to run on disconnect/close
sub on_close {
    my ($self, $callback) = @_;
    push @{$self->{_on_close}}, $callback;
    return $self;
}

# Internal: run all on_close callbacks exactly once
async sub _run_close_callbacks {
    my ($self) = @_;

    # Only run once
    return if $self->{_close_callbacks_ran};
    $self->{_close_callbacks_ran} = 1;

    my $code = $self->close_code;
    my $reason = $self->close_reason;

    for my $cb (@{$self->{_on_close}}) {
        eval {
            my $r = $cb->($code, $reason);
            # Only await if callback returns a Future
            if (blessed($r) && $r->isa('Future')) {
                await $r;
            }
        };
        if ($@) {
            warn "PAGI::WebSocket on_close callback error: $@";
        }
    }
}

# Register callback to run on errors
sub on_error {
    my ($self, $callback) = @_;
    push @{$self->{_on_error}}, $callback;
    return $self;
}

# Register callback to run on message receive
sub on_message {
    my ($self, $callback) = @_;
    push @{$self->{_on_message}}, $callback;
    return $self;
}

# Generic event registration (Socket.IO style)
sub on {
    my ($self, $event, $callback) = @_;

    if ($event eq 'message') {
        return $self->on_message($callback);
    }
    elsif ($event eq 'close') {
        return $self->on_close($callback);
    }
    elsif ($event eq 'error') {
        return $self->on_error($callback);
    }
    else {
        croak "Unknown event type: $event (expected message, close, or error)";
    }
}

# Internal: trigger error callbacks
sub _trigger_error {
    my ($self, $error) = @_;

    for my $cb (@{$self->{_on_error}}) {
        eval { $cb->($error) };
        if ($@) {
            warn "PAGI::WebSocket on_error callback error: $@";
        }
    }

    # If no error handlers registered, warn
    if (!@{$self->{_on_error}}) {
        warn "PAGI::WebSocket error: $error";
    }
}

# Accept the WebSocket connection
async sub accept {
    my ($self, %opts) = @_;

    my $event = {
        type => 'websocket.accept',
    };
    $event->{subprotocol} = $opts{subprotocol} if exists $opts{subprotocol};
    $event->{headers} = $opts{headers} if exists $opts{headers};

    await $self->{send}->($event);
    $self->_set_state('connected');

    return $self;
}

# Close the WebSocket connection
async sub close {
    my ($self, $code, $reason) = @_;

    # Idempotent - don't send close twice
    return if $self->is_closed;

    $code //= 1000;
    $reason //= '';

    await $self->{send}->({
        type   => 'websocket.close',
        code   => $code,
        reason => $reason,
    });

    $self->_set_closed($code, $reason);
    await $self->_run_close_callbacks;

    return $self;
}

# Send text message
async sub send_text {
    my ($self, $text) = @_;

    croak "Cannot send on closed WebSocket" if $self->is_closed;

    await $self->{send}->({
        type => 'websocket.send',
        text => $text,
    });

    return $self;
}

# Send binary message
async sub send_bytes {
    my ($self, $bytes) = @_;

    croak "Cannot send on closed WebSocket" if $self->is_closed;

    await $self->{send}->({
        type  => 'websocket.send',
        bytes => $bytes,
    });

    return $self;
}

# Send JSON-encoded message
async sub send_json {
    my ($self, $data) = @_;

    croak "Cannot send on closed WebSocket" if $self->is_closed;

    my $json = JSON::MaybeXS::encode_json($data);

    await $self->{send}->({
        type => 'websocket.send',
        text => $json,
    });

    return $self;
}

# Safe send methods - return bool instead of throwing

async sub try_send_text {
    my ($self, $text) = @_;
    return 0 if $self->is_closed;

    eval {
        await $self->{send}->({
            type => 'websocket.send',
            text => $text,
        });
    };
    if ($@) {
        $self->_set_closed(1006, 'Connection lost');
        return 0;
    }
    return 1;
}

async sub try_send_bytes {
    my ($self, $bytes) = @_;
    return 0 if $self->is_closed;

    eval {
        await $self->{send}->({
            type => 'websocket.send',
            bytes => $bytes,
        });
    };
    if ($@) {
        $self->_set_closed(1006, 'Connection lost');
        return 0;
    }
    return 1;
}

async sub try_send_json {
    my ($self, $data) = @_;
    return 0 if $self->is_closed;

    my $json = JSON::MaybeXS::encode_json($data);
    eval {
        await $self->{send}->({
            type => 'websocket.send',
            text => $json,
        });
    };
    if ($@) {
        $self->_set_closed(1006, 'Connection lost');
        return 0;
    }
    return 1;
}

# Silent send methods - no-op when closed

async sub send_text_if_connected {
    my ($self, $text) = @_;
    return unless $self->is_connected;
    await $self->try_send_text($text);
    return;
}

async sub send_bytes_if_connected {
    my ($self, $bytes) = @_;
    return unless $self->is_connected;
    await $self->try_send_bytes($bytes);
    return;
}

async sub send_json_if_connected {
    my ($self, $data) = @_;
    return unless $self->is_connected;
    await $self->try_send_json($data);
    return;
}

# Receive methods

async sub receive {
    my ($self) = @_;

    return undef if $self->is_closed;

    while (1) {
        my $event = await $self->{receive}->();

        if (!defined($event) || $event->{type} eq 'websocket.disconnect') {
            # 1005 = No Status Rcvd (RFC 6455)
            my $code = $event->{code} // 1005;
            my $reason = $event->{reason} // '';
            $self->_set_closed($code, $reason);
            await $self->_run_close_callbacks;
            return undef;
        }

        # Skip connect events - they're handled by accept()
        next if $event->{type} eq 'websocket.connect';

        return $event;
    }
}

async sub receive_text {
    my ($self) = @_;

    while (1) {
        my $event = await $self->receive;
        return undef unless $event;

        # Skip non-receive events and binary frames
        next unless $event->{type} eq 'websocket.receive';
        next unless exists $event->{text};

        return $event->{text};
    }
}

async sub receive_bytes {
    my ($self) = @_;

    while (1) {
        my $event = await $self->receive;
        return undef unless $event;

        # Skip non-receive events and text frames
        next unless $event->{type} eq 'websocket.receive';
        next unless exists $event->{bytes};

        return $event->{bytes};
    }
}

async sub receive_json {
    my ($self) = @_;

    my $text = await $self->receive_text;
    return undef unless defined $text;

    return JSON::MaybeXS::decode_json($text);
}

# Iteration helpers

async sub each_message {
    my ($self, $callback) = @_;

    while (my $event = await $self->receive) {
        next unless $event->{type} eq 'websocket.receive';
        await $callback->($event);
    }

    return;
}

async sub each_text {
    my ($self, $callback) = @_;

    while (my $text = await $self->receive_text) {
        await $callback->($text);
    }

    return;
}

async sub each_bytes {
    my ($self, $callback) = @_;

    while (my $bytes = await $self->receive_bytes) {
        await $callback->($bytes);
    }

    return;
}

async sub each_json {
    my ($self, $callback) = @_;

    while (1) {
        my $text = await $self->receive_text;
        last unless defined $text;

        my $data = JSON::MaybeXS::decode_json($text);
        await $callback->($data);
    }

    return;
}

# Callback-based event loop (alternative to each_* iteration)
async sub run {
    my ($self) = @_;

    while (my $event = await $self->receive) {
        next unless $event->{type} eq 'websocket.receive';

        my $data = $event->{text} // $event->{bytes};

        for my $cb (@{$self->{_on_message}}) {
            eval {
                my $r = $cb->($data, $event);
                # Await if callback returns a Future
                if (blessed($r) && $r->isa('Future')) {
                    await $r;
                }
            };
            if ($@) {
                $self->_trigger_error($@);
            }
        }
    }

    return;
}

# Timeout support

sub set_loop {
    my ($self, $loop) = @_;
    $self->{_loop} = $loop;
    return $self;
}

sub loop {
    my ($self) = @_;
    return $self->{_loop} if $self->{_loop};

    # Try to get default loop
    require IO::Async::Loop;
    $self->{_loop} = IO::Async::Loop->new;
    return $self->{_loop};
}

async sub receive_with_timeout {
    my ($self, $timeout) = @_;

    return undef if $self->is_closed;

    my $loop = $self->loop;
    my $start_time = time;

    while (1) {
        my $elapsed = time - $start_time;
        my $remaining = $timeout - $elapsed;

        if ($remaining <= 0) {
            return undef;
        }

        my $receive_f = $self->{receive}->();
        my $timeout_f = $loop->delay_future(after => $remaining);
        my $winner = await Future->wait_any($receive_f, $timeout_f);

        if ($timeout_f->is_ready && !$receive_f->is_ready) {
            # Timeout won - cancel receive and return undef
            $receive_f->cancel;
            return undef;
        }

        # Shouldn't happen, but safety check
        if ($receive_f->is_cancelled) {
            return undef;
        }

        # Message received
        my $event = $receive_f->get;

        if (!defined($event) || $event->{type} eq 'websocket.disconnect') {
            my $code = $event->{code} // 1005;
            my $reason = $event->{reason} // '';
            $self->_set_closed($code, $reason);
            await $self->_run_close_callbacks;
            return undef;
        }

        # Skip connect events - they're handled by accept()
        next if $event->{type} eq 'websocket.connect';

        return $event;
    }
}

async sub receive_text_with_timeout {
    my ($self, $timeout) = @_;

    my $event = await $self->receive_with_timeout($timeout);
    return undef unless $event;
    return undef unless $event->{type} eq 'websocket.receive';
    return undef unless exists $event->{text};

    return $event->{text};
}

async sub receive_bytes_with_timeout {
    my ($self, $timeout) = @_;

    my $event = await $self->receive_with_timeout($timeout);
    return undef unless $event;
    return undef unless $event->{type} eq 'websocket.receive';
    return undef unless exists $event->{bytes};

    return $event->{bytes};
}

async sub receive_json_with_timeout {
    my ($self, $timeout) = @_;

    my $text = await $self->receive_text_with_timeout($timeout);
    return undef unless defined $text;

    return JSON::MaybeXS::decode_json($text);
}

# Heartbeat/keepalive support
sub start_heartbeat {
    my ($self, $interval) = @_;

    return $self if !$interval || $interval <= 0;

    require IO::Async::Timer::Periodic;

    my $loop = $self->loop;

    my $weak_self = $self;
    Scalar::Util::weaken($weak_self);

    my $timer = IO::Async::Timer::Periodic->new(
        interval => $interval,
        on_tick  => sub {
            return unless $weak_self && $weak_self->is_connected;
            eval {
                $weak_self->{send}->({
                    type => 'websocket.send',
                    text => JSON::MaybeXS::encode_json({
                        type => 'ping',
                        ts   => time(),
                    }),
                });
            };
        },
    );

    $loop->add($timer);
    $timer->start;

    # Store for cleanup
    $self->{_heartbeat_timer} = $timer;
    $self->{_heartbeat_loop} = $loop;

    # Auto-stop on close
    $self->on_close(sub {
        $self->stop_heartbeat;
    });

    return $self;
}

sub stop_heartbeat {
    my ($self) = @_;

    if (my $timer = delete $self->{_heartbeat_timer}) {
        $timer->stop if $timer->is_running;
        if (my $loop = delete $self->{_heartbeat_loop}) {
            eval { $loop->remove($timer) };
        }
    }

    return $self;
}

1;

__END__

=head1 NAME

PAGI::WebSocket - Convenience wrapper for PAGI WebSocket connections

=head1 SYNOPSIS

    use PAGI::WebSocket;
    use Future::AsyncAwait;

    # Simple echo server
    async sub app {
        my ($scope, $receive, $send) = @_;

        my $ws = PAGI::WebSocket->new($scope, $receive, $send);
        await $ws->accept;

        await $ws->each_text(async sub {
            my ($text) = @_;
            await $ws->send_text("Echo: $text");
        });
    }

    # JSON API with cleanup
    async sub json_app {
        my ($scope, $receive, $send) = @_;

        my $ws = PAGI::WebSocket->new($scope, $receive, $send);
        await $ws->accept(subprotocol => 'json');

        my $user_id = generate_id();

        # Cleanup runs on any disconnect
        $ws->on_close(async sub {
            my ($code, $reason) = @_;
            await remove_user($user_id);
            log_disconnect($user_id, $code);
        });

        await $ws->each_json(async sub {
            my ($data) = @_;

            if ($data->{type} eq 'ping') {
                await $ws->send_json({ type => 'pong' });
            }
        });
    }

    # Callback-based style (alternative to iteration)
    async sub callback_app {
        my ($scope, $receive, $send) = @_;

        my $ws = PAGI::WebSocket->new($scope, $receive, $send);
        await $ws->accept;

        $ws->stash->{user} = 'anonymous';

        $ws->on(message => sub {
            my ($data) = @_;
            $ws->send_text("Echo: $data");
        });

        $ws->on(error => sub {
            my ($error) = @_;
            warn "WebSocket error: $error";
        });

        $ws->on(close => sub {
            print "User disconnected\n";
        });

        await $ws->run;
    }

=head1 DESCRIPTION

PAGI::WebSocket wraps the raw PAGI WebSocket protocol to provide a clean,
high-level API inspired by Starlette's WebSocket class. It eliminates
protocol boilerplate and provides:

=over 4

=item * Typed send/receive methods (text, bytes, JSON)

=item * Connection state tracking (is_connected, is_closed, close_code)

=item * Cleanup and error callback registration (on_close, on_error)

=item * Safe send methods for broadcast scenarios (try_send_*, send_*_if_connected)

=item * Message iteration helpers (each_text, each_json)

=item * Callback-based event handling (on, run)

=item * Per-connection storage (stash)

=item * Timeout support for receives

=back

=head1 CONSTRUCTOR

=head2 new

    my $ws = PAGI::WebSocket->new($scope, $receive, $send);

Creates a new WebSocket wrapper. Requires:

=over 4

=item * C<$scope> - PAGI scope hashref with C<type => 'websocket'>

=item * C<$receive> - Async coderef returning Futures for events

=item * C<$send> - Async coderef for sending events

=back

Dies if scope type is not 'websocket'.

=head1 SCOPE ACCESSORS

=head2 scope, path, raw_path, query_string, scheme, http_version

    my $path = $ws->path;              # /chat/room1
    my $qs = $ws->query_string;        # token=abc
    my $scheme = $ws->scheme;          # ws or wss

Standard PAGI scope properties with sensible defaults.

=head2 subprotocols

    my $protos = $ws->subprotocols;    # ['chat', 'json']

Returns arrayref of requested subprotocols.

=head2 client, server

    my $client = $ws->client;          # ['192.168.1.1', 54321]

Client and server address info.

=head2 header, headers, header_all

    my $origin = $ws->header('origin');
    my $all_cookies = $ws->header_all('cookie');
    my $hmv = $ws->headers;            # Hash::MultiValue

Case-insensitive header access.

=head2 stash

    $ws->stash->{user} = $user;
    my $room = $ws->stash->{current_room};

Per-connection storage hashref. Useful for storing user data
without external variables.

=head2 state

    my $db = $ws->state->{db};
    my $config = $ws->state->{config};

Application state hashref injected by PAGI::Lifespan. Read-only access
to shared application state. Returns empty hashref if not set.

Note: This is separate from C<stash> (per-connection data) and
C<connection_state> (internal WebSocket state).

=head2 path_param

    my $id = $ws->path_param('id');

Returns a path parameter by name. Path parameters are captured from the URL
path by a router and stored in C<< $scope->{path_params} >>.

    # Route: /chat/:room
    my $room = $ws->path_param('room');

=head2 path_params

    my $params = $ws->path_params;  # { room => 'general', id => '42' }

Returns hashref of all path parameters from scope.

=head1 LIFECYCLE METHODS

=head2 accept

    await $ws->accept;
    await $ws->accept(subprotocol => 'chat');
    await $ws->accept(headers => [['x-custom', 'value']]);

Accepts the WebSocket connection. Optionally specify a subprotocol
to use and additional response headers.

=head2 close

    await $ws->close;
    await $ws->close(1000, 'Normal closure');
    await $ws->close(4000, 'Custom reason');

Closes the connection. Default code is 1000 (normal closure).
Idempotent - calling multiple times only sends close once.

=head1 STATE ACCESSORS

=head2 is_connected, is_closed, connection_state

    if ($ws->is_connected) { ... }
    if ($ws->is_closed) { ... }
    my $state = $ws->connection_state; # 'connecting', 'connected', 'closed'

=head2 close_code, close_reason

    my $code = $ws->close_code;        # 1000, 1001, etc.
    my $reason = $ws->close_reason;    # 'Normal closure'

Available after connection closes. Defaults: code=1005, reason=''.

=head1 SEND METHODS

=head2 send_text, send_bytes, send_json

    await $ws->send_text("Hello!");
    await $ws->send_bytes("\x00\x01\x02");
    await $ws->send_json({ action => 'greet', name => 'Alice' });

Send a message. Dies if connection is closed.

=head2 try_send_text, try_send_bytes, try_send_json

    my $sent = await $ws->try_send_json($data);
    if (!$sent) {
        # Client disconnected
        cleanup_user($id);
    }

Returns true if sent, false if failed or closed. Does not throw.
Useful for broadcasting to multiple clients.

=head2 send_text_if_connected, send_bytes_if_connected, send_json_if_connected

    await $ws->send_json_if_connected($data);

Silent no-op if connection is closed. Useful for fire-and-forget.

=head1 RECEIVE METHODS

=head2 receive

    my $event = await $ws->receive;

Returns raw PAGI event hashref, or undef on disconnect.

=head2 receive_text, receive_bytes

    my $text = await $ws->receive_text;
    my $bytes = await $ws->receive_bytes;

Waits for specific frame type, skipping others. Returns undef on disconnect.

=head2 receive_json

    my $data = await $ws->receive_json;

Receives text frame and decodes as JSON. Dies on invalid JSON.

=head2 receive_with_timeout, receive_text_with_timeout, etc.

    my $event = await $ws->receive_with_timeout(30);  # 30 seconds

Returns undef on timeout (connection remains open).

=head1 ITERATION HELPERS

=head2 each_message, each_text, each_bytes, each_json

    await $ws->each_text(async sub {
        my ($text) = @_;
        await $ws->send_text("Got: $text");
    });

    await $ws->each_json(async sub {
        my ($data) = @_;
        if ($data->{type} eq 'ping') {
            await $ws->send_json({ type => 'pong' });
        }
    });

Loops until disconnect, calling callback for each message.
Exceptions in callback propagate to caller.

=head1 EVENT CALLBACKS

=head2 on_close

    # Simple sync callback
    $ws->on_close(sub {
        my ($code, $reason) = @_;
        print "Disconnected: $code\n";
    });

    # Async callback for cleanup that needs await
    $ws->on_close(async sub {
        my ($code, $reason) = @_;
        await cleanup_resources();
    });

Registers cleanup callback that runs on disconnect or close().
Callbacks can be regular subs or async subs - async results are
automatically awaited. Multiple callbacks run in registration order.
Exceptions are caught and warned but don't prevent other callbacks.

=head2 on_error

    $ws->on_error(sub {
        my ($error) = @_;
        warn "WebSocket error: $error";
    });

Registers error callback. Called when exceptions occur in message
handlers during C<run()>. If no error handlers are registered,
errors are warned to STDERR.

=head2 on_message, on

    $ws->on_message(sub {
        my ($data, $event) = @_;
        # $data is text or bytes, $event is raw PAGI event
    });

    # Generic form (Socket.IO style)
    $ws->on(message => sub { ... });
    $ws->on(close => sub { ... });
    $ws->on(error => sub { ... });

Registers message callback for use with C<run()>. Multiple
callbacks can be registered for each event type.

=head2 run

    # Register callbacks first
    $ws->on(message => sub { my ($data) = @_; ... });
    $ws->on(close => sub { ... });

    # Enter event loop
    await $ws->run;

Callback-based event loop (alternative to C<each_*> iteration).
Runs until disconnect, dispatching messages to registered callbacks.
Errors in callbacks are caught and passed to error handlers.

=head1 HEARTBEAT / KEEPALIVE

=head2 start_heartbeat

    $ws->start_heartbeat(25);  # Ping every 25 seconds

Starts sending periodic JSON ping messages to keep the connection alive.
Useful for preventing proxy/NAT timeout on idle connections.

The ping message format is:

    { "type": "ping", "ts": <unix_timestamp> }

Common intervals:

=over 4

=item C<25> - Safe for most proxies (30s timeout common)

=item C<55> - Safe for aggressive proxies (60s timeout)

=back

Automatically stops when connection closes. Returns C<$self> for chaining.

=head2 stop_heartbeat

    $ws->stop_heartbeat;

Manually stops the heartbeat timer. Called automatically on connection close.
Returns C<$self> for chaining.

=head1 COMPLETE EXAMPLE

    use PAGI::WebSocket;
    use Future::AsyncAwait;

    my %connections;

    async sub chat_app {
        my ($scope, $receive, $send) = @_;

        my $ws = PAGI::WebSocket->new($scope, $receive, $send);
        await $ws->accept;

        my $user_id = generate_id();
        $connections{$user_id} = $ws;

        $ws->on_close(async sub {
            delete $connections{$user_id};
            await broadcast({ type => 'leave', user => $user_id });
        });

        await broadcast({ type => 'join', user => $user_id });

        await $ws->each_json(async sub {
            my ($data) = @_;
            $data->{from} = $user_id;
            await broadcast($data);
        });
    }

    async sub broadcast {
        my ($data) = @_;
        for my $ws (values %connections) {
            await $ws->try_send_json($data);
        }
    }

=head1 SEE ALSO

L<PAGI::Request> - Similar convenience wrapper for HTTP requests

L<PAGI::Server> - PAGI protocol server

=head1 AUTHOR

PAGI Contributors

=cut
