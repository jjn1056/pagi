package PAGI::Context::SSE;

use strict;
use warnings;

our @ISA = ('PAGI::Context');

# ── Underlying PAGI::SSE accessor ────────────────────────────────────

sub sse {
    my ($self) = @_;
    return $self->{_sse} //= do {
        require PAGI::SSE;
        PAGI::SSE->new($self->{scope}, $self->{receive}, $self->{send});
    };
}

# ── Connection lifecycle ─────────────────────────────────────────────

sub start { shift->sse->start(@_) }
sub close { shift->sse->close(@_) }

# ── Send methods ─────────────────────────────────────────────────────

sub send         { shift->sse->send(@_) }
sub send_json    { shift->sse->send_json(@_) }
sub send_event   { shift->sse->send_event(@_) }
sub send_comment { shift->sse->send_comment(@_) }

sub try_send         { shift->sse->try_send(@_) }
sub try_send_json    { shift->sse->try_send_json(@_) }
sub try_send_comment { shift->sse->try_send_comment(@_) }
sub try_send_event   { shift->sse->try_send_event(@_) }

# ── Iteration helpers ────────────────────────────────────────────────

sub each  { shift->sse->each(@_) }
sub every { shift->sse->every(@_) }

# ── State inspection ─────────────────────────────────────────────────

sub is_started { shift->sse->is_started }
sub is_closed  { shift->sse->is_closed }

# ── Protocol metadata ────────────────────────────────────────────────

sub last_event_id { shift->sse->last_event_id }
sub http_version  { shift->sse->http_version }
sub keepalive     { shift->sse->keepalive(@_) }

# ── Query parameter accessors ────────────────────────────────────────
# SSE uses query_param (singular) vs WebSocket's query (method name
# mirrors what PAGI::SSE exposes).

sub query_param      { shift->sse->query_param(@_) }
sub query_params     { shift->sse->query_params(@_) }
sub raw_query_param  { shift->sse->raw_query_param(@_) }
sub raw_query_params { shift->sse->raw_query_params(@_) }

# ── Header extras ────────────────────────────────────────────────────

sub header_all { shift->sse->header_all(@_) }

1;

__END__

=head1 NAME

PAGI::Context::SSE - SSE context with protocol operations

=head1 SYNOPSIS

    use PAGI::Context;
    use Future::AsyncAwait;

    # Simple notification stream — $ctx is all you need
    async sub notifications {
        my ($scope, $receive, $send) = @_;

        my $ctx = PAGI::Context->new($scope, $receive, $send);

        await $ctx->keepalive(25);

        # Replay missed events on reconnect
        if (my $last_id = $ctx->last_event_id) {
            for my $evt (get_events_since($last_id)) {
                await $ctx->send_event(%$evt);
            }
        }

        # Periodic metrics push
        await $ctx->every(2, async sub {
            await $ctx->send_event(
                event => 'metrics',
                data  => get_metrics(),
            );
        });
    }

    # Event-dispatched with channels
    async sub dashboard {
        my ($scope, $receive, $send) = @_;

        my $ctx = PAGI::Context->new($scope, $receive, $send);

        await $ctx->start;
        await $ctx->keepalive(25);

        my $reason = await $ctx
            ->on('metrics.update', async sub {
                my ($ctx, $event) = @_;
                await $ctx->send_json($event);
            })
            ->on('alert.fired', async sub {
                my ($ctx, $event) = @_;
                await $ctx->send_event(
                    event => 'alert',
                    data  => $event,
                );
            })
            ->on_error(sub {
                my ($ctx, $err, $source) = @_;
                warn "[$source] $err";
            })
            ->run;
    }

=head1 DESCRIPTION

Returned by C<< PAGI::Context->new(...) >> when C<< $scope->{type} >> is
C<'sse'>.  Inherits all shared methods from L<PAGI::Context> (scope
accessors, stash, session, event dispatcher) and adds SSE protocol
operations delegated to L<PAGI::SSE>.

This means handler code can use a single C<$ctx> object for everything:
dispatching events with C<on()>/C<run()>, sending SSE events with
C<send_json()> or C<send_event()>, and reading query params with
C<query_param()>.

=head2 Underlying object access

    my $sse = $ctx->sse;

