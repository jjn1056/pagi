package PAGI::Server::Protocol::HTTP2;
use strict;
use warnings;

=head1 NAME

PAGI::Server::Protocol::HTTP2 - HTTP/2 protocol handler using nghttp2

=head1 SYNOPSIS

    use PAGI::Server::Protocol::HTTP2;

    my $proto = PAGI::Server::Protocol::HTTP2->new;

    if ($proto->available) {
        my $session = $proto->create_session(
            on_request => sub { ... },
            on_body    => sub { ... },
            on_close   => sub { ... },
        );
    }

=head1 DESCRIPTION

PAGI::Server::Protocol::HTTP2 provides HTTP/2 support for PAGI::Server
using the nghttp2 C library via Net::HTTP2::nghttp2.

Unlike HTTP/1.1, HTTP/2 uses binary framing, multiplexed streams on a
single connection, HPACK header compression, and per-stream flow control.

This module bridges nghttp2's callback-based API to PAGI's event model.

=cut

# HTTP/2 client connection preface (RFC 9113 Section 3.4)
use constant H2_CLIENT_PREFACE => "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n";
use constant H2_PREFACE_LENGTH => 24;

# Check for nghttp2 availability
our $AVAILABLE;
use constant MIN_NGHTTP2_VERSION => '0.007';
BEGIN {
    $AVAILABLE = eval {
        require Net::HTTP2::nghttp2;
        Net::HTTP2::nghttp2->VERSION(MIN_NGHTTP2_VERSION);
        require Net::HTTP2::nghttp2::Session;
        Net::HTTP2::nghttp2->available;
    } ? 1 : 0;
}

sub available { return $AVAILABLE }

=head2 detect_preface

    if (PAGI::Server::Protocol::HTTP2->detect_preface($bytes)) { ... }

Returns true if C<$bytes> starts with the HTTP/2 client connection preface.
Used for h2c (cleartext HTTP/2) detection.

=cut

sub detect_preface {
    my ($class, $bytes) = @_;
    return 0 unless defined $bytes && length($bytes) >= H2_PREFACE_LENGTH;
    return substr($bytes, 0, H2_PREFACE_LENGTH) eq H2_CLIENT_PREFACE;
}

=head2 new

    my $proto = PAGI::Server::Protocol::HTTP2->new(
        max_concurrent_streams  => 100,    # Default
        initial_window_size     => 65535,  # Default
        max_frame_size          => 16384,  # Default
        enable_push             => 0,      # Default (disabled)
        enable_connect_protocol => 1,      # Default (enabled, RFC 8441)
        max_header_list_size    => 65536,  # Default (64KB)
    );

Creates a new HTTP/2 protocol handler with the specified settings.

=cut

sub new {
    my ($class, %args) = @_;

    my $self = bless {
        max_concurrent_streams  => $args{max_concurrent_streams} // 100,
        initial_window_size     => $args{initial_window_size} // 65535,
        max_frame_size          => $args{max_frame_size} // 16384,
        enable_push             => $args{enable_push} // 0,
        enable_connect_protocol => $args{enable_connect_protocol} // 1,
        max_header_list_size    => $args{max_header_list_size} // 65536,
    }, $class;

    return $self;
}

=head2 create_session

    my $session = $proto->create_session(
        on_request => sub { ($stream_id, $pseudo, $headers, $has_body) = @_ },
        on_body    => sub { ($stream_id, $data, $eof) = @_ },
        on_close   => sub { ($stream_id, $error_code) = @_ },
    );

