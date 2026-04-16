package PAGI::Context;

use strict;
use warnings;
use Carp qw(croak);
use Scalar::Util qw(blessed);
use Future::AsyncAwait;
use Future;

=head1 NAME

PAGI::Context - Per-request context with protocol-specific subclasses

=head1 SYNOPSIS

    use PAGI::Context;
    use Future::AsyncAwait;

    # Factory returns the right subclass based on scope type
    my $ctx = PAGI::Context->new($scope, $receive, $send);

    # Shared methods (all protocol types)
    my $type  = $ctx->type;        # 'http', 'websocket', 'sse'
    my $path  = $ctx->path;
    my $stash = $ctx->stash;       # PAGI::Stash
    my $session = $ctx->session;   # PAGI::Session

    # WebSocket context — protocol ops directly on $ctx
    await $ctx->accept;
    await $ctx->send_json({ msg => 'hello' });
    my $text = await $ctx->receive_text;
    await $ctx->close;

    # SSE context — same idea
    await $ctx->send_event(event => 'update', data => $payload);
    await $ctx->keepalive(25);

    # Event dispatcher — works on any protocol type
    my $reason = await $ctx
        ->on('websocket.receive', async sub { ... })
        ->on('chat.message',      async sub { ... })
        ->on_error(sub { ... })
        ->run;    # returns 'disconnect', 'stop', or 'error'

    # Underlying protocol objects still available
    my $ws  = $ctx->websocket;     # PAGI::WebSocket (WS only)
    my $sse = $ctx->sse;           # PAGI::SSE (SSE only)
    my $req = $ctx->request;       # PAGI::Request (HTTP only)
    my $res = $ctx->response;      # PAGI::Response (HTTP only)

=head1 DESCRIPTION

PAGI::Context is a factory and base class that provides a unified entry
point for per-request context.  Calling C<< PAGI::Context->new(...) >>
inspects C<< $scope->{type} >> and returns the appropriate subclass:
L<PAGI::Context::HTTP>, L<PAGI::Context::WebSocket>, or
L<PAGI::Context::SSE>.

Shared methods (scope accessors, stash, session, event dispatcher) live
on the base class.  Protocol-specific methods are delegated from
subclasses so you can use C<$ctx> as your single object:

    # Instead of:
    my $ws = $ctx->websocket;
    await $ws->send_json($data);    # closes over $ws in every handler

    # Just do:
    await $ctx->send_json($data);   # $ctx is already in scope

=head2 Protocol Shape

Each context type has a different set of available methods.  Calling a
method that belongs to a different protocol type raises a standard Perl
C<Can't locate object method> error.

    Method              HTTP    WebSocket   SSE
    ──────────────────  ──────  ──────────  ──────
    request, response   yes     -           -
    method              yes     -           -
    accept              -       yes         -
    send_text           -       yes         -
    send_bytes          -       yes         -
    send_json           -       yes         yes
    send                -       -           yes
    send_event          -       -           yes
    send_comment        -       -           yes
    start               -       -           yes
    close               -       yes         yes
    query / query_param -       yes(query)  yes(query_param)
    is_connected        base*   WS override -
    is_closed           -       yes         yes
    is_started          -       -           yes
    keepalive           -       yes         yes
    each_text, etc.     -       yes         -
    each, every         -       -           yes

    *is_connected on WebSocket contexts checks WS handshake state,
     not the TCP-level pagi.connection that the base class uses.

See L<PAGI::Context::WebSocket> and L<PAGI::Context::SSE> for the
full method reference on each subclass.

=head1 EXTENSIBILITY

Override C<_type_map> to add or replace protocol types:

    package MyApp::Context;
    our @ISA = ('PAGI::Context');

    sub _type_map {
        my ($class) = @_;
        return {
            %{ $class->SUPER::_type_map },
            grpc => 'MyApp::Context::GRPC',
        };
    }

Override C<_resolve_class> for custom resolution logic beyond the type map.

=head1 CONSTRUCTOR

=head2 new

    my $ctx = PAGI::Context->new($scope, $receive, $send);

Factory constructor. Returns a subclass instance based on
C<< $scope->{type} >>. Defaults to HTTP if type is missing or unknown.

=cut

sub new {
    my ($class, $scope, $receive, $send) = @_;
    my $subclass = $class->_resolve_class($scope);
    return bless {
        scope   => $scope,
        receive => $receive,
        send    => $send,
    }, $subclass;
}

=head1 CLASS METHODS

=head2 _type_map

    my $map = PAGI::Context->_type_map;

Returns a hashref mapping scope type strings to subclass package names.
Override in a subclass to add or replace protocol types.

=cut

sub _type_map {
    return {
        http      => 'PAGI::Context::HTTP',
        websocket => 'PAGI::Context::WebSocket',
        sse       => 'PAGI::Context::SSE',
    };
}

