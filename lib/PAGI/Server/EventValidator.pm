package PAGI::Server::EventValidator;

use strict;
use warnings;
use Carp qw(croak);

# =============================================================================
# PAGI::Server::EventValidator - Dev-mode event field validation
#
# Per main.mkdn: Servers must raise exceptions if events are missing required
# fields or event fields are of the wrong type.
#
# This module provides optional validation for PAGI events. Enable in dev mode
# for early bug detection; disable in production for zero overhead.
# =============================================================================

# =============================================================================
# HTTP Event Validation
# =============================================================================

sub validate_http_send {
    my ($event) = @_;
    my $type = $event->{type} // '';

    if ($type eq 'http.response.start') {
        _validate_http_response_start($event);
    }
    elsif ($type eq 'http.response.body') {
        _validate_http_response_body($event);
    }
    elsif ($type eq 'http.response.trailers') {
        _validate_http_response_trailers($event);
    }
    # http.fullflush has no required fields beyond type
}

sub _validate_http_response_start {
    my ($event) = @_;

    # status is required (Int)
    croak "http.response.start requires 'status' field"
        unless exists $event->{status};
    croak "http.response.start 'status' must be an integer"
        unless defined $event->{status} && $event->{status} =~ /^\d+$/;

    # headers must be ArrayRef if present
    if (exists $event->{headers} && defined $event->{headers}) {
        croak "http.response.start 'headers' must be an array reference"
            unless ref $event->{headers} eq 'ARRAY';
    }
}

sub _validate_http_response_body {
    my ($event) = @_;

    # Exactly one of body, file, or fh must be present
    my $has_body = exists $event->{body};
    my $has_file = exists $event->{file};
    my $has_fh = exists $event->{fh};
    my $count = $has_body + $has_file + $has_fh;

    croak "http.response.body requires exactly one of body/file/fh (got $count)"
        unless $count <= 1;  # 0 is OK - defaults to empty body

    # offset must be integer if present
    if (exists $event->{offset} && defined $event->{offset}) {
        croak "http.response.body 'offset' must be an integer"
            unless $event->{offset} =~ /^\d+$/;
    }

    # length must be integer if present
    if (exists $event->{length} && defined $event->{length}) {
        croak "http.response.body 'length' must be an integer"
            unless $event->{length} =~ /^\d+$/;
    }
}

sub _validate_http_response_trailers {
    my ($event) = @_;

    # headers must be ArrayRef if present
    if (exists $event->{headers} && defined $event->{headers}) {
        croak "http.response.trailers 'headers' must be an array reference"
            unless ref $event->{headers} eq 'ARRAY';
    }
}

# =============================================================================
# WebSocket Event Validation
# =============================================================================

sub validate_websocket_send {
    my ($event) = @_;
    my $type = $event->{type} // '';

    if ($type eq 'websocket.accept') {
        _validate_websocket_accept($event);
    }
    elsif ($type eq 'websocket.send') {
        _validate_websocket_send_event($event);
    }
    elsif ($type eq 'websocket.close') {
        _validate_websocket_close($event);
    }
    elsif ($type eq 'websocket.keepalive') {
        _validate_websocket_keepalive($event);
    }
}

sub _validate_websocket_accept {
    my ($event) = @_;

    # headers must be ArrayRef if present
    if (exists $event->{headers} && defined $event->{headers}) {
        croak "websocket.accept 'headers' must be an array reference"
            unless ref $event->{headers} eq 'ARRAY';
    }
}

sub _validate_websocket_send_event {
    my ($event) = @_;

    # Exactly one of bytes or text must be present
    my $has_bytes = exists $event->{bytes};
    my $has_text = exists $event->{text};
    my $count = $has_bytes + $has_text;

    croak "websocket.send requires exactly one of bytes/text (got $count)"
        unless $count == 1;
}

sub _validate_websocket_close {
    my ($event) = @_;

    # code must be integer if present
    if (exists $event->{code} && defined $event->{code}) {
        croak "websocket.close 'code' must be an integer"
            unless $event->{code} =~ /^\d+$/;
    }
}

sub _validate_websocket_keepalive {
    my ($event) = @_;

    # interval is required (Number)
    croak "websocket.keepalive requires 'interval' field"
        unless exists $event->{interval};
    croak "websocket.keepalive 'interval' must be a number"
        unless defined $event->{interval} && $event->{interval} =~ /^[\d.]+$/;
}

# =============================================================================
# SSE Event Validation
# =============================================================================

sub validate_sse_send {
    my ($event) = @_;
    my $type = $event->{type} // '';

    if ($type eq 'sse.start') {
        _validate_sse_start($event);
    }
    elsif ($type eq 'sse.send') {
        _validate_sse_send_event($event);
    }
    elsif ($type eq 'sse.comment') {
        _validate_sse_comment($event);
    }
    elsif ($type eq 'sse.keepalive') {
        _validate_sse_keepalive($event);
    }
    # http.fullflush has no required fields beyond type
}

sub _validate_sse_start {
    my ($event) = @_;

    # status must be integer if present
    if (exists $event->{status} && defined $event->{status}) {
        croak "sse.start 'status' must be an integer"
            unless $event->{status} =~ /^\d+$/;
    }

    # headers must be ArrayRef if present
    if (exists $event->{headers} && defined $event->{headers}) {
        croak "sse.start 'headers' must be an array reference"
            unless ref $event->{headers} eq 'ARRAY';
    }
}

sub _validate_sse_send_event {
    my ($event) = @_;

    # data is required (String)
    croak "sse.send requires 'data' field"
        unless exists $event->{data};
    croak "sse.send 'data' must be a string"
        unless defined $event->{data} && !ref $event->{data};
}

sub _validate_sse_comment {
    my ($event) = @_;

    # comment is required (String)
    croak "sse.comment requires 'comment' field"
        unless exists $event->{comment};
    croak "sse.comment 'comment' must be a string"
        unless defined $event->{comment} && !ref $event->{comment};
}

sub _validate_sse_keepalive {
    my ($event) = @_;

    # interval is required (Number)
    croak "sse.keepalive requires 'interval' field"
        unless exists $event->{interval};
    croak "sse.keepalive 'interval' must be a number"
        unless defined $event->{interval} && $event->{interval} =~ /^[\d.]+$/;
}

1;

__END__

=head1 NAME

PAGI::Server::EventValidator - Dev-mode event field validation

=head1 SYNOPSIS

    # Enable in PAGI::Server
    my $server = PAGI::Server->new(
        app => $app,
        validate_events => 1,  # Enable validation
    );

=head1 DESCRIPTION

This module provides optional validation for PAGI events. When enabled,
it validates that:

=over 4

=item * Required fields are present

=item * Field types are correct

=item * Mutually exclusive fields are handled properly

=back

Enable this in development to catch bugs early. Disable in production
for zero overhead.

=head1 FUNCTIONS

=head2 validate_http_send($event)

Validates HTTP send events: C<http.response.start>, C<http.response.body>,
C<http.response.trailers>.

=head2 validate_websocket_send($event)

Validates WebSocket send events: C<websocket.accept>, C<websocket.send>,
C<websocket.close>, C<websocket.keepalive>.

=head2 validate_sse_send($event)

Validates SSE send events: C<sse.start>, C<sse.send>, C<sse.comment>,
C<sse.keepalive>.

=head1 SEE ALSO

L<PAGI::Server>, L<PAGI::Server::Connection>

=cut