The underlying L<PAGI::SSE> object is still available if you need
direct access.  In most cases you should not need it.

=head2 Methods NOT delegated

The following L<PAGI::SSE> methods are B<not> available on C<$ctx>.
They are intentionally omitted because C<PAGI::Context> has its own
versions with different semantics:

=over 4

=item C<on()> — On C<$ctx>, this is the generic event dispatcher
(L<PAGI::Context/on>) that accepts any event type string.  On
L<PAGI::SSE>, it only dispatches C<close> and C<error>.

=item C<on_error()> — On C<$ctx>, callbacks receive C<($ctx, $error,
$source)>.  On L<PAGI::SSE>, they receive C<($sse, $error)>.

=item C<on_close()> — L<PAGI::SSE>-specific callback registration.
Use C<< $ctx->on('sse.disconnect', ...) >> instead.

=item C<run()> — On C<$ctx>, this is the generic event dispatch loop
(L<PAGI::Context/run>).  On L<PAGI::SSE>, it only waits for
disconnect.

=item C<state()> — On C<$ctx>, returns C<< $scope->{state} >> (app-level
shared state from lifespan).

=back

=head1 CONNECTION LIFECYCLE

=head2 start

    await $ctx->start;
    await $ctx->start(status => 200, headers => [...]);

Starts the SSE stream.  Called automatically on first C<send>.
Idempotent — only sends C<sse.start> once.

=head2 close

    $ctx->close;

Marks connection as closed and runs on_close callbacks.

=head1 SEND METHODS

=head2 send

    await $ctx->send("Hello world");

Sends a data-only SSE event.

=head2 send_json

    await $ctx->send_json({ type => 'update', data => $payload });

JSON-encodes data before sending.

=head2 send_event

    await $ctx->send_event(
        data  => $data,              # Required (auto JSON-encodes refs)
        event => 'notification',     # Optional event type
        id    => 'msg-123',          # Optional event ID
        retry => 5000,               # Optional reconnect hint (ms)
    );

Sends a full SSE event with all fields.

=head2 send_comment

    await $ctx->send_comment('keepalive');

Sends an SSE comment (does not trigger C<onmessage> in browsers).

=head2 try_send, try_send_json, try_send_comment, try_send_event

    my $ok = await $ctx->try_send_json($data);

Returns true on success, false on failure.  Does not throw.

=head1 ITERATION HELPERS

=head2 each

    await $ctx->each(\@items, async sub {
        my ($item, $index) = @_;
        await $ctx->send_json($item);
    });

Iterates over items (arrayref or coderef iterator), calling callback
for each.

=head2 every

    await $ctx->every(2, async sub {
        await $ctx->send_json(get_metrics());
    });

Periodic callback execution with interval delay.  Requires
L<Future::IO>.

=head1 STATE INSPECTION

=head2 is_started

    if ($ctx->is_started) { ... }

True after C<start()> or first send.

=head2 is_closed

    if ($ctx->is_closed) { ... }

True after close or disconnect.

=head2 last_event_id

    my $id = $ctx->last_event_id;

Returns the C<Last-Event-ID> header sent by reconnecting clients.

=head1 QUERY PARAMETERS

=head2 query_param

    my $value = $ctx->query_param('channel');
    my $value = $ctx->query_param('channel', strict => 1);

Returns a single query parameter value.

=head2 query_params

    my $params = $ctx->query_params;   # Hash::MultiValue

All query parameters as L<Hash::MultiValue>.

=head2 raw_query_param, raw_query_params

    my $val    = $ctx->raw_query_param('name');
    my $params = $ctx->raw_query_params;

Skip UTF-8 decoding.

=head1 HEADER EXTRAS

=head2 header_all

    my @accepts = $ctx->header_all('accept');

All values for a multi-value header.

=head2 http_version

    my $ver = $ctx->http_version;   # '1.1' or '2'

=head1 KEEPALIVE

=head2 keepalive

    await $ctx->keepalive(25);             # Comment every 25s
    await $ctx->keepalive(25, 'ping');     # Custom comment text

Enables SSE keepalive comments for proxy compatibility.

=head1 SEE ALSO

L<PAGI::Context>, L<PAGI::SSE>, L<PAGI::Context::WebSocket>,
L<PAGI::Context::HTTP>

=cut