=head2 _resolve_class

    my $class = PAGI::Context->_resolve_class($scope);

Resolves the scope to a subclass package name. Looks up
C<< $scope->{type} >> in C<_type_map>; defaults to the C<http> mapping
if the type is missing or unknown. Override for custom resolution logic.

=cut

sub _resolve_class {
    my ($class, $scope) = @_;
    my $type = $scope->{type} // 'http';
    return $class->_type_map->{$type} // $class->_type_map->{http};
}

=head1 METHODS

=head2 Scope Accessors

    $ctx->scope;          # raw $scope hashref
    $ctx->type;           # $scope->{type}
    $ctx->path;           # $scope->{path}
    $ctx->raw_path;       # $scope->{raw_path} // $scope->{path}
    $ctx->query_string;   # $scope->{query_string} // ''
    $ctx->scheme;         # $scope->{scheme} // 'http'
    $ctx->client;         # $scope->{client}
    $ctx->server;         # $scope->{server}
    $ctx->headers;        # $scope->{headers} arrayref of [name, value]

=cut

sub scope        { shift->{scope} }
sub type         { shift->{scope}{type} }
sub path         { shift->{scope}{path} }
sub raw_path     { my $s = shift; $s->{scope}{raw_path} // $s->{scope}{path} }
sub query_string { shift->{scope}{query_string} // '' }
sub scheme       { shift->{scope}{scheme} // 'http' }
sub client       { shift->{scope}{client} }
sub server       { shift->{scope}{server} }
sub headers      { shift->{scope}{headers} }

=head2 Path Parameters

    my $params = $ctx->path_params;           # hashref
    my $id     = $ctx->path_param('id');      # strict: dies if missing
    my $id     = $ctx->path_param('id', strict => 0);  # returns undef

C<path_params> returns the C<< $scope->{path_params} >> hashref (set by
the router), defaulting to C<{}> if not present.

C<path_param> returns a single parameter by name. By default it dies if
the key is not found (strict mode). Pass C<< strict => 0 >> to return
C<undef> for missing keys instead.

=cut

sub path_params {
    my ($self) = @_;
    return $self->{scope}{path_params} // {};
}

sub path_param {
    my ($self, $name, %opts) = @_;
    my $strict = exists $opts{strict} ? $opts{strict} : 1;
    my $params = $self->path_params;

    if ($strict && !exists $params->{$name}) {
        my @available = sort keys %$params;
        die "path_param '$name' not found. "
            . (@available ? "Available: " . join(', ', @available) : "No path params set")
            . "\n";
    }

    return $params->{$name};
}

=head2 Protocol Introspection

    $ctx->is_http;        # true if type eq 'http'
    $ctx->is_websocket;   # true if type eq 'websocket'
    $ctx->is_sse;         # true if type eq 'sse'

=cut

sub is_http      { (shift->{scope}{type} // '') eq 'http' }
sub is_websocket { (shift->{scope}{type} // '') eq 'websocket' }
sub is_sse       { (shift->{scope}{type} // '') eq 'sse' }

=head2 header

    my $value = $ctx->header('Content-Type');

Returns the last value for the named header (case-insensitive), or
C<undef> if not found.

=cut

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

=head2 receive

    my $receive = $ctx->receive;

Returns the raw C<$receive> coderef. Calling it returns a L<Future> that
resolves to the next protocol event hashref from the client.

    # Read an HTTP request body event
    my $event = await $ctx->receive->();
    # $event = { type => 'http.request', body => '...' }

    # Read a WebSocket message
    my $msg = await $ctx->receive->();
    # $msg = { type => 'websocket.receive', text => 'hello' }

Most users should prefer the protocol helpers (C<< $ctx->request >>,
C<< $ctx->websocket >>, C<< $ctx->sse >>) which handle the event
protocol internally. Use C<receive> only for raw protocol access.

=head2 send

    my $send = $ctx->send;

Returns the raw C<$send> coderef. Calling it with an event hashref
returns a L<Future> that resolves when the event has been sent.

    # Send an HTTP response (two events: start + body)
    await $ctx->send->({ type => 'http.response.start', status => 200,
                         headers => [['content-type', 'text/plain']] });
    await $ctx->send->({ type => 'http.response.body', body => 'Hello' });

    # Accept a WebSocket connection
    await $ctx->send->({ type => 'websocket.accept' });

Most users should prefer the protocol helpers (C<< $ctx->response >>,
C<< $ctx->websocket >>, C<< $ctx->sse >>) which build and send events
for you. Use C<send> only for raw protocol access.

=cut

sub receive { shift->{receive} }
sub send    { shift->{send} }

=head2 stash

    my $stash = $ctx->stash;   # PAGI::Stash instance

Returns a L<PAGI::Stash> wrapping C<< $scope->{'pagi.stash'} >>.
Lazy-constructed and cached.

=head2 session

    my $session = $ctx->session;   # PAGI::Session instance

Returns a L<PAGI::Session> wrapping C<< $scope->{'pagi.session'} >>.
Lazy-constructed and cached. Dies if session middleware has not run.
Use C<has_session> to check availability first.

=head2 has_session

    if ($ctx->has_session) {
        my $user_id = $ctx->session->get('user_id');
    }

Returns true if session middleware has populated C<< $scope->{'pagi.session'} >>.

=head2 state

    my $state = $ctx->state;   # hashref

Returns C<< $scope->{state} >> — the app/endpoint-level shared state.

=cut

sub stash {
    my ($self) = @_;
    return $self->{_stash} //= do {
        require PAGI::Stash;
        PAGI::Stash->new($self->{scope});
    };
}

sub session {
    my ($self) = @_;
    return $self->{_session} //= do {
        require PAGI::Session;
        PAGI::Session->new($self->{scope});
    };
}

sub has_session {
    my ($self) = @_;
    return exists $self->{scope}{'pagi.session'} ? 1 : 0;
}

sub state {
    my ($self) = @_;
    return $self->{scope}{state} // {};
}

=head2 Connection State

    $ctx->connection;           # PAGI::Server::ConnectionState object
    $ctx->is_connected;         # boolean
    $ctx->is_disconnected;      # boolean
    $ctx->disconnect_reason;    # string or undef
    $ctx->on_disconnect($cb);   # register callback

Delegates to C<< $scope->{'pagi.connection'} >>.

=cut

sub connection {
    my ($self) = @_;
    return $self->{scope}{'pagi.connection'};
}

sub is_connected {
    my ($self) = @_;
    my $conn = $self->connection;
    return 0 unless $conn;
    return $conn->is_connected;
}

sub is_disconnected {
    my ($self) = @_;
    return !$self->is_connected;
}

sub disconnect_reason {
    my ($self) = @_;
    my $conn = $self->connection;
    return undef unless $conn;
    return $conn->disconnect_reason;
}

sub on_disconnect {
    my ($self, $cb) = @_;
    my $conn = $self->connection;
    return unless $conn;
    $conn->on_disconnect($cb);
}

=head1 EVENT DISPATCHER

The event dispatcher provides a generic, protocol-agnostic way to handle
PAGI events.  It is most useful when the receive stream carries a mix of
protocol events and application-level events injected by middleware such
as C<PAGI::Middleware::Channels>.

    my $ctx = PAGI::Context->new($scope, $receive, $send);

    $ctx->on('websocket.receive', async sub {
        my ($ctx, $event) = @_;
        my $text = $event->{text} // '';
        await $ctx->send->({ type => 'websocket.send', text => "echo: $text" });
    });

    $ctx->on('chat.message', async sub {
        my ($ctx, $event) = @_;
        # handle a channel-injected event
    });

    $ctx->on_error(sub {
        my ($ctx, $error, $source) = @_;
        warn "[$source] $error";
    });

    my $reason = await $ctx->run;   # 'disconnect', 'stop', or 'error'

=head2 on

    $ctx->on($event_type, $callback);   # returns $ctx

Register a handler for a raw PAGI event type string.  Multiple handlers
may be registered for the same type; they are called in registration order.
Handlers receive C<($ctx, $event)>.  Handlers may be plain coderefs or
C<async sub>s; if a handler returns a L<Future>, C<run()> awaits it before
continuing.

Returns C<$ctx> for chaining.

=head2 on_error

    $ctx->on_error($callback);   # returns $ctx

Register an error callback.  It is called when C<$receive-E<gt>()> fails
(C<$source = 'receive'>) or when a registered handler throws (C<$source =
'handler'>).  Callbacks receive C<($ctx, $error, $source)>.

Multiple callbacks may be registered and are called in order.  Callbacks
may be C<async sub>s; if a callback returns a L<Future>, it is awaited.
If no callbacks are registered, errors are emitted via C<warn>.

Returns C<$ctx> for chaining.

    # Avoid circular references — weaken if the callback closes over $ctx
    use Scalar::Util qw(weaken);
    my $weak = $ctx;
    weaken $weak;
    $ctx->on_error(sub { my ($ctx, $err, $src) = @_; warn "[$src] $err" });

=head2 stop

    $ctx->stop;   # returns $ctx

Signal the C<run()> loop to exit cleanly after the current handler
finishes.  C<run()> will resolve with reason C<'stop'>.

Returns C<$ctx> for chaining.

=head2 run

    my $reason = await $ctx->run;

Start the event dispatch loop.  Reads events from the receive stream and
dispatches each to registered handlers.  The loop runs until one of:

=over 4

=item * The protocol's terminal disconnect event arrives (C<websocket.disconnect>,
C<sse.disconnect>, C<http.disconnect>) — resolves with C<'disconnect'>

=item * C<stop()> was called — resolves with C<'stop'>

=item * C<$receive-E<gt>()> fails — fires C<on_error> callbacks and resolves
with C<'error'>

=back

C<run()> always resolves successfully (never rejects).  The caller does
not need to C<catch> it.

Calling C<run()> a second time while already running throws synchronously.

When run() resolves, all registered handlers and error callbacks are
cleared to break closure-based reference cycles.

=cut

# ---------------------------------------------------------------------------
# Event dispatcher — on(), on_error(), stop(), run()
# ---------------------------------------------------------------------------

# Terminal event type by scope type (websocket.*, sse.*, http.* are reserved)
my %_TERMINAL = (
    websocket => 'websocket.disconnect',
    sse       => 'sse.disconnect',
    http      => 'http.disconnect',
);

sub _terminal_event_type {
    my ($self) = @_;
    return $_TERMINAL{ $self->type // '' };
}

# Register a handler for a raw PAGI event type string.
# Returns $self for chaining.
sub on {
    my ($self, $type, $cb) = @_;
    push @{ $self->{_handlers}{$type} }, $cb;
    return $self;
}

# Register an error handler. Called for both $receive->() failures
# (source='receive') and handler exceptions (source='handler').
# Returns $self for chaining.
sub on_error {
    my ($self, $cb) = @_;
    push @{ $self->{_on_error} }, $cb;
    return $self;
}

# Signal the run() loop to exit after the current handler finishes.
sub stop {
    my ($self) = @_;
    $self->{_stopped} = 1;
    return $self;
}

# Internal: fire error callbacks with ($ctx, $error, $source).
async sub _trigger_ctx_error {
    my ($self, $error, $source) = @_;

    for my $cb (@{ $self->{_on_error} }) {
        eval {
            my $r = $cb->($self, $error, $source);
            if (blessed($r) && $r->isa('Future')) {
                await $r;
            }
        };
        if ($@) {
            warn "PAGI::Context on_error callback error: $@";
        }
    }

    if (!@{ $self->{_on_error} }) {
        warn "PAGI::Context error ($source): $error";
    }
}

# Run the event dispatch loop.
# Always resolves (never rejects). Returns reason: 'disconnect', 'stop', 'error'.
async sub run {
    my ($self) = @_;

    croak "PAGI::Context run() called while already running"
        if $self->{_running};

    $self->{_running} = 1;
    $self->{_stopped} = 0;
    $self->{_on_error} //= [];

    my $reason   = 'stop';
    my $terminal = $self->_terminal_event_type;

    LOOP: while (!$self->{_stopped}) {
        my $event = eval { await $self->{receive}->() };
        if (my $err = $@) {
            await $self->_trigger_ctx_error($err, 'receive');
            $reason = 'error';
            last LOOP;
        }

        my $type = $event->{type} // '';

        # Snapshot before iterating — on() calls from inside a handler
        # must not affect the current iteration.
        my @handlers = @{ $self->{_handlers}{$type} // [] };

        if (@handlers) {
            for my $cb (@handlers) {
                eval {
                    my $r = $cb->($self, $event);
                    if (blessed($r) && $r->isa('Future')) {
                        await $r;
                    }
                };
                if (my $err = $@) {
                    await $self->_trigger_ctx_error($err, 'handler');
                }
            }
        } elsif ($ENV{PAGI_DEBUG} && !($terminal && $type eq $terminal)) {
            warn "PAGI::Context: unhandled event type '$type'\n";
        }

        if ($terminal && $type eq $terminal) {
            $reason = 'disconnect';
            last LOOP;
        }
    }

    $reason = 'stop' if $self->{_stopped} && $reason eq 'stop';

    # Clear callbacks to break any closure-based reference cycles.
    $self->{_handlers} = {};
    $self->{_on_error} = [];
    $self->{_running}  = 0;
    $self->{_stopped}  = 0;

    return $reason;
}

# Load subclasses
require PAGI::Context::HTTP;
require PAGI::Context::WebSocket;
require PAGI::Context::SSE;

1;

__END__

=head1 SEE ALSO

B<Protocol subclasses> (full method reference for each protocol):

L<PAGI::Context::HTTP>, L<PAGI::Context::WebSocket>, L<PAGI::Context::SSE>

B<Underlying protocol objects> (standalone use, or direct access via
C<< $ctx->websocket >>, C<< $ctx->sse >>, C<< $ctx->request >>,
C<< $ctx->response >>):

L<PAGI::WebSocket>, L<PAGI::SSE>, L<PAGI::Request>, L<PAGI::Response>

B<Shared services>:

L<PAGI::Stash>, L<PAGI::Session>

=cut
