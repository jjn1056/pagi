package PAGI::Server::Protocol::HTTP2;
use strict;
use warnings;

=head1 NAME

PAGI::Server::Protocol::HTTP2 - HTTP/2 protocol handler using nghttp2

=head1 SYNOPSIS

    use PAGI::Server::Protocol::HTTP2;

    my $proto = PAGI::Server::Protocol::HTTP2->new;

    # Check if HTTP/2 is available
    if ($proto->available) {
        # Create session for a connection
        my $session = $proto->create_session(
            on_request => sub { ... },
        );
    }

=head1 DESCRIPTION

PAGI::Server::Protocol::HTTP2 provides HTTP/2 support for PAGI::Server
using the nghttp2 C library via Net::HTTP2::nghttp2.

Unlike HTTP/1.1, HTTP/2 is fundamentally different:
- Binary framing instead of text
- Multiplexed streams on a single connection
- Header compression (HPACK)
- Flow control per-stream and per-connection
- Server push capability

This module bridges nghttp2's callback-based API to PAGI's event model.

=cut

our $VERSION = '0.001';

# Check for nghttp2 availability
our $AVAILABLE;
BEGIN {
    $AVAILABLE = eval {
        require Net::HTTP2::nghttp2;
        require Net::HTTP2::nghttp2::Session;
        Net::HTTP2::nghttp2->available;
    } ? 1 : 0;
}

sub available { return $AVAILABLE }

sub new {
    my ($class, %args) = @_;

    my $self = bless {
        max_concurrent_streams => $args{max_concurrent_streams} // 100,
        initial_window_size    => $args{initial_window_size} // 65535,
        max_frame_size         => $args{max_frame_size} // 16384,
        enable_push            => $args{enable_push} // 0,
    }, $class;

    return $self;
}

=head2 create_session

    my $h2_session = $proto->create_session(
        on_request  => sub { ($stream_id, $headers, $has_body) = @_; },
        on_body     => sub { ($stream_id, $data, $eof) = @_; },
        on_close    => sub { ($stream_id, $error_code) = @_; },
    );

Creates a new HTTP/2 session for a connection. Returns a
PAGI::Server::Protocol::HTTP2::Session wrapper.

=cut

sub create_session {
    my ($self, %callbacks) = @_;

    die "HTTP/2 not available (nghttp2 not installed)\n" unless $AVAILABLE;

    return PAGI::Server::Protocol::HTTP2::Session->new(
        protocol   => $self,
        on_request => $callbacks{on_request},
        on_body    => $callbacks{on_body},
        on_close   => $callbacks{on_close},
        settings   => {
            max_concurrent_streams => $self->{max_concurrent_streams},
            initial_window_size    => $self->{initial_window_size},
            max_frame_size         => $self->{max_frame_size},
            enable_push            => $self->{enable_push},
        },
    );
}

# =============================================================================
# HTTP/2 Session Wrapper
# =============================================================================

package PAGI::Server::Protocol::HTTP2::Session;
use strict;
use warnings;
use Scalar::Util qw(weaken);

sub new {
    my ($class, %args) = @_;

    my $self = bless {
        protocol    => $args{protocol},
        on_request  => $args{on_request},
        on_body     => $args{on_body},
        on_close    => $args{on_close},
        settings    => $args{settings},
        streams     => {},  # stream_id => { headers => [], ... }
        nghttp2     => undef,
    }, $class;

    weaken($self->{protocol});

    # Create nghttp2 session
    $self->_init_nghttp2_session();

    return $self;
}

sub _init_nghttp2_session {
    my ($self) = @_;

    my $weak_self = $self;
    weaken($weak_self);

    $self->{nghttp2} = Net::HTTP2::nghttp2::Session->new_server(
        callbacks => {
            on_begin_headers => sub {
                my ($stream_id, $type, $flags) = @_;
                return 0 unless $weak_self;

                # HEADERS frame starts a new request
                if ($type == Net::HTTP2::nghttp2::NGHTTP2_HEADERS()) {
                    $weak_self->{streams}{$stream_id} = {
                        headers     => [],
                        pseudo      => {},
                        body_chunks => [],
                        has_body    => 0,
                    };
                }
                return 0;
            },

            on_header => sub {
                my ($stream_id, $name, $value, $flags) = @_;
                return 0 unless $weak_self;

                my $stream = $weak_self->{streams}{$stream_id};
                return 0 unless $stream;

                # Pseudo-headers start with ':'
                if ($name =~ /^:/) {
                    $stream->{pseudo}{$name} = $value;
                } else {
                    push @{$stream->{headers}}, [$name, $value];
                }
                return 0;
            },

            on_frame_recv => sub {
                my ($frame) = @_;
                return 0 unless $weak_self;

                my $stream_id = $frame->{stream_id};
                my $type = $frame->{type};
                my $flags = $frame->{flags};

                # HEADERS frame with END_HEADERS = request headers complete
                if ($type == Net::HTTP2::nghttp2::NGHTTP2_HEADERS()) {
                    my $stream = $weak_self->{streams}{$stream_id};
                    if ($stream && $weak_self->{on_request}) {
                        my $end_stream = $flags & Net::HTTP2::nghttp2::NGHTTP2_FLAG_END_STREAM();
                        $weak_self->{on_request}->(
                            $stream_id,
                            $stream->{pseudo},
                            $stream->{headers},
                            !$end_stream,  # has_body = not END_STREAM
                        );
                    }
                }

                return 0;
            },

            on_data_chunk_recv => sub {
                my ($stream_id, $data, $flags) = @_;
                return 0 unless $weak_self;

                if ($weak_self->{on_body}) {
                    # Note: END_STREAM comes in frame_recv, not here
                    $weak_self->{on_body}->($stream_id, $data, 0);
                }
                return 0;
            },

            on_stream_close => sub {
                my ($stream_id, $error_code) = @_;
                return 0 unless $weak_self;

                if ($weak_self->{on_close}) {
                    $weak_self->{on_close}->($stream_id, $error_code);
                }

                # Clean up stream state
                delete $weak_self->{streams}{$stream_id};
                return 0;
            },
        },
    );

    # Send initial SETTINGS
    $self->{nghttp2}->send_connection_preface(%{$self->{settings}});
}

