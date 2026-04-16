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
