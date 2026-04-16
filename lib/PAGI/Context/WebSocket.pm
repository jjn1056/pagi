package PAGI::Context::WebSocket;

use strict;
use warnings;

our @ISA = ('PAGI::Context');

# ── Underlying PAGI::WebSocket accessor ──────────────────────────────

sub websocket {
    my ($self) = @_;
    return $self->{_websocket} //= do {
        require PAGI::WebSocket;
        PAGI::WebSocket->new($self->{scope}, $self->{receive}, $self->{send});
    };
}

sub ws { shift->websocket }

# ── Connection lifecycle ─────────────────────────────────────────────

sub accept   { shift->ws->accept(@_) }
sub close    { shift->ws->close(@_) }

# ── Send methods ─────────────────────────────────────────────────────

sub send_text   { shift->ws->send_text(@_) }
sub send_bytes  { shift->ws->send_bytes(@_) }
sub send_json   { shift->ws->send_json(@_) }

sub try_send_text  { shift->ws->try_send_text(@_) }
sub try_send_bytes { shift->ws->try_send_bytes(@_) }
sub try_send_json  { shift->ws->try_send_json(@_) }

sub send_text_if_connected  { shift->ws->send_text_if_connected(@_) }
sub send_bytes_if_connected { shift->ws->send_bytes_if_connected(@_) }
sub send_json_if_connected  { shift->ws->send_json_if_connected(@_) }

# ── Receive methods ──────────────────────────────────────────────────

sub receive_text  { shift->ws->receive_text(@_) }
sub receive_bytes { shift->ws->receive_bytes(@_) }
sub receive_json  { shift->ws->receive_json(@_) }

# ── Iteration helpers ────────────────────────────────────────────────

sub each_message { shift->ws->each_message(@_) }
sub each_text    { shift->ws->each_text(@_) }
sub each_bytes   { shift->ws->each_bytes(@_) }
sub each_json    { shift->ws->each_json(@_) }

# ── State inspection ─────────────────────────────────────────────────
# is_connected overrides the base Context method (which checks TCP-level
# pagi.connection) to use WebSocket handshake state instead — that is
# what handler code actually cares about.

sub is_connected { shift->ws->is_connected }
sub is_closed    { shift->ws->is_closed }
sub close_code   { shift->ws->close_code }
sub close_reason { shift->ws->close_reason }

# ── Protocol metadata ────────────────────────────────────────────────

sub subprotocols { shift->ws->subprotocols }
sub http_version { shift->ws->http_version }
sub keepalive    { shift->ws->keepalive(@_) }

# ── Query parameter accessors ────────────────────────────────────────
# The base Context class has query_string but not parsed query access.
# These delegate to PAGI::WebSocket's Hash::MultiValue-based parsing.

sub query            { shift->ws->query(@_) }
sub query_params     { shift->ws->query_params(@_) }
sub raw_query        { shift->ws->raw_query(@_) }
sub raw_query_params { shift->ws->raw_query_params(@_) }

# ── Header extras ────────────────────────────────────────────────────
# Base Context has header() (single value). header_all() returns all
# values for multi-value headers like Cookie via Hash::MultiValue.

sub header_all { shift->ws->header_all(@_) }

1;

__END__

=head1 NAME

PAGI::Context::WebSocket - WebSocket context with protocol operations

=head1 SYNOPSIS

    use PAGI::Context;
    use Future::AsyncAwait;

    # Simple echo — $ctx is all you need
    async sub echo_handler {
        my ($scope, $receive, $send) = @_;

        my $ctx = PAGI::Context->new($scope, $receive, $send);
        await $ctx->accept;

        await $ctx->each_text(async sub {
            my ($text) = @_;
            await $ctx->send_text("Echo: $text");
        });
    }

    # Event-dispatched chat with channels
    async sub chat_handler {
        my ($scope, $receive, $send) = @_;

        my $ctx = PAGI::Context->new($scope, $receive, $send);

        my $room = $ctx->path_param('room', strict => 0) // 'general';
        my $user = $ctx->query('user') // 'anonymous';

        await $ctx->accept;

        my $reason = await $ctx
            ->on('websocket.receive', async sub {
                my ($ctx, $event) = @_;
                # handle incoming message
            })
            ->on('chat.message', async sub {
                my ($ctx, $event) = @_;
                await $ctx->send_json($event);
            })
            ->on_error(sub {
                my ($ctx, $err, $source) = @_;
                warn "[$source] $err";
            })
            ->run;
    }

=head1 DESCRIPTION

Returned by C<< PAGI::Context->new(...) >> when C<< $scope->{type} >> is
C<'websocket'>.  Inherits all shared methods from L<PAGI::Context>
(scope accessors, stash, session, event dispatcher) and adds WebSocket
protocol operations delegated to L<PAGI::WebSocket>.

This means handler code can use a single C<$ctx> object for everything:
dispatching events with C<on()>/C<run()>, sending messages with
C<send_json()>, reading query params with C<query()>, and so on.

=head2 Underlying object access

    my $ws = $ctx->websocket;   # or $ctx->ws

The underlying L<PAGI::WebSocket> object is still available if you need
direct access.  In most cases you should not need it.

=head2 Methods NOT delegated

