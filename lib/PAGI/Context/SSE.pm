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