=head2 feed

    my $consumed = $session->feed($data);

Feed incoming data to the HTTP/2 session. Returns bytes consumed.

=cut

sub feed {
    my ($self, $data) = @_;
    return $self->{nghttp2}->mem_recv($data);
}

=head2 extract

    my $data = $session->extract();

Extract outgoing data from the session. Returns bytes to send.

=cut

sub extract {
    my ($self) = @_;
    return $self->{nghttp2}->mem_send();
}

=head2 want_read / want_write

    if ($session->want_read) { ... }
    if ($session->want_write) { ... }

Check if session wants to read or write.

=cut

sub want_read {
    my ($self) = @_;
    return $self->{nghttp2}->want_read();
}

sub want_write {
    my ($self) = @_;
    return $self->{nghttp2}->want_write();
}

=head2 submit_response

    $session->submit_response($stream_id,
        status  => 200,
        headers => [['content-type', 'text/html']],
        body    => $body,  # or data_callback for streaming
    );

Submit a response on a stream.

=cut

sub submit_response {
    my ($self, $stream_id, %args) = @_;
    return $self->{nghttp2}->submit_response($stream_id, %args);
}

=head2 submit_response_streaming

    $session->submit_response_streaming($stream_id,
        status  => 200,
        headers => [['content-type', 'text/event-stream']],
        data_callback => sub {
            my ($stream_id, $max_len) = @_;
            return ($chunk, $is_eof);
        },
    );

Submit a streaming response. The callback is called repeatedly
to produce body data.

=cut

sub submit_response_streaming {
    my ($self, $stream_id, %args) = @_;
    return $self->{nghttp2}->submit_response($stream_id,
        status        => $args{status},
        headers       => $args{headers},
        data_callback => $args{data_callback},
        callback_data => $args{callback_data},
    );
}

=head2 resume_stream

    $session->resume_stream($stream_id);

Resume a deferred stream after data becomes available.

=cut

sub resume_stream {
    my ($self, $stream_id) = @_;
    return $self->{nghttp2}->resume_stream($stream_id);
}

=head2 is_stream_deferred

    if ($session->is_stream_deferred($stream_id)) { ... }

Check if a stream is currently deferred (waiting for data).

=cut

sub is_stream_deferred {
    my ($self, $stream_id) = @_;
    return $self->{nghttp2}->is_stream_deferred($stream_id);
}

=head2 terminate

    $session->terminate($error_code);

Terminate the session with GOAWAY.

=cut

sub terminate {
    my ($self, $error_code) = @_;
    $error_code //= 0;  # NO_ERROR
    return $self->{nghttp2}->terminate_session($error_code);
}

1;

__END__

=head1 HTTP/2 vs HTTP/1.1

Key differences that affect PAGI integration:

=over 4

=item * Multiplexing

HTTP/2 supports multiple concurrent requests on a single TCP connection.
Each request is a "stream" with a unique ID. PAGI creates separate
scope/receive/send for each stream.

=item * Binary Framing

HTTP/2 uses binary frames instead of text. The nghttp2 library handles
all framing - PAGI just feeds bytes and extracts bytes.

=item * Header Compression

HPACK compression is built into nghttp2. Headers are represented the
same way as HTTP/1.1 (array of [name, value] pairs).

=item * Flow Control

HTTP/2 has per-stream and connection-level flow control. The streaming
callback mechanism (return undef to defer, call resume_stream later)
integrates with this.

=back

=head1 SEE ALSO

L<Net::HTTP2::nghttp2>, L<PAGI::Server::Protocol::HTTP1>

=cut