Creates a new HTTP/2 session for a connection. Returns a
L<PAGI::Server::Protocol::HTTP2::Session> wrapper.

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
            max_concurrent_streams  => $self->{max_concurrent_streams},
            initial_window_size     => $self->{initial_window_size},
            max_frame_size          => $self->{max_frame_size},
            enable_push             => $self->{enable_push},
            enable_connect_protocol => $self->{enable_connect_protocol},
            max_header_list_size    => $self->{max_header_list_size},
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
        streams     => {},  # stream_id => { headers => [], pseudo => {}, ... }
        nghttp2     => undef,
    }, $class;

    weaken($self->{protocol});

    $self->_init_nghttp2_session;

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
                if (!defined $type || $type == Net::HTTP2::nghttp2::NGHTTP2_HEADERS()) {
                    $weak_self->{streams}{$stream_id} = {
                        headers          => [],
                        pseudo           => {},
                        header_list_size => 0,
                    };
                }
                return 0;
            },

            on_header => sub {
                my ($stream_id, $name, $value, $flags) = @_;
                return 0 unless $weak_self;

                my $stream = $weak_self->{streams}{$stream_id};
                return 0 unless $stream;

                # RFC 7541: header entry size = name_len + value_len + 32
                $stream->{header_list_size} += length($name) + length($value) + 32;
                if ($stream->{header_list_size} > $weak_self->{settings}{max_header_list_size}) {
                    delete $weak_self->{streams}{$stream_id};
                    return Net::HTTP2::nghttp2::NGHTTP2_ERR_TEMPORAL_CALLBACK_FAILURE();
                }

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

                # HEADERS frame = request headers complete
                if ($type == Net::HTTP2::nghttp2::NGHTTP2_HEADERS()) {
                    my $stream = $weak_self->{streams}{$stream_id};

                    # Reject HEADERS on a stream where client already sent END_STREAM
                    if ($stream && $stream->{client_end_stream}) {
                        return Net::HTTP2::nghttp2::NGHTTP2_ERR_TEMPORAL_CALLBACK_FAILURE();
                    }

                    if ($stream && $weak_self->{on_request}) {
                        my $headers = $stream->{headers};
                        my $pseudo  = $stream->{pseudo};

                        # Convert :authority pseudo-header to host header
                        # (RFC 9113 Section 8.3.1: :authority takes precedence)
                        if (defined $pseudo->{':authority'}) {
                            my $authority = $pseudo->{':authority'};
                            my $found_host = 0;
                            for my $h (@$headers) {
                                if ($h->[0] eq 'host') {
                                    $h->[1] = $authority;
                                    $found_host = 1;
                                    last;
                                }
                            }
                            push @$headers, ['host', $authority] unless $found_host;
                        }

                        # Normalize multiple cookie headers into one
                        # (matches HTTP/1.1 behavior in HTTP1.pm)
                        my @cookie_values;
                        my @non_cookie;
                        for my $h (@$headers) {
                            if ($h->[0] eq 'cookie') {
                                push @cookie_values, $h->[1];
                            } else {
                                push @non_cookie, $h;
                            }
                        }
                        if (@cookie_values > 1) {
                            push @non_cookie, ['cookie', join('; ', @cookie_values)];
                            @$headers = @non_cookie;
                        }

                        my $end_stream = $flags & Net::HTTP2::nghttp2::NGHTTP2_FLAG_END_STREAM();

                        # Track that client has finished sending on this stream
                        if ($end_stream) {
                            $stream->{client_end_stream} = 1;
                        }

                        $weak_self->{on_request}->(
                            $stream_id,
                            $pseudo,
                            $headers,
                            !$end_stream,  # has_body = not END_STREAM
                        );
                    }
                }

                # DATA frame with END_STREAM = body complete
                if ($type == Net::HTTP2::nghttp2::NGHTTP2_DATA()) {
                    my $end_stream = $flags & Net::HTTP2::nghttp2::NGHTTP2_FLAG_END_STREAM();
                    if ($end_stream) {
                        my $stream = $weak_self->{streams}{$stream_id};
                        $stream->{client_end_stream} = 1 if $stream;
                        if ($weak_self->{on_body}) {
                            $weak_self->{on_body}->($stream_id, '', 1);
                        }
                    }
                }

                return 0;
            },

            on_data_chunk_recv => sub {
                my ($stream_id, $data, $flags) = @_;
                return 0 unless $weak_self;

                # Reject DATA on a stream where client already sent END_STREAM
                my $stream = $weak_self->{streams}{$stream_id};
                if ($stream && $stream->{client_end_stream}) {
                    return Net::HTTP2::nghttp2::NGHTTP2_ERR_TEMPORAL_CALLBACK_FAILURE();
                }

                if ($weak_self->{on_body}) {
                    # END_STREAM comes in frame_recv, not here
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

    my $data = $session->extract;

Extract outgoing data from the session. Returns bytes to send.

=cut

sub extract {
    my ($self) = @_;
    return $self->{nghttp2}->mem_send;
}

=head2 want_read

    if ($session->want_read) { ... }

Check if session wants to read.

=cut

sub want_read {
    my ($self) = @_;
    return $self->{nghttp2}->want_read;
}

=head2 want_write

    if ($session->want_write) { ... }

Check if session has data to write.

=cut

sub want_write {
    my ($self) = @_;
    return $self->{nghttp2}->want_write;
}

=head2 submit_response

    $session->submit_response($stream_id,
        status  => 200,
        headers => [['content-type', 'text/html']],
        body    => $body,
    );

Submit a response on a stream. C<body> can be a string (sent as single
response) or a coderef for streaming.

=cut

sub submit_response {
    my ($self, $stream_id, %args) = @_;
    return $self->{nghttp2}->submit_response($stream_id, %args);
}

=head2 submit_response_streaming

    $session->submit_response_streaming($stream_id,
        status        => 200,
        headers       => [['content-type', 'text/event-stream']],
        data_callback => sub {
            my ($stream_id, $max_len) = @_;
            return ($chunk, $is_eof);
        },
    );

Submit a streaming response with a data provider callback.

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

=head2 submit_data

    $session->submit_data($stream_id, $data, $eof);

Push data directly onto a stream. Used for WebSocket frame delivery
over HTTP/2 where frames are sent as DATA payloads.

=cut

sub submit_data {
    my ($self, $stream_id, $data, $eof) = @_;
    return $self->{nghttp2}->submit_data($stream_id, $data, $eof);
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

=item * Multiplexing - Multiple concurrent requests on one TCP connection

=item * Binary Framing - nghttp2 handles all framing; PAGI feeds/extracts bytes

=item * Header Compression - HPACK is built into nghttp2

=item * Flow Control - Per-stream and connection-level, via streaming callbacks

=back

=head1 SEE ALSO

L<Net::HTTP2::nghttp2>, L<PAGI::Server::Protocol::HTTP1>

=cut