The following L<PAGI::WebSocket> methods are B<not> available on
C<$ctx>.  They are intentionally omitted because C<PAGI::Context> has
its own versions with different semantics:

=over 4

=item C<on()> — On C<$ctx>, this is the generic event dispatcher
(L<PAGI::Context/on>) that accepts any event type string.  On
L<PAGI::WebSocket>, it is a Socket.IO-style dispatcher limited to
C<message>, C<close>, C<error>.

=item C<on_error()> — On C<$ctx>, callbacks receive C<($ctx, $error,
$source)>.  On L<PAGI::WebSocket>, they receive C<($error)>.

=item C<on_close()>, C<on_message()> — L<PAGI::WebSocket>-specific
callback registration.  Use C<< $ctx->on('websocket.disconnect', ...) >>
and C<< $ctx->on('websocket.receive', ...) >> instead.

=item C<run()> — On C<$ctx>, this is the generic event dispatch loop
(L<PAGI::Context/run>).  On L<PAGI::WebSocket>, it only dispatches
C<on_message> callbacks.

=item C<state()> — On C<$ctx>, returns C<< $scope->{state} >> (app-level
shared state from lifespan).  On L<PAGI::WebSocket>, same method
exists but could diverge in meaning.

=back

=head1 CONNECTION LIFECYCLE

=head2 accept

    await $ctx->accept;
    await $ctx->accept(subprotocol => 'chat');
    await $ctx->accept(headers => [['x-custom', 'value']]);

Accepts the WebSocket connection.  Optionally specify a subprotocol and
additional response headers.

=head2 close

    await $ctx->close;
    await $ctx->close(4000, 'Custom reason');

Closes the connection.  Default code is 1000 (normal closure).
Idempotent — calling multiple times only sends close once.

=head1 SEND METHODS

=head2 send_text, send_bytes, send_json

    await $ctx->send_text("Hello!");
    await $ctx->send_bytes("\x00\x01\x02");
    await $ctx->send_json({ action => 'greet', name => 'Alice' });

Send a message.  Dies if connection is closed.

=head2 try_send_text, try_send_bytes, try_send_json

    my $sent = await $ctx->try_send_json($data);

Returns true if sent, false if failed or closed.  Does not throw.
Useful for broadcasting to multiple clients.

=head2 send_text_if_connected, send_bytes_if_connected, send_json_if_connected

    await $ctx->send_json_if_connected($data);

Silent no-op if connection is closed.  Useful for fire-and-forget.

=head1 RECEIVE METHODS

=head2 receive_text, receive_bytes, receive_json

    my $text  = await $ctx->receive_text;
    my $bytes = await $ctx->receive_bytes;
    my $data  = await $ctx->receive_json;

Wait for a specific frame type, skipping others.  Returns C<undef> on
disconnect.  C<receive_json> dies on invalid JSON.

=head1 ITERATION HELPERS

=head2 each_message, each_text, each_bytes, each_json

    await $ctx->each_text(async sub {
        my ($text) = @_;
        await $ctx->send_text("Got: $text");
    });

Loop until disconnect, calling callback for each message.

=head1 STATE INSPECTION

=head2 is_connected

    if ($ctx->is_connected) { ... }

B<Overrides the base class method.>  Returns true if the WebSocket
handshake is complete and the connection is not yet closed.  The base
C<PAGI::Context> version checks the TCP-level C<pagi.connection>
object; this version checks WebSocket protocol state, which is what
handler code actually cares about.

=head2 is_closed

    if ($ctx->is_closed) { ... }

True after close or disconnect.

=head2 close_code, close_reason

    my $code   = $ctx->close_code;     # 1000, 4000, etc.
    my $reason = $ctx->close_reason;   # 'Normal closure'

Available after connection closes.

=head2 subprotocols

    my $protos = $ctx->subprotocols;   # ['chat', 'json']

Requested subprotocols from the client.

=head1 QUERY PARAMETERS

=head2 query

    my $value = $ctx->query('user');
    my $value = $ctx->query('page', strict => 1);

Returns a single query parameter value.  Accepts C<strict> and C<raw>
options.

=head2 query_params

    my $params = $ctx->query_params;   # Hash::MultiValue

All query parameters as L<Hash::MultiValue>.

=head2 raw_query, raw_query_params

    my $val    = $ctx->raw_query('name');
    my $params = $ctx->raw_query_params;

Skip UTF-8 decoding, return raw bytes after URL decoding.

=head1 HEADER EXTRAS

=head2 header_all

    my @cookies = $ctx->header_all('cookie');

All values for a multi-value header.  The base class C<header()> method
returns only the last value; C<header_all> returns all of them.

=head2 http_version

    my $ver = $ctx->http_version;   # '1.1' or '2'

=head1 KEEPALIVE

=head2 keepalive

    await $ctx->keepalive(30);        # Ping every 30 seconds
    await $ctx->keepalive(30, 20);    # Ping every 30s, pong timeout 20s

Enables WebSocket protocol-level ping/pong keepalive.

=head1 SEE ALSO

L<PAGI::Context>, L<PAGI::WebSocket>, L<PAGI::Context::SSE>,
L<PAGI::Context::HTTP>

=cut
