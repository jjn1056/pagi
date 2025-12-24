package PAGI::SSE;
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

    croak "PAGI::SSE requires scope hashref"
        unless $scope && ref($scope) eq 'HASH';
    croak "PAGI::SSE requires receive coderef"
        unless $receive && ref($receive) eq 'CODE';
    croak "PAGI::SSE requires send coderef"
        unless $send && ref($send) eq 'CODE';
    croak "PAGI::SSE requires scope type 'sse', got '$scope->{type}'"
        unless ($scope->{type} // '') eq 'sse';

    return bless {
        scope     => $scope,
        receive   => $receive,
        send      => $send,
        _state    => 'pending',  # pending -> started -> closed
        _on_close => [],
        _on_error => [],
    }, $class;
}

# Scope property accessors
sub scope        { shift->{scope} }
sub path         { shift->{scope}{path} // '/' }
sub raw_path     { my $s = shift; $s->{scope}{raw_path} // $s->{scope}{path} // '/' }
sub query_string { shift->{scope}{query_string} // '' }
sub scheme       { shift->{scope}{scheme} // 'http' }
sub http_version { shift->{scope}{http_version} // '1.1' }
sub client       { shift->{scope}{client} }
sub server       { shift->{scope}{server} }

# Per-connection storage - lives in scope, shared across Request/Response/WebSocket/SSE
# See PAGI::Request for detailed design notes on why stash is scope-based.
sub stash {
    my ($self) = @_;
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

# Connection state accessors
sub connection_state { shift->{_state} }

sub is_started {
    my $self = shift;
    return $self->{_state} eq 'started';
}

sub is_closed {
    my $self = shift;
    return $self->{_state} eq 'closed';
}

# Internal state setters
sub _set_state {
    my ($self, $state) = @_;
    $self->{_state} = $state;
}

sub _set_closed {
    my ($self) = @_;
    $self->{_state} = 'closed';

    # Stop keepalive timer if running
    if ($self->{_keepalive_timer}) {
        $self->{_keepalive_timer}->stop;
        if ($self->{_loop}) {
            $self->{_loop}->remove($self->{_keepalive_timer});
        }
        delete $self->{_keepalive_timer};
    }
}

# Start the SSE stream
async sub start {
    my ($self, %opts) = @_;

    # Idempotent - don't start twice
    return $self if $self->is_started || $self->is_closed;

    my $event = {
        type   => 'sse.start',
        status => $opts{status} // 200,
    };
    $event->{headers} = $opts{headers} if exists $opts{headers};

    await $self->{send}->($event);
    $self->_set_state('started');

    return $self;
}

# Set or get the event loop
sub set_loop {
    my ($self, $loop) = @_;
    $self->{_loop} = $loop;
    return $self;
}

sub loop {
    my ($self) = @_;
    return $self->{_loop} if $self->{_loop};

    require IO::Async::Loop;
    $self->{_loop} = IO::Async::Loop->new;
    return $self->{_loop};
}

# Enable/disable keepalive timer
sub keepalive {
    my ($self, $interval, $comment) = @_;
    $comment //= ':keepalive';

    # Stop existing timer if any
    if ($self->{_keepalive_timer}) {
        $self->{_keepalive_timer}->stop;
        $self->loop->remove($self->{_keepalive_timer});
        delete $self->{_keepalive_timer};
    }

    # If interval is 0 or undef, just disable
    return $self unless $interval && $interval > 0;

    require IO::Async::Timer::Periodic;
    require Scalar::Util;

    my $weak_self = $self;
    Scalar::Util::weaken($weak_self);

    my $timer = IO::Async::Timer::Periodic->new(
        interval => $interval,
        on_tick  => sub {
            return unless $weak_self && !$weak_self->is_closed;
            # Send as SSE comment (not data) to avoid triggering onmessage
            $weak_self->try_send_comment($comment);
        },
    );

    $self->loop->add($timer);
    $timer->start;
    $self->{_keepalive_timer} = $timer;

    return $self;
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

# Get Last-Event-ID header from client (for reconnection)
sub last_event_id {
    my ($self) = @_;
    return $self->header('last-event-id');
}

# Send data-only event
async sub send {
    my ($self, $data) = @_;

    croak "Cannot send on closed SSE connection" if $self->is_closed;

    # Auto-start if not started
    await $self->start unless $self->is_started;

    await $self->{send}->({
        type => 'sse.send',
        data => $data,
    });

    return $self;
}

# Send JSON-encoded data
async sub send_json {
    my ($self, $data) = @_;

    croak "Cannot send on closed SSE connection" if $self->is_closed;

    await $self->start unless $self->is_started;

    my $json = JSON::MaybeXS::encode_json($data);

    await $self->{send}->({
        type => 'sse.send',
        data => $json,
    });

    return $self;
}

# Send full SSE event with all fields
async sub send_event {
    my ($self, %opts) = @_;

    croak "Cannot send on closed SSE connection" if $self->is_closed;
    croak "send_event requires 'data' parameter" unless exists $opts{data};

    await $self->start unless $self->is_started;

    # Auto-encode hashref/arrayref data as JSON
    my $data = $opts{data};
    if (ref $data) {
        $data = JSON::MaybeXS::encode_json($data);
    }

    my $event = {
        type => 'sse.send',
        data => $data,
    };

    $event->{event} = $opts{event} if defined $opts{event};
    $event->{id}    = "$opts{id}"  if defined $opts{id};
    $event->{retry} = int($opts{retry}) if defined $opts{retry};

    await $self->{send}->($event);

    return $self;
}

# Safe send - returns bool instead of throwing
async sub try_send {
    my ($self, $data) = @_;
    return 0 if $self->is_closed;

    eval {
        await $self->start unless $self->is_started;
        await $self->{send}->({
            type => 'sse.send',
            data => $data,
        });
    };
    if ($@) {
        $self->_set_closed;
        return 0;
    }
    return 1;
}

async sub try_send_json {
    my ($self, $data) = @_;
    return 0 if $self->is_closed;

    eval {
        await $self->start unless $self->is_started;
        my $json = JSON::MaybeXS::encode_json($data);
        await $self->{send}->({
            type => 'sse.send',
            data => $json,
        });
    };
    if ($@) {
        $self->_set_closed;
        return 0;
    }
    return 1;
}

# Send SSE comment (doesn't trigger onmessage in browser)
async sub send_comment {
    my ($self, $comment) = @_;

    croak "Cannot send on closed SSE connection" if $self->is_closed;

    await $self->start unless $self->is_started;

    await $self->{send}->({
        type    => 'sse.comment',
        comment => $comment,
    });

    return $self;
}

async sub try_send_comment {
    my ($self, $comment) = @_;
    return 0 if $self->is_closed;

    eval {
        await $self->start unless $self->is_started;
        await $self->{send}->({
            type    => 'sse.comment',
            comment => $comment,
        });
    };
    if ($@) {
        $self->_set_closed;
        return 0;
    }
    return 1;
}

async sub try_send_event {
    my ($self, %opts) = @_;
    return 0 if $self->is_closed;

    eval {
        await $self->start unless $self->is_started;

        my $data = $opts{data} // '';
        if (ref $data) {
            $data = JSON::MaybeXS::encode_json($data);
        }

        my $event = {
            type => 'sse.send',
            data => $data,
        };
        $event->{event} = $opts{event} if defined $opts{event};
        $event->{id}    = "$opts{id}"  if defined $opts{id};
        $event->{retry} = int($opts{retry}) if defined $opts{retry};

        await $self->{send}->($event);
    };
    if ($@) {
        $self->_set_closed;
        return 0;
    }
    return 1;
}

# Register close callback
sub on_close {
    my ($self, $callback) = @_;
    push @{$self->{_on_close}}, $callback;
    return $self;
}

# Register error callback
sub on_error {
    my ($self, $callback) = @_;
    push @{$self->{_on_error}}, $callback;
    return $self;
}

# Internal: run all on_close callbacks
async sub _run_close_callbacks {
    my ($self) = @_;

    # Only run once
    return if $self->{_close_callbacks_ran};
    $self->{_close_callbacks_ran} = 1;

    for my $cb (@{$self->{_on_close}}) {
        eval {
            my $r = $cb->($self);
            if (blessed($r) && $r->isa('Future')) {
                await $r;
            }
        };
        if ($@) {
            warn "PAGI::SSE on_close callback error: $@";
        }
    }
}

# Close the connection
sub close {
    my ($self) = @_;

    return $self if $self->is_closed;

    $self->_set_closed;
    $self->_run_close_callbacks->get;

    return $self;
}

# Wait for disconnect
async sub run {
    my ($self) = @_;

    await $self->start unless $self->is_started;

    while (!$self->is_closed) {
        my $event = await $self->{receive}->();
        my $type = $event->{type} // '';

        if ($type eq 'sse.disconnect') {
            $self->_set_closed;
            await $self->_run_close_callbacks;
            last;
        }
    }

    return;
}

# Iterate over items and send events
async sub each {
    my ($self, $source, $callback) = @_;

    await $self->start unless $self->is_started;

    my $index = 0;

    # Handle arrayref
    if (ref $source eq 'ARRAY') {
        for my $item (@$source) {
            last if $self->is_closed;

            my $result = await $callback->($item, $index++);

            # If callback returns a hashref, treat as event spec
            if (ref $result eq 'HASH') {
                await $self->send_event(%$result);
            }
        }
    }
    # Handle coderef iterator
    elsif (ref $source eq 'CODE') {
        while (!$self->is_closed) {
            my $item = $source->();
            last unless defined $item;

            my $result = await $callback->($item, $index++);

            if (ref $result eq 'HASH') {
                await $self->send_event(%$result);
            }
        }
    }
    else {
        croak "each() requires arrayref or coderef, got " . ref($source);
    }

    return $self;
}

# Periodic event sending
async sub every {
    my ($self, $interval, $callback) = @_;

    my $loop = $self->loop;

    await $self->start unless $self->is_started;

    # Start background disconnect monitor
    $self->_start_disconnect_monitor unless $self->{_disconnect_monitor_started};

    while (!$self->is_closed) {
        # Try to send - if it fails, connection is closed
        my $ok = eval { await $callback->(); 1 };
        unless ($ok) {
            $self->_set_closed;
            await $self->_run_close_callbacks;
            last;
        }

        await $loop->delay_future(after => $interval);
    }
}

# Start a background task to monitor for disconnect events
sub _start_disconnect_monitor {
    my ($self) = @_;
    return if $self->{_disconnect_monitor_started};
    $self->{_disconnect_monitor_started} = 1;

    my $receive = $self->{receive};
    my $weak_self = $self;
    require Scalar::Util;
    Scalar::Util::weaken($weak_self);

    # This runs in the background and waits for disconnect
    my $monitor = (async sub {
        while ($weak_self && !$weak_self->is_closed) {
            my $event = eval { await $receive->() };
            last unless $event;

            my $type = $event->{type} // '';
            if ($type eq 'sse.disconnect') {
                if ($weak_self) {
                    $weak_self->_set_closed;
                    await $weak_self->_run_close_callbacks;
                }
                last;
            }
        }
    })->();

    # Keep the future alive but don't block on it
    $monitor->on_fail(sub { }); # Ignore errors
    $self->{_disconnect_monitor} = $monitor;
}

1;

__END__

=head1 NAME

PAGI::SSE - Convenience wrapper for PAGI Server-Sent Events connections

=head1 SYNOPSIS

    use PAGI::SSE;
    use Future::AsyncAwait;

    # Simple notification stream
    async sub app {
        my ($scope, $receive, $send) = @_;

        my $sse = PAGI::SSE->new($scope, $receive, $send);

        # Enable keepalive for proxy compatibility
        $sse->keepalive(25);

        # Cleanup on disconnect
        $sse->on_close(sub {
            remove_subscriber($sse->stash->{sub_id});
        });

        # Handle reconnection
        if (my $last_id = $sse->last_event_id) {
            my @missed = get_events_since($last_id);
            for my $event (@missed) {
                await $sse->send_event(%$event);
            }
        }

        # Subscribe to updates
        $sse->stash->{sub_id} = add_subscriber(sub {
            my ($event) = @_;
            $sse->try_send_json($event);
        });

        # Wait for disconnect
        await $sse->run;
    }

=head1 DESCRIPTION

PAGI::SSE wraps the raw PAGI SSE protocol to provide a clean,
high-level API inspired by Starlette. It eliminates protocol
boilerplate and provides:

=over 4

=item * Multiple send methods (send, send_json, send_event)

=item * Connection state tracking (is_started, is_closed)

=item * Cleanup callback registration (on_close)

=item * Safe send methods for broadcast scenarios (try_send_*)

=item * Reconnection support (last_event_id)

=item * Keepalive timer for proxy compatibility

=item * Iteration helper (each)

=item * Per-connection storage (stash)

=back

=head1 CONSTRUCTOR

=head2 new

    my $sse = PAGI::SSE->new($scope, $receive, $send);

Creates a new SSE wrapper. Requires:

=over 4

=item * C<$scope> - PAGI scope hashref with C<type => 'sse'>

=item * C<$receive> - Async coderef returning Futures for events

=item * C<$send> - Async coderef for sending events

=back

Dies if scope type is not 'sse'.

=head1 SCOPE ACCESSORS

=head2 scope, path, raw_path, query_string, scheme, http_version

    my $path = $sse->path;              # /events
    my $qs = $sse->query_string;        # token=abc

=head2 header, headers, header_all

    my $auth = $sse->header('authorization');
    my @cookies = $sse->header_all('cookie');

=head2 last_event_id

    my $id = $sse->last_event_id;       # From Last-Event-ID header

Returns the Last-Event-ID header sent by reconnecting clients.
Use this to replay missed events.

=head2 stash

    $sse->stash->{client_id} = $id;
    my $user = $sse->stash->{user};

Returns the per-request stash hashref. The stash lives in the request
scope and is shared across all middleware, handlers, and subrouters
processing the same request.

B<Note:> For worker-level state (database connections, config), use
C<< $sse->state >> to access application state injected by PAGI::Lifespan.

=head2 path_param

    my $channel = $sse->path_param('channel');

Returns a path parameter by name. Path parameters are captured from the URL
path by a router and stored in C<< $scope->{path_params} >>.

=head2 path_params

    my $params = $sse->path_params;

Returns hashref of all path parameters from scope.

=head2 state

    my $state = $sse->state;
    my $db = $sse->state->{db};

Returns the application state hashref injected by PAGI::Lifespan.
This contains worker-level shared state like database connections
and configuration. Returns empty hashref if no state was injected.

=head1 LIFECYCLE METHODS

=head2 start

    await $sse->start;
    await $sse->start(status => 200, headers => [...]);

Starts the SSE stream. Called automatically on first send.
Idempotent - only sends sse.start once.

=head2 close

    $sse->close;

Marks connection as closed and runs on_close callbacks.

=head2 run

    await $sse->run;

Waits for client disconnect. Use this at the end of your
handler to keep the connection open.

=head1 CONNECTION STATE ACCESSORS

=head2 is_started, is_closed, connection_state

    if ($sse->is_started) { ... }
    if ($sse->is_closed) { ... }
    my $state = $sse->connection_state;    # 'pending', 'started', 'closed'

=head1 SEND METHODS

=head2 send

    await $sse->send("Hello world");

Sends a data-only event.

=head2 send_json

    await $sse->send_json({ type => 'update', data => $payload });

JSON-encodes data before sending.

=head2 send_event

    await $sse->send_event(
        data  => $data,              # Required (auto JSON-encodes refs)
        event => 'notification',     # Optional event type
        id    => 'msg-123',          # Optional event ID
        retry => 5000,               # Optional reconnect hint (ms)
    );

Sends a full SSE event with all fields.

=head2 try_send, try_send_json, try_send_event

    my $ok = await $sse->try_send_json($data);
    if (!$ok) {
        # Client disconnected
    }

Returns true on success, false on failure. Does not throw.
Useful for broadcasting to multiple clients.

=head1 KEEPALIVE

=head2 keepalive

    $sse->keepalive(30);              # Ping every 30 seconds
    $sse->keepalive(30, ':ping');     # Custom comment text
    $sse->keepalive(0);               # Disable

Sends periodic comment pings to prevent proxy timeouts.
Requires an event loop (auto-created if needed).

=head1 ITERATION

=head2 each

    # Simple iteration
    await $sse->each(\@items, async sub {
        my ($item) = @_;
        await $sse->send_json($item);
    });

    # With transformer - return event spec
    await $sse->each(\@items, async sub {
        my ($item, $index) = @_;
        return {
            data  => $item,
            event => 'item',
            id    => $index,
        };
    });

    # Coderef iterator
    await $sse->each($iterator_sub, async sub { ... });

Iterates over items, calling callback for each.
If callback returns a hashref, sends it as an event.

=head2 every

    await $sse->every(1, async sub {
        await $sse->send_event(
            event => 'tick',
            data  => { ts => time },
        );
    });

Calls the callback every C<$interval> seconds until client disconnects.
Useful for periodic updates.

=head1 EVENT CALLBACKS

=head2 on_close

    $sse->on_close(sub {
        my ($sse) = @_;
        cleanup_resources();
    });

Registers cleanup callback. Runs on disconnect or close().
Multiple callbacks run in registration order.

=head2 on_error

    $sse->on_error(sub {
        my ($sse, $error) = @_;
        warn "SSE error: $error";
    });

Registers error callback.

=head1 EXAMPLE: LIVE DASHBOARD

    async sub dashboard_sse {
        my ($scope, $receive, $send) = @_;

        my $sse = PAGI::SSE->new($scope, $receive, $send);

        $sse->keepalive(25);

        # Send initial state
        await $sse->send_event(
            event => 'connected',
            data  => { time => time() },
        );

        # Subscribe to metrics
        my $sub_id = subscribe_metrics(sub {
            my ($metrics) = @_;
            $sse->try_send_event(
                event => 'metrics',
                data  => $metrics,
            );
        });

        $sse->on_close(sub {
            unsubscribe_metrics($sub_id);
        });

        await $sse->run;
    }

=head1 SEE ALSO

L<PAGI::WebSocket> - Similar wrapper for WebSocket connections

L<PAGI::Server> - PAGI protocol server

=head1 AUTHOR

PAGI Contributors

=cut
