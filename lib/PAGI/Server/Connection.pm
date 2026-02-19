package PAGI::Server::Connection;
use strict;
use warnings;
use Future;
use Future::AsyncAwait;
use Scalar::Util qw(weaken refaddr);
use Protocol::WebSocket::Handshake::Server;
use Protocol::WebSocket::Frame;
use Digest::SHA qw(sha1_base64);
use Encode;
use URI::Escape qw(uri_unescape);
use IO::Async::Timer::Countdown;
use IO::Async::Timer::Periodic;
use Time::HiRes qw(gettimeofday tv_interval);
use PAGI::Server::AsyncFile;
use PAGI::Server::ConnectionState;


use constant FILE_CHUNK_SIZE => 65536;  # 64KB chunks for file streaming

# Per-second cache for CLF timestamp in access log (same pattern as HTTP1::format_date)
my $_cached_log_timestamp;
my $_cached_log_time = 0;

# =============================================================================
# Unrecognized Event Type Handler (PAGI spec compliance)
# =============================================================================
# Per main.mkdn: "Servers must raise exceptions if... The type field is unrecognized"

sub _unrecognized_event_type {
    my ($type, $protocol) = @_;
    die "Unrecognized event type '$type' for $protocol protocol\n";
}

# =============================================================================
# Header Validation (CRLF Injection Prevention)
# =============================================================================
# RFC 7230 Section 3.2.6: Field values MUST NOT contain CR or LF

sub _validate_header_value {
    my ($value) = @_;

    if ($value =~ /[\r\n\0]/) {
        die "Invalid header value: contains CR, LF, or null byte\n";
    }
    return $value;
}

sub _validate_header_name {
    my ($name) = @_;

    if ($name =~ /[\r\n\0]/) {
        die "Invalid header name: contains CR, LF, or null byte\n";
    }
    if ($name =~ /[[:cntrl:]]/) {
        die "Invalid header name: contains control characters\n";
    }
    return $name;
}

# RFC 6455 Section 11.3.4: Subprotocol must be a token (no whitespace, separators)
sub _validate_subprotocol {
    my ($value) = @_;

    if ($value =~ /[\r\n\0\s]/) {
        die "Invalid subprotocol: contains CR, LF, null, or whitespace\n";
    }
    # Token characters only (roughly)
    if ($value !~ /^[\w\-\.]+$/) {
        die "Invalid subprotocol: must be alphanumeric, dash, underscore, or dot\n";
    }
    return $value;
}

=head1 NAME

PAGI::Server::Connection - Per-connection state machine

=head1 SYNOPSIS

    # Internal use by PAGI::Server
    my $conn = PAGI::Server::Connection->new(
        stream     => $stream,
        app        => $app,
        protocol   => $protocol,
        server     => $server,
        extensions => {},
    );
    $conn->start;

=head1 DESCRIPTION

PAGI::Server::Connection manages the state machine for a single client
connection. It handles:

=over 4

=item * Request parsing via Protocol::HTTP1

=item * Scope creation for the application

=item * Event queue management for $receive and $send

=item * Protocol upgrades (WebSocket, SSE)

=item * SSE over HTTP/1.1 and HTTP/2

=item * Connection lifecycle and cleanup

=back

=cut

sub new {
    my ($class, %args) = @_;

    my $self = bless {
        stream        => $args{stream},
        app           => $args{app},
        protocol      => $args{protocol},
        server        => $args{server},
        extensions    => $args{extensions} // {},
        state         => $args{state} // {},
        tls_enabled   => $args{tls_enabled} // 0,
        timeout       => $args{timeout} // 60,  # Idle timeout in seconds
        request_timeout => $args{request_timeout} // 0,  # Request stall timeout in seconds (0 = disabled, default for performance)
        ws_idle_timeout => $args{ws_idle_timeout} // 0,   # WebSocket idle timeout (0 = disabled)
        sse_idle_timeout => $args{sse_idle_timeout} // 0,  # SSE idle timeout (0 = disabled)
        max_body_size     => $args{max_body_size},  # 0 = unlimited
        access_log        => $args{access_log},     # Filehandle for access logging
        _access_log_formatter => $args{_access_log_formatter},  # Pre-compiled format closure
        max_receive_queue => $args{max_receive_queue} // 1000,  # Max WebSocket receive queue size
        max_ws_frame_size => $args{max_ws_frame_size} // 65536,  # Max WebSocket frame size in bytes
        sync_file_threshold => $args{sync_file_threshold} // 65536,  # Threshold for sync file reads (default 64KB)
        validate_events => $args{validate_events} // 0,  # Dev-mode event validation (0 = disabled)
        # Send-side backpressure (watermarks in bytes)
        # Defaults match Python asyncio: 64KB high, 16KB low (high/4)
        write_high_watermark => $args{write_high_watermark} // 65536,   # 64KB - pause sending above this
        write_low_watermark  => $args{write_low_watermark}  // 16384,   # 16KB - resume sending below this
        _drain_waiters       => [],   # Pending Futures waiting for buffer drain
        _drain_check_active  => 0,    # Flag to prevent redundant on_outgoing_empty setup
        tls_info      => undef,  # Populated on first request if TLS
        buffer        => '',
        closed        => 0,
        response_started => 0,
        response_status  => undef,  # Track response status for logging
        _response_size   => 0,      # Track response body bytes for logging
        request_start    => undef,  # Track request start time for logging
        idle_timer    => undef,  # IO::Async::Timer for idle timeout
        stall_timer   => undef,  # IO::Async::Timer for request stall timeout
        ws_idle_timer => undef,  # IO::Async::Timer for WebSocket idle timeout
        sse_idle_timer => undef, # IO::Async::Timer for SSE idle timeout
        # Event queue for $receive
        receive_queue   => [],
        receive_pending => undef,
        # Track all pending receive Futures to cancel on close
        receive_futures => [],
        # Track request handling Future to prevent "lost future" warning
        request_future  => undef,
        # Idempotency guard for disconnect handling
        _disconnect_handled => 0,
        # WebSocket state
        websocket_mode    => 0,
        websocket_frame   => undef,  # Protocol::WebSocket::Frame for parsing
        websocket_accepted => 0,
        # SSE state
        sse_mode          => 0,
        sse_started       => 0,
        sse_disconnect_reason => undef,  # Reason for SSE disconnect (client_closed, write_error, etc.)
        # Keepalive state (protocol-level ping/pong for WebSocket, comments for SSE)
        ws_keepalive_timer  => undef,  # Periodic timer for sending WebSocket pings
        ws_pong_timeout     => undef,  # Timeout timer for pong response
        ws_waiting_pong     => 0,      # Flag: are we waiting for a pong?
        ws_keepalive_interval => 0,    # Current keepalive interval (0 = disabled)
        ws_keepalive_timeout  => 0,    # Current pong timeout (0 = no timeout check)
        sse_keepalive_timer => undef,  # Periodic timer for sending SSE keepalive comments
        sse_keepalive_comment => '',   # Comment text to send
        # HTTP/2 state
        alpn_protocol     => $args{alpn_protocol},    # ALPN-negotiated protocol (e.g. 'h2', 'http/1.1')
        h2_protocol       => $args{h2_protocol},      # PAGI::Server::Protocol::HTTP2 instance
        h2c_enabled       => $args{h2c_enabled} // 0, # Allow h2c preface detection on cleartext
        is_h2             => 0,                        # Set during start() if HTTP/2 detected
        h2_session        => undef,                    # PAGI::Server::Protocol::HTTP2::Session
        h2_streams        => {},                       # Per-stream state for HTTP/2
        # Cached connection info (populated in start(), used by _create_scope)
        client_host       => '127.0.0.1',
        client_port       => 0,
        server_host       => '127.0.0.1',
        server_port       => 5000,
    }, $class;

    # Extract TLS info if this is a TLS connection
    if ($self->{tls_enabled}) {
        $self->_extract_tls_info;
    }

    return $self;
}

use Socket qw(IPPROTO_TCP TCP_NODELAY);

sub start {
    my ($self) = @_;

    my $stream = $self->{stream};
    weaken(my $weak_self = $self);

    # Enable TCP_NODELAY to reduce latency for small responses
    my $handle = $stream->write_handle // $stream->read_handle;
    if ($handle && $handle->can('setsockopt')) {
        eval {
            $handle->setsockopt(IPPROTO_TCP, TCP_NODELAY, 1);
        };
        # Ignore errors - not all sockets support this
    }

    # Cache connection info once (avoids per-request socket method calls)
    if ($handle && $handle->can('peerhost')) {
        eval {
            $self->{client_host} = $handle->peerhost // '127.0.0.1';
            $self->{client_port} = $handle->peerport // 0;
            $self->{server_host} = $handle->sockhost // '127.0.0.1';
            $self->{server_port} = $handle->sockport // 5000;
        };
        # Ignore errors - keep defaults if extraction fails
    }

    # Detect HTTP/2 via ALPN negotiation
    if ($self->{alpn_protocol} && $self->{alpn_protocol} eq 'h2' && $self->{h2_protocol}) {
        $self->_init_h2_session;
    }

    # Set up idle timeout timer
    if ($self->{timeout} && $self->{timeout} > 0 && $self->{server}) {
        my $timer = IO::Async::Timer::Countdown->new(
            delay => $self->{timeout},
            on_expire => sub {
                return unless $weak_self;
                return if $weak_self->{closed};
                # Close idle connection
                $weak_self->_handle_disconnect_and_close('idle_timeout');
            },
        );
        $self->{idle_timer} = $timer;
        $self->{server}->add_child($timer);
        $timer->start;
    }

    # Set up read handler
    $stream->configure(
        on_read => sub  {
        my ($s, $buffref, $eof) = @_;
            return 0 unless $weak_self;

            # Reset idle timer on any read activity
            $weak_self->_reset_idle_timer;

            # Reset stall timer on read activity (if handling a request)
            $weak_self->_reset_stall_timer if $weak_self->{handling_request};

            $weak_self->{buffer} .= $$buffref;
            $$buffref = '';

            if ($eof) {
                # EOF means client closed - handle disconnect and cleanup
                $weak_self->_handle_disconnect_and_close('client_closed');
                return 0;
            }

            # h2c detection: check if cleartext connection starts with HTTP/2 preface
            if ($weak_self->{h2c_enabled} && !$weak_self->{is_h2}) {
                if (length($weak_self->{buffer}) >= 24) {  # HTTP/2 preface is 24 bytes
                    if ($weak_self->{h2_protocol} && PAGI::Server::Protocol::HTTP2->detect_preface($weak_self->{buffer})) {
                        $weak_self->_init_h2_session;
                        $weak_self->{h2c_enabled} = 0;  # Detection done
                    } else {
                        $weak_self->{h2c_enabled} = 0;  # Not h2c, stop checking
                    }
                } else {
                    # Not enough data yet to determine protocol, wait for more
                    return 0;
                }
            }

            # Wrap processing in eval to prevent exceptions from crashing the event loop
            # This is critical - Protocol::WebSocket::Frame can throw exceptions for
            # oversized payloads, and other parsing code may throw as well
            eval {
                # HTTP/2: feed data to session for frame processing
                if ($weak_self->{is_h2}) {
                    $weak_self->_h2_process_data;
                    return;
                }

                # If in WebSocket mode, process WebSocket frames
                if ($weak_self->{websocket_mode}) {
                    $weak_self->_process_websocket_frames;
                    return;
                }

                # If we're waiting for body data, notify the receive handler
                if ($weak_self->{receive_pending} && !$weak_self->{receive_pending}->is_ready) {
                    my $f = $weak_self->{receive_pending};
                    $weak_self->{receive_pending} = undef;
                    $f->done;
                }

                $weak_self->_try_handle_request;
            };
            if (my $error = $@) {
                # Log the error and close the connection gracefully
                warn "PAGI connection error: $error";
                return 0 unless $weak_self;
                $weak_self->_handle_disconnect_and_close('server_error');
            }
            return 0;
        },
        on_closed => sub {
            return unless $weak_self;
            # Stream closed - handle disconnect and remove from connections hash
            $weak_self->_handle_disconnect_and_close('client_closed');
        },
    );
}

sub _reset_idle_timer {
    my ($self) = @_;

    return unless $self->{idle_timer};
    $self->{idle_timer}->reset;
    $self->{idle_timer}->start unless $self->{idle_timer}->is_running;
}

sub _stop_idle_timer {
    my ($self) = @_;

    return unless $self->{idle_timer};
    $self->{idle_timer}->stop if $self->{idle_timer}->is_running;
    # Remove timer completely so _reset_idle_timer won't restart it
    # This is important for long-lived connections (WebSocket, SSE)
    if ($self->{server}) {
        $self->{server}->remove_child($self->{idle_timer});
    }
    $self->{idle_timer} = undef;
}

# =============================================================================
# HTTP/2 Session Initialization
# =============================================================================

sub _init_h2_session {
    my ($self) = @_;

    $self->{is_h2} = 1;

    weaken(my $weak_self = $self);

    $self->{h2_session} = $self->{h2_protocol}->create_session(
        on_request => sub {
            my ($stream_id, $pseudo, $headers, $has_body) = @_;
            return unless $weak_self;
            $weak_self->_h2_on_request($stream_id, $pseudo, $headers, $has_body);
        },
        on_body => sub {
            my ($stream_id, $data, $eof) = @_;
            return unless $weak_self;
            $weak_self->_h2_on_body($stream_id, $data, $eof);
        },
        on_close => sub {
            my ($stream_id, $error_code) = @_;
            return unless $weak_self;
            $weak_self->_h2_on_close($stream_id, $error_code);
        },
    );

    # Send initial SETTINGS to client
    $self->_h2_write_pending;
}

sub _h2_process_data {
    my ($self) = @_;
    return unless $self->{h2_session};

    if (length($self->{buffer}) > 0) {
        $self->{h2_session}->feed($self->{buffer});
        $self->{buffer} = '';
    }

    $self->_h2_write_pending;

    # Close connection when session is done (GOAWAY received or sent)
    if ($self->{h2_session} && !$self->{h2_session}->want_read) {
        $self->_h2_write_pending;  # Flush any remaining output
        $self->_handle_disconnect_and_close;
    }
}

sub _h2_write_pending {
    my ($self) = @_;
    return unless $self->{h2_session};
    while (1) {
        my $data = $self->{h2_session}->extract;
        last unless defined $data && length($data) > 0;
        $self->{stream}->write($data);
    }
}

# =============================================================================
# HTTP/2 Stream Callbacks
# =============================================================================

sub _h2_on_request {
    my ($self, $stream_id, $pseudo, $headers, $has_body) = @_;

    # Detect CONNECT method
    my $is_websocket = 0;
    if (($pseudo->{':method'} // '') eq 'CONNECT') {
        if (($pseudo->{':protocol'} // '') eq 'websocket') {
            # Extended CONNECT for WebSocket (RFC 8441)
            $is_websocket = 1;
        } else {
            # Plain CONNECT not supported — defer response to avoid
            # re-entrant nghttp2 calls (we're inside feed/mem_recv)
            weaken(my $ws = $self);
            $self->{server}->loop->later(sub {
                return unless $ws;
                return if $ws->{closed};
                $ws->{h2_session}->submit_response($stream_id,
                    status  => 501,
                    headers => [['content-type', 'text/plain']],
                    body    => "CONNECT method not supported\n",
                );
                $ws->_h2_write_pending;
            });
            return;
        }
    }

    # Detect SSE (Accept: text/event-stream)
    my $is_sse = 0;
    if (!$is_websocket) {
        for my $h (@$headers) {
            if ($h->[0] eq 'accept' && $h->[1] =~ m{text/event-stream}) {
                $is_sse = 1;
                last;
            }
        }
    }

    # Initialize per-stream state
    $self->{h2_streams}{$stream_id} = {
        pseudo    => $pseudo,
        headers   => $headers,
        has_body  => $has_body,
        body      => '',
        body_complete => !$has_body,
        body_pending  => undef,   # Future for body availability
        receive_queue => [],
        response_started => 0,
        is_websocket => $is_websocket,
        is_sse       => $is_sse,
        ws_accepted  => 0,
        ws_frame     => undef,   # Protocol::WebSocket::Frame for parsing
        ws_connect_sent => 0,
    };

    # Check Content-Length against max_body_size limit before dispatching
    # (after stream init so _h2_on_body/_h2_on_close can find the stream)
    if ($self->{max_body_size} && $has_body) {
        for my $h (@$headers) {
            if ($h->[0] eq 'content-length') {
                if ($h->[1] > $self->{max_body_size}) {
                    # Defer response to avoid re-entrant nghttp2 calls
                    weaken(my $ws = $self);
                    $self->{server}->loop->later(sub {
                        return unless $ws;
                        return if $ws->{closed};
                        $ws->{h2_session}->submit_response($stream_id,
                            status  => 413,
                            headers => [['content-type', 'text/plain']],
                            body    => "Payload Too Large\n",
                        );
                        $ws->_h2_write_pending;
                    });
                    return;
                }
                last;
            }
        }
    }

    # Defer dispatch to next event loop tick to prevent re-entrant nghttp2 calls
    weaken(my $weak_self = $self);
    $self->{server}->loop->later(sub {
        return unless $weak_self;
        return if $weak_self->{closed};
        $weak_self->_h2_dispatch_stream($stream_id);
    });
}

sub _h2_on_body {
    my ($self, $stream_id, $data, $eof) = @_;

    my $stream = $self->{h2_streams}{$stream_id};
    return unless $stream;

    if ($stream->{is_websocket} && $stream->{ws_accepted}) {
        # WebSocket: DATA frames contain raw WebSocket frames
        $self->_h2_process_ws_frames($stream_id, $stream, $data) if length($data);

        if ($eof) {
            # END_STREAM = client closing the WebSocket stream
            push @{$stream->{receive_queue}}, {
                type   => 'websocket.disconnect',
                code   => 1005,
                reason => '',
            };
            $self->_h2_wake_pending($stream);
        }
        return;
    }

    if (length($data) > 0) {
        $stream->{body} .= $data;

        # Enforce max_body_size (0 = unlimited)
        if ($self->{max_body_size} && length($stream->{body}) > $self->{max_body_size}) {
            $self->{h2_session}->submit_response($stream_id,
                status  => 413,
                headers => [['content-type', 'text/plain']],
                body    => 'Payload Too Large',
            );
            # No _h2_write_pending here — we're inside feed(); _h2_process_data
            # flushes after feed() returns
            delete $self->{h2_streams}{$stream_id};
            return;
        }
    }

    if ($eof) {
        $stream->{body_complete} = 1;
    }

    $self->_h2_wake_pending($stream);
}

sub _h2_wake_pending {
    my ($self, $stream) = @_;
    if ($stream->{body_pending} && !$stream->{body_pending}->is_ready) {
        my $f = $stream->{body_pending};
        $stream->{body_pending} = undef;
        $f->done;
    }
}

sub _h2_on_close {
    my ($self, $stream_id, $error_code) = @_;

    my $stream = $self->{h2_streams}{$stream_id};
    return unless $stream;

    # Mark body complete to unblock any pending receive
    $stream->{body_complete} = 1;

    # Enqueue disconnect event
    if ($stream->{is_websocket}) {
        push @{$stream->{receive_queue}}, {
            type   => 'websocket.disconnect',
            code   => 1006,
            reason => '',
        };
    } elsif ($stream->{is_sse}) {
        push @{$stream->{receive_queue}}, {
            type   => 'sse.disconnect',
            reason => 'client_closed',
        };
    } else {
        push @{$stream->{receive_queue}}, { type => 'http.disconnect' };
    }

    $self->_h2_wake_pending($stream);

    # Clean up after a delay (let any pending futures resolve)
    weaken(my $weak_self = $self);
    $self->{server}->loop->later(sub {
        return unless $weak_self;
        delete $weak_self->{h2_streams}{$stream_id};
    });
}

# =============================================================================
# HTTP/2 Stream Dispatch (scope/receive/send creation)
# =============================================================================

sub _h2_dispatch_stream {
    my ($self, $stream_id) = @_;

    my $stream_state = $self->{h2_streams}{$stream_id};
    return unless $stream_state;

    my ($scope, $receive, $send);

    if ($stream_state->{is_websocket}) {
        $scope   = $self->_h2_create_websocket_scope($stream_id, $stream_state);
        $receive = $self->_h2_create_websocket_receive($stream_id, $stream_state);
        $send    = $self->_h2_create_websocket_send($stream_id, $stream_state);
    } elsif ($stream_state->{is_sse}) {
        $scope   = $self->_h2_create_sse_scope($stream_id, $stream_state);
        $receive = $self->_h2_create_sse_receive($stream_id, $stream_state);
        $send    = $self->_h2_create_sse_send($stream_id, $stream_state);
    } else {
        $scope   = $self->_h2_create_scope($stream_id, $stream_state);
        $receive = $self->_h2_create_receive($stream_id, $stream_state);
        $send    = $self->_h2_create_send($stream_id, $stream_state);
    }

    weaken(my $weak_self = $self);

    my $future = (async sub {
        eval {
            await $weak_self->{app}->($scope, $receive, $send);
        };
        if (my $error = $@) {
            warn "PAGI application error (HTTP/2 stream $stream_id): $error\n";
            if ($weak_self && !$stream_state->{response_started}) {
                eval {
                    $weak_self->{h2_session}->submit_response($stream_id,
                        status  => 500,
                        headers => [['content-type', 'text/plain']],
                        body    => "Internal Server Error\n",
                    );
                    $weak_self->_h2_write_pending;
                };
            }
        }

        # Notify server that request completed (for max_requests tracking)
        $weak_self->{server}->_on_request_complete if $weak_self && $weak_self->{server};
    })->();

    $self->{server}->adopt_future($future);
}

sub _h2_create_scope {
    my ($self, $stream_id, $stream_state) = @_;

    my $pseudo  = $stream_state->{pseudo};
    my $headers = $stream_state->{headers};

    # Parse path and query string from :path pseudo-header
    my $full_path = $pseudo->{':path'} // '/';
    my ($path, $query_string) = split(/\?/, $full_path, 2);
    $query_string //= '';

    # Decode percent-encoded path for scope (keep raw_path as-is)
    # Match HTTP/1.1 pipeline: URI::Escape + UTF-8 decode with fallback
    my $unescaped = uri_unescape($path);
    my $decoded_path = eval { decode('UTF-8', $unescaped, Encode::FB_CROAK) }
                       // $unescaped;

    my $connection_state = PAGI::Server::ConnectionState->new(
        connection => $self,
    );

    return {
        type         => 'http',
        pagi         => {
            version      => '0.2',
            spec_version => '0.2',
            features     => {},
        },
        http_version => '2',
        method       => $pseudo->{':method'} // 'GET',
        scheme       => $pseudo->{':scheme'} // $self->_get_scheme,
        path         => $decoded_path,
        raw_path     => $path,
        query_string => $query_string,
        root_path    => '',
        headers      => $headers,
        client       => [$self->{client_host}, $self->{client_port}],
        server       => [$self->{server_host}, $self->{server_port}],
        state        => keys %{$self->{state}} ? { %{$self->{state}} } : {},
        extensions   => $self->_get_extensions_for_scope,
        'pagi.connection' => $connection_state,
    };
}

sub _h2_create_receive {
    my ($self, $stream_id, $stream_state) = @_;

    weaken(my $weak_self = $self);

    return sub {
        return Future->done({ type => 'http.disconnect' }) unless $weak_self;
        return Future->done({ type => 'http.disconnect' }) if $weak_self->{closed};

        my $ss = $weak_self->{h2_streams}{$stream_id};
        return Future->done({ type => 'http.disconnect' }) unless $ss;

        my $future = (async sub {
            return { type => 'http.disconnect' } unless $weak_self;

            my $ss = $weak_self->{h2_streams}{$stream_id};
            return { type => 'http.disconnect' } unless $ss;

            # Check queue first
            if (@{$ss->{receive_queue}}) {
                return shift @{$ss->{receive_queue}};
            }

            # If body is already complete, return final body event
            if ($ss->{body_complete}) {
                my $body = $ss->{body};
                $ss->{body} = '';
                return {
                    type => 'http.request',
                    body => $body,
                    more => 0,
                };
            }

            # Wait for body data
            if (!$ss->{body_pending}) {
                $ss->{body_pending} = Future->new;
            }
            await $ss->{body_pending};

            # Re-fetch stream state (may have changed)
            $ss = $weak_self->{h2_streams}{$stream_id};
            return { type => 'http.disconnect' } unless $ss;

            # Check queue after waking
            if (@{$ss->{receive_queue}}) {
                return shift @{$ss->{receive_queue}};
            }

            my $body = $ss->{body};
            $ss->{body} = '';
            return {
                type => 'http.request',
                body => $body,
                more => $ss->{body_complete} ? 0 : 1,
            };
        })->();

        return $future;
    };
}

sub _h2_create_send {
    my ($self, $stream_id, $stream_state) = @_;

    weaken(my $weak_self = $self);

    my $status;
    my @response_headers;

    # Streaming state for deferred data provider pattern
    my @data_queue;
    my $eof_pending = 0;
    my $streaming_started = 0;

    # Data callback for nghttp2's streaming response.
    # Returns ($data, $eof) when data is available, or undef to defer.
    my $data_callback = sub {
        my ($cb_stream_id, $max_len) = @_;

        if (@data_queue) {
            my $chunk = shift @data_queue;
            # Respect max_len — XS truncates without preserving remainder
            if (length($chunk) > $max_len) {
                unshift @data_queue, substr($chunk, $max_len);
                $chunk = substr($chunk, 0, $max_len);
            }
            my $eof = (!@data_queue && $eof_pending) ? 1 : 0;
            return ($chunk, $eof);
        }

        # Queue empty but EOF pending — signal end of stream
        if ($eof_pending) {
            return ('', 1);
        }

        # Queue empty, more data expected — defer (NGHTTP2_ERR_DEFERRED in C layer)
        return undef;
    };

    return async sub {
        my ($event) = @_;
        return unless $weak_self;
        return if $weak_self->{closed};

        my $type = $event->{type} // '';

        if ($type eq 'http.response.start') {
            my $ss = $weak_self->{h2_streams}{$stream_id} or return;
            return if $ss->{response_started};
            $ss->{response_started} = 1;

            $status = $event->{status} // 200;
            @response_headers = map {
                [_validate_header_name($_->[0]), _validate_header_value($_->[1])]
            } @{$event->{headers} // []};
        }
        elsif ($type eq 'http.response.body') {
            my $ss = $weak_self->{h2_streams}{$stream_id} or return;
            return unless $ss->{response_started};

            my $body = $event->{body} // '';
            my $more = $event->{more} // 0;

            if ($more) {
                if (!$streaming_started) {
                    # First streaming chunk — submit with data callback
                    $streaming_started = 1;
                    push @data_queue, $body if length($body);
                    $weak_self->{h2_session}->submit_response_streaming(
                        $stream_id,
                        status        => $status,
                        headers       => \@response_headers,
                        data_callback => $data_callback,
                    );
                    $weak_self->_h2_write_pending;
                } else {
                    # Subsequent chunk — backpressure check then push and resume
                    if ($weak_self->_get_write_buffer_size >= $weak_self->{write_high_watermark}) {
                        await $weak_self->_wait_for_drain;
                        return unless $weak_self;
                        return if $weak_self->{closed};
                        return unless $weak_self->{h2_streams}{$stream_id};
                    }
                    push @data_queue, $body if length($body);
                    $weak_self->{h2_session}->resume_stream($stream_id);
                    $weak_self->_h2_write_pending;
                }
            } else {
                if ($streaming_started) {
                    # Final chunk on an already-streaming response
                    if ($weak_self->_get_write_buffer_size >= $weak_self->{write_high_watermark}) {
                        await $weak_self->_wait_for_drain;
                        return unless $weak_self;
                        return if $weak_self->{closed};
                        return unless $weak_self->{h2_streams}{$stream_id};
                    }
                    $eof_pending = 1;
                    push @data_queue, $body if length($body);
                    $weak_self->{h2_session}->resume_stream($stream_id);
                    $weak_self->_h2_write_pending;
                } else {
                    # Non-streaming: single response (unchanged one-shot path)
                    $weak_self->{h2_session}->submit_response($stream_id,
                        status  => $status,
                        headers => \@response_headers,
                        body    => $body,
                    );
                    $weak_self->_h2_write_pending;
                }
            }
        }
        else {
            _unrecognized_event_type($type, 'http');
        }
    };
}

# =============================================================================
# HTTP/2 WebSocket over HTTP/2 (RFC 8441)
# =============================================================================

sub _h2_create_websocket_scope {
    my ($self, $stream_id, $stream_state) = @_;

    my $pseudo  = $stream_state->{pseudo};
    my $headers = $stream_state->{headers};

    my $full_path = $pseudo->{':path'} // '/';
    my ($path, $query_string) = split(/\?/, $full_path, 2);
    $query_string //= '';

    # Match HTTP/1.1 pipeline: URI::Escape + UTF-8 decode with fallback
    my $unescaped = uri_unescape($path);
    my $decoded_path = eval { decode('UTF-8', $unescaped, Encode::FB_CROAK) }
                       // $unescaped;

    # Extract subprotocols from headers
    my @subprotocols;
    for my $header (@$headers) {
        my ($name, $value) = @$header;
        if ($name eq 'sec-websocket-protocol') {
            push @subprotocols, map { s/^\s+|\s+$//gr } split /,/, $value;
        }
    }

    my $connection_state = PAGI::Server::ConnectionState->new(
        connection => $self,
    );

    return {
        type         => 'websocket',
        pagi         => {
            version      => '0.2',
            spec_version => '0.2',
            features     => {},
        },
        http_version => '2',
        scheme       => $self->_get_ws_scheme,
        path         => $decoded_path,
        raw_path     => $path,
        query_string => $query_string,
        root_path    => '',
        headers      => $headers,
        client       => [$self->{client_host}, $self->{client_port}],
        server       => [$self->{server_host}, $self->{server_port}],
        subprotocols => \@subprotocols,
        state        => keys %{$self->{state}} ? { %{$self->{state}} } : {},
        extensions   => $self->_get_extensions_for_scope,
        'pagi.connection' => $connection_state,
    };
}

sub _h2_create_websocket_receive {
    my ($self, $stream_id, $stream_state) = @_;

    weaken(my $weak_self = $self);

    return sub {
        return Future->done({ type => 'websocket.disconnect', code => 1006, reason => '' })
            unless $weak_self;
        return Future->done({ type => 'websocket.disconnect', code => 1006, reason => '' })
            if $weak_self->{closed};

        my $ss = $weak_self->{h2_streams}{$stream_id};
        return Future->done({ type => 'websocket.disconnect', code => 1006, reason => '' })
            unless $ss;

        my $future = (async sub {
            return { type => 'websocket.disconnect', code => 1006, reason => '' }
                unless $weak_self;

            my $ss = $weak_self->{h2_streams}{$stream_id};
            return { type => 'websocket.disconnect', code => 1006, reason => '' }
                unless $ss;

            # Check queue first
            if (@{$ss->{receive_queue}}) {
                return shift @{$ss->{receive_queue}};
            }

            # First call returns websocket.connect
            if (!$ss->{ws_connect_sent}) {
                $ss->{ws_connect_sent} = 1;
                return { type => 'websocket.connect' };
            }

            # Wait for events
            while (1) {
                if (@{$ss->{receive_queue}}) {
                    return shift @{$ss->{receive_queue}};
                }

                return { type => 'websocket.disconnect', code => 1006, reason => '' }
                    if $weak_self->{closed};

                if (!$ss->{body_pending}) {
                    $ss->{body_pending} = Future->new;
                }
                await $ss->{body_pending};

                $ss = $weak_self->{h2_streams}{$stream_id};
                return { type => 'websocket.disconnect', code => 1006, reason => '' }
                    unless $ss;
            }
        })->();

        return $future;
    };
}

sub _h2_create_websocket_send {
    my ($self, $stream_id, $stream_state) = @_;

    weaken(my $weak_self = $self);

    return async sub {
        my ($event) = @_;
        return unless $weak_self;
        return if $weak_self->{closed};

        my $ss = $weak_self->{h2_streams}{$stream_id};
        return unless $ss;

        my $type = $event->{type} // '';

        if ($type eq 'websocket.accept') {
            return if $ss->{ws_accepted};

            # HTTP/2 WebSocket: respond with 200 (not 101)
            my @headers;
            if (my $subprotocol = $event->{subprotocol}) {
                $subprotocol = _validate_subprotocol($subprotocol);
                push @headers, ['sec-websocket-protocol', $subprotocol];
            }
            if (my $extra = $event->{headers}) {
                push @headers, map {
                    [_validate_header_name($_->[0]), _validate_header_value($_->[1])]
                } @$extra;
            }

            $ss->{ws_accepted} = 1;
            $ss->{response_started} = 1;
            $ss->{ws_frame} = Protocol::WebSocket::Frame->new(
                max_payload_size => $weak_self->{max_ws_frame_size},
            );

            # Submit 200 response with streaming body that defers
            $weak_self->{h2_session}->submit_response($stream_id,
                status  => 200,
                headers => \@headers,
                body    => sub { return undef },  # defer until submit_data
            );
            $weak_self->_h2_write_pending;

            # Process any data that arrived before accept
            if (length($ss->{body}) > 0) {
                my $buffered = $ss->{body};
                $ss->{body} = '';
                $weak_self->_h2_process_ws_frames($stream_id, $ss, $buffered);
            }
        }
        elsif ($type eq 'websocket.send') {
            return unless $ss->{ws_accepted};

            my $frame;
            if (defined $event->{text}) {
                $frame = Protocol::WebSocket::Frame->new(
                    buffer => $event->{text},
                    type   => 'text',
                );
            }
            elsif (defined $event->{bytes}) {
                $frame = Protocol::WebSocket::Frame->new(
                    buffer => $event->{bytes},
                    type   => 'binary',
                );
            }
            else {
                return;
            }

            my $bytes = $frame->to_bytes;
            $weak_self->{h2_session}->submit_data($stream_id, $bytes, 0);
            $weak_self->_h2_write_pending;
        }
        elsif ($type eq 'websocket.close') {
            if (!$ss->{ws_accepted}) {
                # Reject: send 403
                $weak_self->{h2_session}->submit_response($stream_id,
                    status  => 403,
                    headers => [['content-type', 'text/plain']],
                    body    => 'Forbidden',
                );
                $weak_self->_h2_write_pending;
                return;
            }

            my $code = $event->{code} // 1000;
            my $reason = $event->{reason} // '';

            my $frame = Protocol::WebSocket::Frame->new(
                type   => 'close',
                buffer => pack('n', $code) . $reason,
            );

            # Send close frame + END_STREAM
            $weak_self->{h2_session}->submit_data($stream_id, $frame->to_bytes, 1);
            $weak_self->_h2_write_pending;
        }

        return;
    };
}

# =============================================================================
# HTTP/2 SSE (Server-Sent Events over HTTP/2)
# =============================================================================

sub _h2_create_sse_scope {
    my ($self, $stream_id, $stream_state) = @_;

    my $pseudo  = $stream_state->{pseudo};
    my $headers = $stream_state->{headers};

    my $full_path = $pseudo->{':path'} // '/';
    my ($path, $query_string) = split(/\?/, $full_path, 2);
    $query_string //= '';

    # Match HTTP/1.1 pipeline: URI::Escape + UTF-8 decode with fallback
    my $unescaped = uri_unescape($path);
    my $decoded_path = eval { decode('UTF-8', $unescaped, Encode::FB_CROAK) }
                       // $unescaped;

    my $connection_state = PAGI::Server::ConnectionState->new(
        connection => $self,
    );

    return {
        type         => 'sse',
        pagi         => {
            version      => '0.2',
            spec_version => '0.2',
            features     => {},
        },
        http_version => '2',
        method       => $pseudo->{':method'} // 'GET',
        scheme       => $pseudo->{':scheme'} // $self->_get_scheme,
        path         => $decoded_path,
        raw_path     => $path,
        query_string => $query_string,
        root_path    => '',
        headers      => $headers,
        client       => [$self->{client_host}, $self->{client_port}],
        server       => [$self->{server_host}, $self->{server_port}],
        state        => keys %{$self->{state}} ? { %{$self->{state}} } : {},
        extensions   => $self->_get_extensions_for_scope,
        'pagi.connection' => $connection_state,
    };
}

sub _h2_create_sse_receive {
    my ($self, $stream_id, $stream_state) = @_;

    weaken(my $weak_self = $self);

    my $sse_disconnect = sub {
        return {
            type   => 'sse.disconnect',
            reason => 'client_closed',
        };
    };

    return sub {
        return Future->done($sse_disconnect->()) unless $weak_self;
        return Future->done($sse_disconnect->()) if $weak_self->{closed};

        my $ss = $weak_self->{h2_streams}{$stream_id};
        return Future->done($sse_disconnect->()) unless $ss;

        my $future = (async sub {
            return $sse_disconnect->() unless $weak_self;

            my $ss = $weak_self->{h2_streams}{$stream_id};
            return $sse_disconnect->() unless $ss;

            # Check queue first
            if (@{$ss->{receive_queue}}) {
                return shift @{$ss->{receive_queue}};
            }

            # First call returns sse.request with body
            if (!$ss->{sse_request_sent}) {
                $ss->{sse_request_sent} = 1;
                return {
                    type => 'sse.request',
                    body => $ss->{body},
                    more => 0,
                };
            }

            # Wait for disconnect
            while (1) {
                if (@{$ss->{receive_queue}}) {
                    return shift @{$ss->{receive_queue}};
                }

                return $sse_disconnect->()
                    if $weak_self->{closed};

                if (!$ss->{body_pending}) {
                    $ss->{body_pending} = Future->new;
                }
                await $ss->{body_pending};

                $ss = $weak_self->{h2_streams}{$stream_id};
                return $sse_disconnect->() unless $ss;
            }
        })->();

        return $future;
    };
}

sub _h2_create_sse_send {
    my ($self, $stream_id, $stream_state) = @_;

    weaken(my $weak_self = $self);

    # Streaming state for data provider pattern
    my @data_queue;
    my $streaming_started = 0;

    my $data_callback = sub {
        my ($cb_stream_id, $max_len) = @_;

        if (@data_queue) {
            my $chunk = shift @data_queue;
            if (length($chunk) > $max_len) {
                unshift @data_queue, substr($chunk, $max_len);
                $chunk = substr($chunk, 0, $max_len);
            }
            return ($chunk, 0);  # SSE streams never EOF via data_callback
        }

        # Queue empty — defer
        return undef;
    };

    return async sub {
        my ($event) = @_;
        return unless $weak_self;
        return if $weak_self->{closed};

        my $ss = $weak_self->{h2_streams}{$stream_id};
        return unless $ss;

        # Reset SSE idle timer on send activity
        $weak_self->_reset_sse_idle_timer;

        my $type = $event->{type} // '';

        # Dev-mode event validation (PAGI spec compliance)
        if ($weak_self->{validate_events}) {
            require PAGI::Server::EventValidator;
            PAGI::Server::EventValidator::validate_sse_send($event);
        }

        if ($type eq 'sse.start') {
            return if $ss->{response_started};
            $ss->{response_started} = 1;

            my $status = $event->{status} // 200;
            my $headers = $event->{headers} // [];

            # Ensure Content-Type is text/event-stream
            my $has_content_type = 0;
            for my $h (@$headers) {
                if (lc($h->[0]) eq 'content-type') {
                    $has_content_type = 1;
                    last;
                }
            }

            my @final_headers;
            for my $h (@$headers) {
                push @final_headers, [_validate_header_name($h->[0]), _validate_header_value($h->[1])];
            }
            if (!$has_content_type) {
                push @final_headers, ['content-type', 'text/event-stream'];
            }
            push @final_headers, ['cache-control', 'no-cache'];

            $streaming_started = 1;
            $weak_self->{h2_session}->submit_response_streaming(
                $stream_id,
                status        => $status,
                headers       => \@final_headers,
                data_callback => $data_callback,
            );
            $weak_self->_h2_write_pending;

            # Set protocol-specific keepalive writer (HTTP/2 DATA frames)
            $weak_self->{sse_keepalive_writer} = sub {
                my ($text) = @_;
                return unless $weak_self;
                return if $weak_self->{closed};
                return unless $weak_self->{h2_streams}{$stream_id};
                push @data_queue, $text;
                $weak_self->{h2_session}->resume_stream($stream_id);
                $weak_self->_h2_write_pending;
            };

            # Start SSE idle timer if configured
            $weak_self->_start_sse_idle_timer;
        }
        elsif ($type eq 'sse.send') {
            return unless $ss->{response_started};

            # Backpressure check
            if ($weak_self->_get_write_buffer_size >= $weak_self->{write_high_watermark}) {
                await $weak_self->_wait_for_drain;
                return Future->done unless $weak_self;
                return Future->done if $weak_self->{closed};
                return unless $weak_self->{h2_streams}{$stream_id};
            }

            my $sse_data = _format_sse_event($event);
            push @data_queue, $sse_data;
            $weak_self->{h2_session}->resume_stream($stream_id);
            $weak_self->_h2_write_pending;
        }
        elsif ($type eq 'sse.comment') {
            return unless $ss->{response_started};

            my $comment = _format_sse_comment($event);
            push @data_queue, $comment;
            $weak_self->{h2_session}->resume_stream($stream_id);
            $weak_self->_h2_write_pending;
        }
        elsif ($type eq 'sse.keepalive') {
            my $interval = $event->{interval} // 0;
            my $comment = $event->{comment};

            if ($interval > 0) {
                $weak_self->_start_sse_keepalive($interval, $comment);
            }
            else {
                $weak_self->_stop_sse_keepalive;
            }
        }
        else {
            _unrecognized_event_type($type, 'sse');
        }

        return;
    };
}

sub _h2_process_ws_frames {
    my ($self, $stream_id, $stream, $data) = @_;

    my $frame = $stream->{ws_frame};
    return unless $frame;

    $frame->append($data);

    while (defined(my $bytes = $frame->next_bytes)) {
        my $opcode = $frame->opcode;

        if ($opcode == 1) {
            # Text frame
            my $text = eval { Encode::decode('UTF-8', $bytes, Encode::FB_CROAK) };
            unless (defined $text) {
                $self->_h2_ws_close($stream_id, 1007, 'Invalid UTF-8');
                return;
            }
            push @{$stream->{receive_queue}}, {
                type => 'websocket.receive',
                text => $text,
            };
        }
        elsif ($opcode == 2) {
            # Binary frame
            push @{$stream->{receive_queue}}, {
                type  => 'websocket.receive',
                bytes => $bytes,
            };
        }
        elsif ($opcode == 8) {
            # Close frame
            my ($code, $reason) = (1005, '');

            # RFC 6455 Section 5.5.1: Close frame payload is 0 or >=2 bytes
            if (length($bytes) == 1) {
                $self->_h2_ws_close($stream_id, 1002, 'Invalid close frame');
                push @{$stream->{receive_queue}}, {
                    type   => 'websocket.disconnect',
                    code   => 1002,
                    reason => 'Invalid close frame',
                };
                $self->_h2_wake_pending($stream);
                return;
            }

            if (length($bytes) >= 2) {
                $code = unpack('n', substr($bytes, 0, 2));
                $reason = substr($bytes, 2) // '';

                # RFC 6455 Section 7.4.1: Validate close code
                my $valid_code = 0;
                if ($code == 1000 || $code == 1001 || $code == 1002 || $code == 1003) {
                    $valid_code = 1;
                }
                elsif ($code >= 1007 && $code <= 1011) {
                    $valid_code = 1;
                }
                elsif ($code >= 3000 && $code <= 4999) {
                    $valid_code = 1;
                }
                unless ($valid_code) {
                    $self->_h2_ws_close($stream_id, 1002, 'Invalid close code');
                    push @{$stream->{receive_queue}}, {
                        type   => 'websocket.disconnect',
                        code   => 1002,
                        reason => 'Invalid close code',
                    };
                    $self->_h2_wake_pending($stream);
                    return;
                }

                # RFC 6455: Close reason must be valid UTF-8
                if (length($reason) > 0) {
                    my $reason_copy = $reason;
                    my $decoded = eval { Encode::decode('UTF-8', $reason_copy, Encode::FB_CROAK) };
                    unless (defined $decoded) {
                        $self->_h2_ws_close($stream_id, 1007, 'Invalid UTF-8 in close reason');
                        push @{$stream->{receive_queue}}, {
                            type   => 'websocket.disconnect',
                            code   => 1007,
                            reason => 'Invalid UTF-8 in close reason',
                        };
                        $self->_h2_wake_pending($stream);
                        return;
                    }
                }
            }

            # Send close frame back + END_STREAM
            my $close_frame = Protocol::WebSocket::Frame->new(
                type   => 'close',
                buffer => pack('n', $code) . $reason,
            );
            $self->{h2_session}->submit_data($stream_id, $close_frame->to_bytes, 1);
            # No _h2_write_pending — inside feed(); flushed by _h2_process_data

            push @{$stream->{receive_queue}}, {
                type   => 'websocket.disconnect',
                code   => $code,
                reason => $reason,
            };
        }
        elsif ($opcode == 9) {
            # Ping — respond with pong
            my $pong = Protocol::WebSocket::Frame->new(
                type   => 'pong',
                buffer => $bytes,
            );
            $self->{h2_session}->submit_data($stream_id, $pong->to_bytes, 0);
            # No _h2_write_pending — inside feed(); flushed by _h2_process_data
        }
        # Opcode 10 (pong) — ignore
    }

    $self->_h2_wake_pending($stream);
}

sub _h2_ws_close {
    my ($self, $stream_id, $code, $reason) = @_;

    my $frame = Protocol::WebSocket::Frame->new(
        type   => 'close',
        buffer => pack('n', $code) . ($reason // ''),
    );
    $self->{h2_session}->submit_data($stream_id, $frame->to_bytes, 1);
    # No _h2_write_pending — called from inside feed(); flushed by _h2_process_data
}

# Request stall timeout - closes connection if no I/O activity during request processing
sub _start_stall_timer {
    my ($self) = @_;

    return unless $self->{request_timeout} && $self->{request_timeout} > 0;
    return unless $self->{server};
    return if $self->{stall_timer};  # Already running

    weaken(my $weak_self = $self);

    my $timer = IO::Async::Timer::Countdown->new(
        delay => $self->{request_timeout},
        on_expire => sub {
            return unless $weak_self;
            return if $weak_self->{closed};
            # Log the timeout
            if ($weak_self->{server} && $weak_self->{server}->can('_log')) {
                $weak_self->{server}->_log(warn =>
                    "Request stall timeout ($weak_self->{request_timeout}s) - closing connection");
            }
            $weak_self->_handle_disconnect_and_close('client_timeout');
        },
    );
    $self->{stall_timer} = $timer;
    $self->{server}->add_child($timer);
    $timer->start;
}

sub _reset_stall_timer {
    my ($self) = @_;

    return unless $self->{stall_timer};
    $self->{stall_timer}->reset;
    $self->{stall_timer}->start unless $self->{stall_timer}->is_running;
}

sub _stop_stall_timer {
    my ($self) = @_;

    return unless $self->{stall_timer};
    $self->{stall_timer}->stop if $self->{stall_timer}->is_running;
    if ($self->{server}) {
        $self->{server}->remove_child($self->{stall_timer});
    }
    $self->{stall_timer} = undef;
}

# WebSocket idle timeout - closes connection if no activity
sub _start_ws_idle_timer {
    my ($self) = @_;

    return unless $self->{ws_idle_timeout} && $self->{ws_idle_timeout} > 0;
    return unless $self->{server};
    return if $self->{ws_idle_timer};

    weaken(my $weak_self = $self);

    my $timer = IO::Async::Timer::Countdown->new(
        delay => $self->{ws_idle_timeout},
        on_expire => sub {
            return unless $weak_self;
            return if $weak_self->{closed};
            if ($weak_self->{server} && $weak_self->{server}->can('_log')) {
                $weak_self->{server}->_log(warn =>
                    "WebSocket idle timeout ($weak_self->{ws_idle_timeout}s) - closing connection");
            }
            $weak_self->_handle_disconnect_and_close('idle_timeout');
        },
    );
    $self->{ws_idle_timer} = $timer;
    $self->{server}->add_child($timer);
    $timer->start;
}

sub _reset_ws_idle_timer {
    my ($self) = @_;

    return unless $self->{ws_idle_timer};
    $self->{ws_idle_timer}->reset;
    $self->{ws_idle_timer}->start unless $self->{ws_idle_timer}->is_running;
}

sub _stop_ws_idle_timer {
    my ($self) = @_;

    return unless $self->{ws_idle_timer};
    $self->{ws_idle_timer}->stop if $self->{ws_idle_timer}->is_running;
    if ($self->{server}) {
        $self->{server}->remove_child($self->{ws_idle_timer});
    }
    $self->{ws_idle_timer} = undef;
}

# SSE idle timeout - closes connection if no activity
sub _start_sse_idle_timer {
    my ($self) = @_;

    return unless $self->{sse_idle_timeout} && $self->{sse_idle_timeout} > 0;
    return unless $self->{server};
    return if $self->{sse_idle_timer};

    weaken(my $weak_self = $self);

    my $timer = IO::Async::Timer::Countdown->new(
        delay => $self->{sse_idle_timeout},
        on_expire => sub {
            return unless $weak_self;
            return if $weak_self->{closed};
            if ($weak_self->{server} && $weak_self->{server}->can('_log')) {
                $weak_self->{server}->_log(warn =>
                    "SSE idle timeout ($weak_self->{sse_idle_timeout}s) - closing connection");
            }
            $weak_self->{sse_disconnect_reason} = 'idle_timeout';
            $weak_self->_handle_disconnect_and_close('idle_timeout');
        },
    );
    $self->{sse_idle_timer} = $timer;
    $self->{server}->add_child($timer);
    $timer->start;
}

sub _reset_sse_idle_timer {
    my ($self) = @_;

    return unless $self->{sse_idle_timer};
    $self->{sse_idle_timer}->reset;
    $self->{sse_idle_timer}->start unless $self->{sse_idle_timer}->is_running;
}

sub _stop_sse_idle_timer {
    my ($self) = @_;

    return unless $self->{sse_idle_timer};
    $self->{sse_idle_timer}->stop if $self->{sse_idle_timer}->is_running;
    if ($self->{server}) {
        $self->{server}->remove_child($self->{sse_idle_timer});
    }
    $self->{sse_idle_timer} = undef;
}

# ============================================================================
# Send-side backpressure support
# ============================================================================
#
# Prevents unbounded memory growth when apps send faster than slow clients
# can receive. Uses watermark-based flow control:
# - High watermark (default 1MB): pause sending when buffer exceeds this
# - Low watermark (default 256KB): resume sending when buffer drops below this
#
# The $send->() Future will block (await) when high watermark is exceeded,
# and resolve when buffer drains below low watermark.

sub _get_write_buffer_size {
    my ($self) = @_;

    return 0 unless $self->{stream};

    # Access IO::Async::Stream's internal write queue
    # IO::Async doesn't expose a public API for buffer size, so we access internals
    my $queue = $self->{stream}{writequeue} // [];
    my $total = 0;

    for my $writer (@$queue) {
        my $data = $writer->data;
        if (defined $data && !ref $data) {
            $total += length($data);
        }
    }

    return $total;
}

sub _check_drain_waiters {
    my ($self) = @_;

    return unless @{$self->{_drain_waiters}};
    return unless $self->{stream};

    my $buffered = $self->_get_write_buffer_size;

    # Resolve all waiters if we've drained below low watermark
    if ($buffered < $self->{write_low_watermark}) {
        my @waiters = splice @{$self->{_drain_waiters}};
        for my $f (@waiters) {
            $f->done unless $f->is_ready;
        }
        # Disable drain checking until next high watermark hit
        $self->{_drain_check_active} = 0;
    }
}

sub _setup_drain_detection {
    my ($self) = @_;

    # Avoid redundant setup
    return if $self->{_drain_check_active};
    $self->{_drain_check_active} = 1;

    weaken(my $weak_self = $self);

    # Primary mechanism: check when write queue empties
    # This guarantees we notice drain even for fast-draining connections
    # Store previous handler to chain if needed
    my $prev_on_empty = $self->{_prev_on_outgoing_empty};

    $self->{stream}->configure(
        on_outgoing_empty => sub {
            return unless $weak_self;
            $weak_self->_check_drain_waiters;
            # Call previous handler if any
            $prev_on_empty->(@_) if $prev_on_empty;
        },
    );
}

sub _wait_for_drain {
    my ($self) = @_;

    # Fast path: already below low watermark
    my $buffered = $self->_get_write_buffer_size;
    if ($buffered < $self->{write_low_watermark}) {
        return Future->done;
    }

    # Create Future to be resolved when drained
    my $f = $self->{server}->loop->new_future;
    push @{$self->{_drain_waiters}}, $f;

    # Ensure drain detection is active
    $self->_setup_drain_detection;

    return $f;
}

sub _cancel_drain_waiters {
    my ($self, $reason) = @_;
    $reason //= 'connection closed';

    my @waiters = splice @{$self->{_drain_waiters}};
    for my $f (@waiters) {
        # Resolve (not fail) - app should check connection state after await
        $f->done unless $f->is_ready;
    }
    $self->{_drain_check_active} = 0;
}

# ============================================================================

# WebSocket keepalive - sends protocol-level ping frames (RFC 6455)
sub _start_ws_keepalive {
    my ($self, $interval, $timeout) = @_;

    # Stop existing timers first
    $self->_stop_ws_keepalive;

    return unless $interval && $interval > 0;
    return unless $self->{server};

    $self->{ws_keepalive_interval} = $interval;
    $self->{ws_keepalive_timeout} = $timeout // 0;

    weaken(my $weak_self = $self);

    my $timer = IO::Async::Timer::Periodic->new(
        interval => $interval,
        on_tick  => sub {
            return unless $weak_self;
            return if $weak_self->{closed};
            return unless $weak_self->{websocket_mode};

            # Send ping frame
            my $ping = Protocol::WebSocket::Frame->new(
                type   => 'ping',
                buffer => '',
            );
            $weak_self->{stream}->write($ping->to_bytes);

            # Start pong timeout if configured
            if ($weak_self->{ws_keepalive_timeout} > 0) {
                $weak_self->{ws_waiting_pong} = 1;
                $weak_self->_start_ws_pong_timeout;
            }
        },
    );

    $self->{ws_keepalive_timer} = $timer;
    $self->{server}->add_child($timer);
    $timer->start;
}

sub _start_ws_pong_timeout {
    my ($self) = @_;

    # Don't start another timeout if one is running
    return if $self->{ws_pong_timeout};
    return unless $self->{ws_keepalive_timeout} > 0;
    return unless $self->{server};

    weaken(my $weak_self = $self);

    my $timer = IO::Async::Timer::Countdown->new(
        delay => $self->{ws_keepalive_timeout},
        on_expire => sub {
            return unless $weak_self;
            return if $weak_self->{closed};

            if ($weak_self->{ws_waiting_pong}) {
                # No pong received within timeout - close connection
                if ($weak_self->{server} && $weak_self->{server}->can('_log')) {
                    $weak_self->{server}->_log(warn =>
                        "WebSocket keepalive timeout - no pong received within $weak_self->{ws_keepalive_timeout}s");
                }
                $weak_self->_handle_disconnect_and_close('keepalive_timeout');
            }
        },
    );

    $self->{ws_pong_timeout} = $timer;
    $self->{server}->add_child($timer);
    $timer->start;
}

sub _cancel_ws_pong_timeout {
    my ($self) = @_;

    $self->{ws_waiting_pong} = 0;

    return unless $self->{ws_pong_timeout};
    $self->{ws_pong_timeout}->stop if $self->{ws_pong_timeout}->is_running;
    if ($self->{server}) {
        $self->{server}->remove_child($self->{ws_pong_timeout});
    }
    $self->{ws_pong_timeout} = undef;
}

sub _stop_ws_keepalive {
    my ($self) = @_;

    # Stop pong timeout first
    $self->_cancel_ws_pong_timeout;

    return unless $self->{ws_keepalive_timer};
    $self->{ws_keepalive_timer}->stop if $self->{ws_keepalive_timer}->is_running;
    if ($self->{server}) {
        $self->{server}->remove_child($self->{ws_keepalive_timer});
    }
    $self->{ws_keepalive_timer} = undef;
    $self->{ws_keepalive_interval} = 0;
    $self->{ws_keepalive_timeout} = 0;
}

# SSE keepalive - sends comment lines to prevent proxy timeouts
sub _start_sse_keepalive {
    my ($self, $interval, $comment) = @_;

    # Stop existing timer first
    $self->_stop_sse_keepalive;

    return unless $interval && $interval > 0;
    return unless $self->{server};

    $self->{sse_keepalive_comment} = $comment // '';

    weaken(my $weak_self = $self);

    my $timer = IO::Async::Timer::Periodic->new(
        interval => $interval,
        on_tick  => sub {
            return unless $weak_self;
            return if $weak_self->{closed};

            my $text = $weak_self->{sse_keepalive_comment};
            $text = ":$text" unless $text =~ /^:/;
            my $formatted = "$text\n\n";

            if (my $writer = $weak_self->{sse_keepalive_writer}) {
                $writer->($formatted);
            }
        },
    );

    $self->{sse_keepalive_timer} = $timer;
    $self->{server}->add_child($timer);
    $timer->start;
}

sub _stop_sse_keepalive {
    my ($self) = @_;

    return unless $self->{sse_keepalive_timer};
    $self->{sse_keepalive_timer}->stop if $self->{sse_keepalive_timer}->is_running;
    if ($self->{server}) {
        $self->{server}->remove_child($self->{sse_keepalive_timer});
    }
    $self->{sse_keepalive_timer} = undef;
    $self->{sse_keepalive_comment} = '';
}

sub _try_handle_request {
    my ($self) = @_;

    return if $self->{closed};
    return if $self->{handling_request};

    # Try to parse a request from the buffer
    my ($request, $consumed) = $self->{protocol}->parse_request($self->{buffer});

    return unless $request;

    # Remove consumed bytes from buffer
    substr($self->{buffer}, 0, $consumed) = '';

    # Handle parse errors (malformed request, header too large)
    if ($request->{error}) {
        # Mark connection as disconnected with protocol_error reason (PAGI spec compliance)
        $self->_handle_disconnect('protocol_error');
        $self->_send_error_response($request->{error}, $request->{message});
        $self->_close;
        return;
    }

    # Check Content-Length against max_body_size limit (0 = unlimited)
    if ($self->{max_body_size} && defined $request->{content_length}) {
        if ($request->{content_length} > $self->{max_body_size}) {
            $self->_handle_disconnect('body_too_large');
            $self->_send_error_response(413, 'Payload Too Large');
            $self->_close;
            return;
        }
    }

    # Check if this is a WebSocket upgrade request
    my $is_websocket = $self->_is_websocket_upgrade($request);

    # Check if this is an SSE request
    my $is_sse = !$is_websocket && $self->_is_sse_request($request);

    # Handle the request - store the Future to prevent "lost future" warning
    $self->{handling_request} = 1;
    $self->{request_start} = [gettimeofday];
    $self->{current_request} = $request;  # Store for access logging

    if ($is_websocket) {
        $self->{request_future} = $self->_handle_websocket_request($request);
    } elsif ($is_sse) {
        $self->{request_future} = $self->_handle_sse_request($request);
    } else {
        # Start stall timer for HTTP requests (WebSocket/SSE have their own handling)
        $self->_start_stall_timer;
        $self->{request_future} = $self->_handle_request($request);
    }

    # Use adopt_future for proper error tracking instead of retain
    # This ensures errors are propagated to the server's error handling
    $self->{server}->adopt_future($self->{request_future});
}

sub _is_websocket_upgrade {
    my ($self, $request) = @_;

    # Check for WebSocket upgrade headers
    my $has_upgrade = 0;
    my $has_connection_upgrade = 0;
    my $has_ws_key = 0;

    for my $header (@{$request->{headers}}) {
        my ($name, $value) = @$header;
        if ($name eq 'upgrade' && lc($value) eq 'websocket') {
            $has_upgrade = 1;
        }
        elsif ($name eq 'connection') {
            # Connection header can have multiple values
            $has_connection_upgrade = 1 if lc($value) =~ /upgrade/;
        }
        elsif ($name eq 'sec-websocket-key') {
            $has_ws_key = 1;
        }
    }

    return $has_upgrade && $has_connection_upgrade && $has_ws_key;
}

sub _is_sse_request {
    my ($self, $request) = @_;

    # SSE detection per spec:
    # - Accept header includes text/event-stream
    # - Request has not been upgraded to WebSocket (already checked)
    # Note: SSE works with any HTTP method (GET, POST, etc.) to support
    # modern patterns like htmx 4 and datastar using fetch-event-source

    for my $header (@{$request->{headers}}) {
        my ($name, $value) = @$header;
        if ($name eq 'accept') {
            # Check if Accept header includes text/event-stream
            return 1 if $value =~ m{text/event-stream};
        }
    }

    return 0;
}

async sub _handle_request {
    my ($self, $request) = @_;

    my $scope = $self->_create_scope($request);
    my $receive = $self->_create_receive($request);
    my $send = $self->_create_send($request);

    eval {
        await $self->{app}->($scope, $receive, $send);
    };

    if (my $error = $@) {
        # Handle application error - always close connection after exception
        # If response already started, we can't send error page (3.17)
        if ($self->{response_started}) {
            warn "PAGI application error (after response started): $error\n";
        } else {
            $self->_send_error_response(500, "Internal Server Error");
            warn "PAGI application error: $error\n";
        }
        # Write access log before closing
        $self->_write_access_log;
        # Notify server that request completed (for max_requests tracking)
        $self->{server}->_on_request_complete if $self->{server};
        # Always close connection after exception (3.2) - don't try keep-alive
        $self->_handle_disconnect('server_error');
        $self->_close;
        return;
    }

    # Write access log entry
    $self->_write_access_log;

    # Notify server that request completed (for max_requests tracking)
    $self->{server}->_on_request_complete if $self->{server};

    # Stop stall timer - request completed successfully
    $self->_stop_stall_timer;

    # Determine if we should keep the connection alive
    my $keep_alive = $self->_should_keep_alive($request);

    if ($keep_alive) {
        # Reset for next request
        $self->{handling_request} = 0;
        $self->{response_started} = 0;
        $self->{response_status} = undef;
        $self->{_response_size} = 0;
        $self->{request_start} = undef;
        $self->{current_request} = undef;
        $self->{request_future} = undef;
        $self->{current_connection_state} = undef;  # Clear for next request

        # Check if there's more data in the buffer (pipelining)
        if (length($self->{buffer}) > 0) {
            $self->_try_handle_request;
        }
    } else {
        # Not keeping alive - close connection
        $self->_handle_disconnect_and_close('request_complete');
    }
}

sub _should_keep_alive {
    my ($self, $request) = @_;

    my $http_version = $request->{http_version} // '1.1';

    # Check for Connection header
    my $connection_header;
    for my $header (@{$request->{headers}}) {
        if ($header->[0] eq 'connection') {
            $connection_header = lc($header->[1]);
            last;
        }
    }

    # HTTP/1.1: keep-alive by default unless Connection: close
    if ($http_version eq '1.1') {
        return 0 if $connection_header && $connection_header =~ /close/;
        return 1;
    }

    # HTTP/1.0: close by default unless Connection: keep-alive
    if ($http_version eq '1.0') {
        return 1 if $connection_header && $connection_header =~ /keep-alive/;
        return 0;
    }

    # Unknown version: close connection
    return 0;
}

sub _create_scope {
    my ($self, $request) = @_;

    # Create connection state object for disconnect tracking (PAGI spec 0.3)
    # Uses lazy Future creation - Future only allocated if disconnect_future() is called
    my $connection_state = PAGI::Server::ConnectionState->new(
        connection => $self,
    );
    $self->{current_connection_state} = $connection_state;

    my $scope = {
        type         => 'http',
        pagi         => {
            version      => '0.2',
            spec_version => '0.2',
            features     => {},
        },
        http_version => $request->{http_version},
        method       => $request->{method},
        scheme       => $self->_get_scheme,
        path         => $request->{path},
        raw_path     => $request->{raw_path},
        query_string => $request->{query_string},
        root_path    => '',
        headers      => $request->{headers},
        client       => [$self->{client_host}, $self->{client_port}],
        server       => [$self->{server_host}, $self->{server_port}],
        # Optimized: avoid hash copy when state is empty (common case)
        state        => keys %{$self->{state}} ? { %{$self->{state}} } : {},
        extensions   => $self->_get_extensions_for_scope,
        # Connection state for non-destructive disconnect detection (PAGI spec 0.3)
        'pagi.connection' => $connection_state,
    };

    return $scope;
}

sub _create_receive {
    my ($self, $request) = @_;

    my $content_length = $request->{content_length};
    my $is_chunked = $request->{chunked} // 0;
    my $expect_continue = $request->{expect_continue} // 0;
    my $continue_sent = 0;
    my $body_complete = 0;
    my $bytes_read = 0;
    my $chunk_size = 65536;  # 64KB chunks for large bodies

    # For requests without Content-Length and not chunked, treat as no body
    my $has_body = defined($content_length) && $content_length > 0 || $is_chunked;

    weaken(my $weak_self = $self);

    # Return a wrapper that tracks the Future from the async receive
    return sub {
        return Future->done({ type => 'http.disconnect' }) unless $weak_self;
        return Future->done({ type => 'http.disconnect' }) if $weak_self->{closed};

        # The actual async implementation
        my $future = (async sub {
            return { type => 'http.disconnect' } unless $weak_self;
            return { type => 'http.disconnect' } if $weak_self->{closed};

            # Check queue first - events from disconnect handler
            if (@{$weak_self->{receive_queue}}) {
                return shift @{$weak_self->{receive_queue}};
            }

            # If body is already complete, wait for disconnect
            if ($body_complete) {
                if (!$weak_self->{receive_pending}) {
                    $weak_self->{receive_pending} = Future->new;
                }

                if ($weak_self->{closed}) {
                    $weak_self->{receive_pending} = undef;
                    return { type => 'http.disconnect' };
                }

                my $result = await $weak_self->{receive_pending};
                # receive_pending may be completed with a value (disconnect event)
                # or just done() as a signal
                return $result if ref $result eq 'HASH';
                # If no value, check queue
                if (@{$weak_self->{receive_queue}}) {
                    return shift @{$weak_self->{receive_queue}};
                }
                return { type => 'http.disconnect' };
            }

            # For requests without body, return empty body immediately
            if (!$has_body) {
                $body_complete = 1;
                return {
                    type => 'http.request',
                    body => '',
                    more => 0,
                };
            }

            # Send 100 Continue if client expects it (before reading body)
            if ($expect_continue && !$continue_sent) {
                $continue_sent = 1;
                $weak_self->{stream}->write($weak_self->{protocol}->serialize_continue);
            }

            # Handle chunked Transfer-Encoding
            if ($is_chunked) {
                # Wait for data if buffer is empty
                while (length($weak_self->{buffer}) == 0 && !$weak_self->{closed}) {
                    if (!$weak_self->{receive_pending}) {
                        $weak_self->{receive_pending} = Future->new;
                    }
                    await $weak_self->{receive_pending};
                    $weak_self->{receive_pending} = undef;

                    # Check queue after waiting
                    if (@{$weak_self->{receive_queue}}) {
                        return shift @{$weak_self->{receive_queue}};
                    }
                }

                # Try to parse chunked data
                my ($data, $consumed, $complete) = $weak_self->{protocol}->parse_chunked_body($weak_self->{buffer});

                # Check for parse error (invalid chunk size)
                if (ref($data) eq 'HASH' && $data->{error}) {
                    $weak_self->_handle_disconnect('protocol_error');
                    $weak_self->_send_error_response($data->{error}, $data->{message} // 'Bad Request');
                    $weak_self->_close;
                    return { type => 'http.disconnect' };
                }

                if ($consumed > 0) {
                    substr($weak_self->{buffer}, 0, $consumed) = '';

                    # Track total bytes read for max_body_size check
                    $bytes_read += length($data // '');

                    # Check max_body_size for chunked requests (0 = unlimited)
                    if ($weak_self->{max_body_size} && $bytes_read > $weak_self->{max_body_size}) {
                        # Body too large - close connection
                        $weak_self->_send_error_response(413, 'Payload Too Large');
                        $weak_self->_handle_disconnect('body_too_large');
                        $weak_self->_close;
                        return { type => 'http.disconnect' };
                    }

                    if ($complete) {
                        $body_complete = 1;
                    }

                    return {
                        type => 'http.request',
                        body => $data // '',
                        more => $complete ? 0 : 1,
                    };
                }

                # Need more data - wait for it
                if (!$weak_self->{receive_pending}) {
                    $weak_self->{receive_pending} = Future->new;
                }
                await $weak_self->{receive_pending};
                $weak_self->{receive_pending} = undef;

                # Recursive call to re-process - but we can't use __SUB__ in nested async
                # Just return disconnect if closed
                return { type => 'http.disconnect' } if $weak_self->{closed};
                # This shouldn't happen often - caller should retry
                return { type => 'http.request', body => '', more => 1 };
            }

            # Handle Content-Length based body reading
            my $remaining = $content_length - $bytes_read;

            if ($remaining <= 0) {
                $body_complete = 1;
                return {
                    type => 'http.request',
                    body => '',
                    more => 0,
                };
            }

            # Wait for data if buffer is empty
            while (length($weak_self->{buffer}) == 0 && !$weak_self->{closed}) {
                if (!$weak_self->{receive_pending}) {
                    $weak_self->{receive_pending} = Future->new;
                }
                await $weak_self->{receive_pending};
                $weak_self->{receive_pending} = undef;

                # Check queue after waiting
                if (@{$weak_self->{receive_queue}}) {
                    return shift @{$weak_self->{receive_queue}};
                }
            }

            # Return disconnect if closed while waiting
            if ($weak_self->{closed} && length($weak_self->{buffer}) == 0) {
                return { type => 'http.disconnect' };
            }

            # Read up to chunk_size or remaining bytes, whichever is smaller
            my $to_read = $remaining < $chunk_size ? $remaining : $chunk_size;
            $to_read = length($weak_self->{buffer}) if length($weak_self->{buffer}) < $to_read;

            my $body = substr($weak_self->{buffer}, 0, $to_read, '');
            $bytes_read += length($body);

            # Check if we've read all the body
            my $more = ($bytes_read < $content_length) ? 1 : 0;

            if (!$more) {
                $body_complete = 1;
            }

            return {
                type => 'http.request',
                body => $body,
                more => $more,
            };
        })->();

        # Track this Future so we can cancel it on close
        push @{$weak_self->{receive_futures}}, $future;

        # Clean up completed futures from the list
        @{$weak_self->{receive_futures}} = grep { !$_->is_ready } @{$weak_self->{receive_futures}};

        return $future;
    };
}

sub _create_send {
    my ($self, $request) = @_;

    my $chunked = 0;
    my $response_started = 0;
    my $expects_trailers = 0;
    my $body_complete = 0;
    my $is_head_request = ($request->{method} // '') eq 'HEAD';
    my $http_version = $request->{http_version} // '1.1';
    my $is_http10 = ($http_version eq '1.0');

    # Check if HTTP/1.0 client requested keep-alive
    my $client_wants_keepalive = 0;
    if ($is_http10) {
        for my $h (@{$request->{headers}}) {
            if ($h->[0] eq 'connection' && lc($h->[1]) =~ /keep-alive/) {
                $client_wants_keepalive = 1;
                last;
            }
        }
    }

    weaken(my $weak_self = $self);

    return async sub  {
        my ($event) = @_;
        return Future->done unless $weak_self;
        return Future->done if $weak_self->{closed};

        # Reset stall timer on write activity
        $weak_self->_reset_stall_timer;

        my $type = $event->{type} // '';

        # Dev-mode event validation (PAGI spec compliance)
        if ($weak_self->{validate_events}) {
            require PAGI::Server::EventValidator;
            PAGI::Server::EventValidator::validate_http_send($event);
        }

        if ($type eq 'http.response.start') {
            return if $response_started;
            $response_started = 1;
            $weak_self->{response_started} = 1;
            $weak_self->{response_status} = $event->{status} // 200;  # Track for logging
            $expects_trailers = $event->{trailers} // 0;

            my $status = $event->{status} // 200;
            my $headers = $event->{headers} // [];

            # Check if we need chunked encoding (no Content-Length)
            my $has_content_length = 0;
            for my $h (@$headers) {
                if (lc($h->[0]) eq 'content-length') {
                    $has_content_length = 1;
                    last;
                }
            }

            # Add Date header
            my @final_headers = @$headers;
            push @final_headers, ['date', $weak_self->{protocol}->format_date];

            # For HEAD requests, don't use chunked encoding (no body will be sent)
            # For HTTP/1.0, don't use chunked encoding - use Connection: close instead
            if ($is_head_request || $is_http10) {
                $chunked = 0;
                if ($is_http10) {
                    if (!$has_content_length) {
                        # No Content-Length means we can't do keep-alive
                        push @final_headers, ['connection', 'close'];
                    } elsif ($client_wants_keepalive) {
                        # HTTP/1.0 client requested keep-alive and we can honor it
                        # Must explicitly acknowledge with Connection: keep-alive
                        push @final_headers, ['connection', 'keep-alive'];
                    }
                }
            } else {
                $chunked = !$has_content_length;
            }

            my $response = $weak_self->{protocol}->serialize_response_start(
                $status, \@final_headers, $chunked, $http_version
            );

            # Write headers to stream
            $weak_self->{stream}->write($response);
        }
        elsif ($type eq 'http.response.body') {
            return unless $response_started;
            return if $body_complete;

            # For HEAD requests, suppress the body but track completion
            if ($is_head_request) {
                my $more = $event->{more} // 0;
                if (!$more) {
                    $body_complete = 1;
                }
                return;  # Don't send any body for HEAD
            }

            # --- BACKPRESSURE CHECK ---
            # Wait for buffer to drain if we're above high watermark
            # This prevents unbounded memory growth with slow clients
            if ($weak_self->_get_write_buffer_size >= $weak_self->{write_high_watermark}) {
                await $weak_self->_wait_for_drain;
                # Re-check connection state after await
                return Future->done unless $weak_self;
                return Future->done if $weak_self->{closed};
            }
            # --- END BACKPRESSURE CHECK ---

            # Determine body source: body, file, or fh (mutually exclusive)
            my $body = $event->{body};
            my $file = $event->{file};
            my $fh = $event->{fh};
            my $offset = $event->{offset} // 0;
            my $length = $event->{length};

            if (defined $file) {
                # File path response - stream from file (async, non-blocking)
                # File responses are implicitly complete (more is ignored)
                await $weak_self->_send_file_response($file, $offset, $length, $chunked);
                $body_complete = 1;
            }
            elsif (defined $fh) {
                # Filehandle response - stream from handle (async, non-blocking)
                # Filehandle responses are implicitly complete (more is ignored)
                await $weak_self->_send_fh_response($fh, $offset, $length, $chunked);
                $body_complete = 1;
            }
            else {
                # Traditional body response
                $body //= '';
                my $more = $event->{more} // 0;

                $weak_self->{_response_size} += length($body);

                if ($chunked) {
                    if (length $body) {
                        my $len = sprintf("%x", length($body));
                        $weak_self->{stream}->write("$len\r\n$body\r\n");
                    }
                }
                else {
                    $weak_self->{stream}->write($body) if length $body;
                }

                # Handle completion for body responses
                if (!$more) {
                    $body_complete = 1;
                    if ($chunked && !$expects_trailers) {
                        $weak_self->{stream}->write("0\r\n\r\n");
                    }
                }
            }
        }
        elsif ($type eq 'http.response.trailers') {
            return unless $response_started;
            return unless $expects_trailers;
            return unless $chunked;  # Trailers only work with chunked encoding

            my $trailer_headers = $event->{headers} // [];

            # Send final chunk + trailers
            my $trailers = "0\r\n";
            for my $header (@$trailer_headers) {
                my ($name, $value) = @$header;
                $trailers .= "$name: $value\r\n";
            }
            $trailers .= "\r\n";

            $weak_self->{stream}->write($trailers);
            $body_complete = 1;
        }
        elsif ($type eq 'http.fullflush') {
            # Fullflush extension - force immediate TCP buffer flush
            # Per spec: servers that don't advertise the extension must reject
            unless (exists $weak_self->{extensions}{fullflush}) {
                warn "PAGI: http.fullflush event rejected - extension not enabled\n";
                die "Extension not enabled: fullflush\n";
            }

            # Force flush by ensuring TCP_NODELAY and flushing any pending writes
            my $handle = $weak_self->{stream}->write_handle;
            if ($handle && $handle->can('setsockopt')) {
                # Ensure TCP_NODELAY is set to disable Nagle buffering
                require Socket;
                $handle->setsockopt(Socket::IPPROTO_TCP(), Socket::TCP_NODELAY(), 1);
            }

            # In IO::Async, writes are queued and sent when the event loop allows.
            # The above TCP_NODELAY ensures no Nagle buffering delays.
            # For this reference implementation, we return immediately as the
            # write buffer will be flushed by the event loop.
        }
        else {
            # Per PAGI spec: servers must raise exceptions for unrecognized event types
            _unrecognized_event_type($type, 'http');
        }

        return;
    };
}

sub _send_error_response {
    my ($self, $status, $message) = @_;

    return if $self->{closed};
    return if $self->{response_started};

    my $body = $message;
    my $headers = [
        ['content-type', 'text/plain'],
        ['content-length', length($body)],
        ['date', $self->{protocol}->format_date],
    ];

    my $response = $self->{protocol}->serialize_response_start($status, $headers, 0);
    $response .= $body;

    $self->{stream}->write($response);
    $self->{response_started} = 1;
    $self->{response_status} = $status;  # Track for logging
}

sub _write_access_log {
    my ($self) = @_;

    return unless $self->{access_log};
    return unless $self->{current_request};

    my $request = $self->{current_request};

    # Calculate request duration
    my $duration = 0;
    if ($self->{request_start}) {
        $duration = tv_interval($self->{request_start});
    }

    # Per-second cached CLF timestamp
    my $now = time();
    if ($now != $_cached_log_time) {
        $_cached_log_time = $now;
        my @gmt = gmtime($now);
        my @months = qw(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec);
        $_cached_log_timestamp = sprintf("%02d/%s/%04d:%02d:%02d:%02d +0000",
            $gmt[3], $months[$gmt[4]], $gmt[5] + 1900,
            $gmt[2], $gmt[1], $gmt[0]);
    }

    my $info = {
        client_ip       => $self->{client_host} // '-',
        timestamp       => $_cached_log_timestamp,
        method          => $request->{method} // '-',
        path            => $request->{raw_path} // '/',
        query           => $request->{query_string},
        http_version    => $request->{http_version} // '1.1',
        status          => $self->{response_status} // '-',
        size            => $self->{_response_size} // 0,
        duration        => $duration,
        request_headers => $request->{headers} // [],
    };

    my $formatter = $self->{_access_log_formatter};
    if ($formatter) {
        print {$self->{access_log}} $formatter->($info), "\n";
    }
    else {
        # Fallback (should not happen with properly initialized server)
        my $path = $info->{path};
        my $query = $info->{query};
        $path .= "?$query" if defined $query && length $query;
        print {$self->{access_log}} "$info->{client_ip} - - [$info->{timestamp}] \"$info->{method} $path\" $info->{status} $info->{duration}s\n";
    }
}

sub _handle_disconnect {
    my ($self, $reason) = @_;

    # Idempotency guard - prevent duplicate disconnect handling
    # Multiple paths can trigger disconnect (timeout, protocol error, session end)
    return if $self->{_disconnect_handled};
    $self->{_disconnect_handled} = 1;

    # Cancel any pending drain waiters (backpressure)
    $self->_cancel_drain_waiters($reason);

    # Auto-detect server shutdown (PAGI spec compliance)
    # If no explicit reason and server is shutting down, use server_shutdown
    if (!$reason && $self->{server} && $self->{server}{shutting_down}) {
        $reason = 'server_shutdown';
    }

    # Default reason is client_closed (TCP FIN received)
    $reason //= 'client_closed';

    # Mark HTTP connection state as disconnected (PAGI spec 0.3)
    # Only for HTTP - WebSocket/SSE have their own patterns
    if ($self->{current_connection_state} && !$self->{websocket_mode} && !$self->{sse_mode}) {
        $self->{current_connection_state}->_mark_disconnected($reason);
    }

    # Determine disconnect event type based on mode
    my $disconnect_event;
    if ($self->{websocket_mode}) {
        $disconnect_event = { type => 'websocket.disconnect', code => 1006, reason => '' };
    } elsif ($self->{sse_mode}) {
        $disconnect_event = {
            type   => 'sse.disconnect',
            reason => $self->{sse_disconnect_reason} // 'client_closed',
        };
    } else {
        $disconnect_event = { type => 'http.disconnect' };
    }

    # Queue disconnect event (do this even if already closed)
    push @{$self->{receive_queue}}, $disconnect_event;

    # Complete any pending receive
    if ($self->{receive_pending} && !$self->{receive_pending}->is_ready) {
        $self->{receive_pending}->done($disconnect_event);
        $self->{receive_pending} = undef;
    }
}

# Send a WebSocket close frame with status code and optional reason
# Per RFC 6455 Section 7.4, common codes:
#   1000 - Normal closure
#   1007 - Invalid frame payload data (e.g., invalid UTF-8)
#   1009 - Message too big
#   1011 - Unexpected condition
sub _send_close_frame {
    my ($self, $code, $reason) = @_;
    $reason //= '';

    return unless $self->{stream};
    return if $self->{close_sent};

    my $frame = Protocol::WebSocket::Frame->new(
        type   => 'close',
        buffer => pack('n', $code) . $reason,
    );

    $self->{stream}->write($frame->to_bytes);
    $self->{close_sent} = 1;
}

sub _close {
    my ($self) = @_;

    return if $self->{closed};
    $self->{closed} = 1;

    # Cancel pending drain waiters early (before other cleanup)
    $self->_cancel_drain_waiters('connection closing');

    # Clean up HTTP/2 per-stream state
    if ($self->{h2_streams}) {
        for my $stream (values %{$self->{h2_streams}}) {
            if ($stream->{body_pending} && !$stream->{body_pending}->is_ready) {
                my $event = $stream->{is_sse}
                    ? { type => 'sse.disconnect', reason => 'client_closed' }
                    : { type => 'http.disconnect' };
                $stream->{body_pending}->done($event);
            }
        }
        delete $self->{h2_streams};
    }
    if ($self->{h2_session}) {
        eval { $self->{h2_session}->terminate(0) };
        delete $self->{h2_session};
    }

    # Clean up WebSocket frame parser to free memory immediately
    delete $self->{websocket_frame};

    # Remove from server's connection list (O(1) hash delete)
    if ($self->{server}) {
        delete $self->{server}{connections}{refaddr($self)};

        # Signal drain complete if this was the last connection during shutdown
        if ($self->{server}{shutting_down} &&
            keys %{$self->{server}{connections}} == 0 &&
            $self->{server}{drain_complete} &&
            !$self->{server}{drain_complete}->is_ready) {
            $self->{server}{drain_complete}->done;
        }
    }

    # Stop idle timer
    $self->_stop_idle_timer;

    # Stop stall timer
    $self->_stop_stall_timer;

    # Stop WS/SSE idle timers
    $self->_stop_ws_idle_timer;
    $self->_stop_sse_idle_timer;

    # Stop keepalive timers
    $self->_stop_ws_keepalive;
    $self->_stop_sse_keepalive;

    # Note: _close is resource cleanup ONLY. Callers should use
    # _handle_disconnect_and_close() which handles both protocol
    # notification and cleanup.

    # Determine disconnect event type based on mode
    my $disconnect_event;
    if ($self->{websocket_mode}) {
        $disconnect_event = { type => 'websocket.disconnect', code => 1006, reason => '' };
    } elsif ($self->{sse_mode}) {
        $disconnect_event = {
            type   => 'sse.disconnect',
            reason => $self->{sse_disconnect_reason} // 'client_closed',
        };
    } else {
        $disconnect_event = { type => 'http.disconnect' };
    }

    # Cancel any tracked receive Futures that are still pending
    for my $future (@{$self->{receive_futures}}) {
        if (!$future->is_ready) {
            # Complete with disconnect event instead of cancelling
            # This allows the async sub to complete cleanly
            $future->done($disconnect_event);
        }
    }
    $self->{receive_futures} = [];

    if ($self->{stream}) {
        $self->{stream}->close_when_empty;
    }
}

# Combined disconnect and close - use this from callbacks where $weak_self may
# become undefined after _handle_disconnect completes its Future callbacks.
# This method holds a strong reference to $self throughout the operation.
sub _handle_disconnect_and_close {
    my ($self, $reason) = @_;
    $self->_handle_disconnect($reason);
    $self->_close;
}

#
# TLS Support Methods
#

sub _extract_tls_info {
    my ($self) = @_;

    my $stream = $self->{stream};
    my $handle = $stream->read_handle;

    # Check if handle is an IO::Socket::SSL
    return unless $handle && $handle->isa('IO::Socket::SSL');

    my $tls_info = {
        server_cert       => undef,
        client_cert_chain => [],
        client_cert_name  => undef,
        client_cert_error => undef,
        tls_version       => undef,
        cipher_suite      => undef,
    };

    # Get TLS version - IO::Socket::SSL returns something like 'TLSv1_3'
    if (my $version_str = $handle->get_sslversion) {
        # Map version string to numeric value per TLS spec
        my %version_map = (
            'SSLv3'   => 0x0300,
            'TLSv1'   => 0x0301,
            'TLSv1_1' => 0x0302,
            'TLSv1_2' => 0x0303,
            'TLSv1_3' => 0x0304,
        );
        $tls_info->{tls_version} = $version_map{$version_str};
    }

    # Get cipher suite
    if (my $cipher = $handle->get_cipher) {
        # IO::Socket::SSL provides cipher name, we need to map to numeric
        # For now, get the raw bits if available, or store undef
        # IO::Socket::SSL doesn't easily expose the numeric cipher ID
        # We'll try to get it from the SSL object
        my $ssl = $handle->_get_ssl_object;
        if ($ssl && $ssl->can('get_cipher_bits')) {
            # Unfortunately, OpenSSL doesn't expose cipher ID easily via perl bindings
            # We'll leave cipher_suite as undef for this reference implementation
            # A production server could use Net::SSLeay::get_current_cipher and
            # Net::SSLeay::CIPHER_get_id for the actual numeric ID
            eval {
                require Net::SSLeay;
                my $current_cipher = Net::SSLeay::get_current_cipher($ssl);
                if ($current_cipher) {
                    my $id = Net::SSLeay::CIPHER_get_id($current_cipher);
                    # The ID from OpenSSL includes protocol bits in upper bytes
                    # We want just the cipher suite ID (lower 16 bits usually, but SSL3+ uses different encoding)
                    # For TLS, the ID is returned as a 32-bit value with protocol in upper bits
                    # Extract lower 16 bits for the cipher suite
                    $tls_info->{cipher_suite} = $id & 0xFFFF if defined $id;
                }
            };
            if ($@) {
                warn "TLS cipher suite extraction error: $@\n";
                $tls_info->{cipher_extraction_error} = $@;
            }
        }
    }

    # Get server certificate (our certificate)
    # IO::Socket::SSL uses sock_certificate() for the server's own cert
    eval {
        my $cert = $handle->sock_certificate;
        if ($cert) {
            require Net::SSLeay;
            $tls_info->{server_cert} = Net::SSLeay::PEM_get_string_X509($cert);
        }
    };
    if ($@) {
        warn "TLS server certificate extraction error: $@\n";
        $tls_info->{server_cert_error} = $@;
    }

    # Get client certificate if provided
    eval {
        my $client_cert = $handle->peer_certificate;
        if ($client_cert) {
            require Net::SSLeay;

            # Get client cert chain
            my @chain;
            push @chain, Net::SSLeay::PEM_get_string_X509($client_cert);

            # Try to get additional certs in chain
            if (my $ssl = $handle->_get_ssl_object) {
                my $chain_obj = Net::SSLeay::get_peer_cert_chain($ssl);
                if ($chain_obj) {
                    for my $i (0 .. Net::SSLeay::sk_X509_num($chain_obj) - 1) {
                        my $cert = Net::SSLeay::sk_X509_value($chain_obj, $i);
                        push @chain, Net::SSLeay::PEM_get_string_X509($cert) if $cert;
                    }
                }
            }
            $tls_info->{client_cert_chain} = \@chain;

            # Get client cert DN (Subject)
            my $subject = Net::SSLeay::X509_NAME_oneline(
                Net::SSLeay::X509_get_subject_name($client_cert)
            );
            $tls_info->{client_cert_name} = $subject if $subject;

            # Check for verification errors
            my $verify_result = $handle->get_sslversion_int;
            # Actually, use verify_result
            if (my $ssl = $handle->_get_ssl_object) {
                my $result = Net::SSLeay::get_verify_result($ssl);
                if ($result != 0) {  # X509_V_OK = 0
                    $tls_info->{client_cert_error} = Net::SSLeay::X509_verify_cert_error_string($result);
                }
            }
        }
    };
    if ($@) {
        warn "TLS client certificate extraction error: $@\n";
        $tls_info->{client_cert_extraction_error} = $@;
    }

    $self->{tls_info} = $tls_info;
}

sub _get_scheme {
    my ($self) = @_;

    return $self->{tls_enabled} ? 'https' : 'http';
}

sub _get_ws_scheme {
    my ($self) = @_;

    return $self->{tls_enabled} ? 'wss' : 'ws';
}

sub _get_extensions_for_scope {
    my ($self) = @_;

    my %extensions = %{$self->{extensions}};

    # Add TLS info to extensions if this is a TLS connection
    if ($self->{tls_enabled} && $self->{tls_info}) {
        $extensions{tls} = $self->{tls_info};
    }
    # Remove tls extension if not a TLS connection (per spec)
    elsif (!$self->{tls_enabled}) {
        delete $extensions{tls};
    }

    return \%extensions;
}

#
# SSE (Server-Sent Events) Support Methods
#

async sub _handle_sse_request {
    my ($self, $request) = @_;

    $self->{sse_mode} = 1;
    $self->_stop_idle_timer;  # SSE connections are long-lived
    $self->_start_sse_idle_timer;  # Start SSE-specific idle timer if configured

    my $scope = $self->_create_sse_scope($request);
    my $receive = $self->_create_sse_receive($request);
    my $send = $self->_create_sse_send($request);

    eval {
        await $self->{app}->($scope, $receive, $send);
    };

    if (my $error = $@) {
        # If SSE not yet started, send HTTP error
        if (!$self->{sse_started}) {
            $self->_send_error_response(500, "Internal Server Error");
        }
        warn "PAGI application error (SSE): $error\n";
    }

    # Send chunked terminator if SSE was started (uses chunked encoding)
    # Check both closed flag and that stream is still writable
    if ($self->{sse_started} && !$self->{closed} &&
        $self->{stream} && $self->{stream}->write_handle) {
        $self->{stream}->write("0\r\n\r\n");
    }

    # Write access log entry (logs at connection close with total duration)
    $self->_write_access_log;

    # Close connection after SSE stream ends
    $self->_handle_disconnect_and_close('stream_complete');
}

sub _create_sse_scope {
    my ($self, $request) = @_;

    my $scope = {
        type         => 'sse',
        pagi         => {
            version      => '0.2',
            spec_version => '0.2',
            features     => {},
        },
        http_version => $request->{http_version},
        method       => $request->{method},
        scheme       => $self->_get_scheme,
        path         => $request->{path},
        raw_path     => $request->{raw_path},
        query_string => $request->{query_string},
        root_path    => '',
        headers      => $request->{headers},
        client       => [$self->{client_host}, $self->{client_port}],
        server       => [$self->{server_host}, $self->{server_port}],
        # Optimized: avoid hash copy when state is empty (common case)
        state        => keys %{$self->{state}} ? { %{$self->{state}} } : {},
        extensions   => $self->_get_extensions_for_scope,
    };

    return $scope;
}

sub _create_sse_receive {
    my ($self, $request) = @_;

    my $content_length = $request->{content_length};
    my $has_body = defined($content_length) && $content_length > 0;
    my $body_complete = 0;
    my $bytes_read = 0;

    weaken(my $weak_self = $self);

    # Helper to create SSE disconnect event with reason
    my $sse_disconnect = sub {
        return {
            type   => 'sse.disconnect',
            reason => ($weak_self ? $weak_self->{sse_disconnect_reason} : undef) // 'client_closed',
        };
    };

    return sub {
        return Future->done($sse_disconnect->())
            unless $weak_self;
        return Future->done($sse_disconnect->())
            if $weak_self->{closed};

        my $future = (async sub {
            return $sse_disconnect->()
                unless $weak_self;
            return $sse_disconnect->()
                if $weak_self->{closed};

            # Check queue first
            if (@{$weak_self->{receive_queue}}) {
                return shift @{$weak_self->{receive_queue}};
            }

            # Handle request body for POST/PUT SSE requests
            if ($has_body && !$body_complete) {
                my $remaining = $content_length - $bytes_read;

                # Wait for data if buffer is empty
                while (length($weak_self->{buffer}) == 0 && !$weak_self->{closed} && $remaining > 0) {
                    if (!$weak_self->{receive_pending}) {
                        $weak_self->{receive_pending} = Future->new;
                    }
                    await $weak_self->{receive_pending};
                    $weak_self->{receive_pending} = undef;

                    if (@{$weak_self->{receive_queue}}) {
                        return shift @{$weak_self->{receive_queue}};
                    }
                }

                return $sse_disconnect->() if $weak_self->{closed};

                # Read available data up to remaining
                my $to_read = $remaining < length($weak_self->{buffer})
                    ? $remaining
                    : length($weak_self->{buffer});

                my $chunk = substr($weak_self->{buffer}, 0, $to_read, '');
                $bytes_read += length($chunk);

                my $more = ($bytes_read < $content_length) ? 1 : 0;
                $body_complete = 1 if !$more;

                return {
                    type => 'sse.request',
                    body => $chunk,
                    more => $more,
                };
            }

            # No body or body complete - return empty body if not yet returned
            if (!$body_complete) {
                $body_complete = 1;
                return {
                    type => 'sse.request',
                    body => '',
                    more => 0,
                };
            }

            # Wait for disconnect
            while (1) {
                if (@{$weak_self->{receive_queue}}) {
                    return shift @{$weak_self->{receive_queue}};
                }

                return $sse_disconnect->()
                    if $weak_self->{closed};

                if (!$weak_self->{receive_pending}) {
                    $weak_self->{receive_pending} = Future->new;
                }
                await $weak_self->{receive_pending};
                $weak_self->{receive_pending} = undef;
            }
        })->();

        # Track this Future
        push @{$weak_self->{receive_futures}}, $future;
        @{$weak_self->{receive_futures}} = grep { !$_->is_ready } @{$weak_self->{receive_futures}};

        return $future;
    };
}

sub _format_sse_event {
    my ($event) = @_;
    my $sse_data = '';
    if (defined $event->{event} && length $event->{event}) {
        $sse_data .= "event: $event->{event}\n";
    }
    my $data = $event->{data} // '';
    for my $line (split /\r?\n|\r/, $data, -1) {
        $sse_data .= "data: $line\n";
    }
    if (defined $event->{id} && length $event->{id}) {
        $sse_data .= "id: $event->{id}\n";
    }
    if (defined $event->{retry}) {
        $sse_data .= "retry: $event->{retry}\n";
    }
    $sse_data .= "\n";
    return $sse_data;
}

sub _format_sse_comment {
    my ($event) = @_;
    my $text = $event->{comment} // '';
    my $formatted = '';
    for my $line (split /\r?\n|\r/, $text, -1) {
        $line = ":$line" unless $line =~ /^:/;
        $formatted .= "$line\n";
    }
    $formatted .= "\n";
    return $formatted;
}

sub _create_sse_send {
    my ($self, $request) = @_;

    weaken(my $weak_self = $self);

    return async sub  {
        my ($event) = @_;
        return Future->done unless $weak_self;
        return Future->done if $weak_self->{closed};

        # Reset SSE idle timer on send activity
        $weak_self->_reset_sse_idle_timer;

        my $type = $event->{type} // '';

        # Dev-mode event validation (PAGI spec compliance)
        if ($weak_self->{validate_events}) {
            require PAGI::Server::EventValidator;
            PAGI::Server::EventValidator::validate_sse_send($event);
        }

        if ($type eq 'sse.start') {
            return if $weak_self->{sse_started};
            $weak_self->{sse_started} = 1;
            $weak_self->{response_started} = 1;

            my $status = $event->{status} // 200;
            $weak_self->{response_status} = $status;  # Track for access logging
            my $headers = $event->{headers} // [];

            # Ensure Content-Type is text/event-stream
            my $has_content_type = 0;
            for my $h (@$headers) {
                if (lc($h->[0]) eq 'content-type') {
                    $has_content_type = 1;
                    last;
                }
            }

            my @final_headers = @$headers;
            if (!$has_content_type) {
                push @final_headers, ['content-type', 'text/event-stream'];
            }

            # Add Cache-Control and Connection headers for SSE
            push @final_headers, ['cache-control', 'no-cache'];
            push @final_headers, ['connection', 'keep-alive'];
            push @final_headers, ['date', $weak_self->{protocol}->format_date];

            # SSE uses chunked encoding implicitly (no Content-Length)
            my $response = $weak_self->{protocol}->serialize_response_start(
                $status, \@final_headers, 1  # chunked = 1
            );

            $weak_self->{stream}->write($response);

            # Set protocol-specific keepalive writer (HTTP/1.1 chunked)
            $weak_self->{sse_keepalive_writer} = sub {
                my ($text) = @_;
                return unless $weak_self;
                return if $weak_self->{closed};
                my $len = sprintf("%x", length($text));
                $weak_self->{stream}->write("$len\r\n$text\r\n");
            };
        }
        elsif ($type eq 'sse.send') {
            return unless $weak_self->{sse_started};

            # --- BACKPRESSURE CHECK ---
            if ($weak_self->_get_write_buffer_size >= $weak_self->{write_high_watermark}) {
                await $weak_self->_wait_for_drain;
                return Future->done unless $weak_self;
                return Future->done if $weak_self->{closed};
            }
            # --- END BACKPRESSURE CHECK ---

            my $sse_data = _format_sse_event($event);

            # Send as chunked data
            my $len = sprintf("%x", length($sse_data));
            $weak_self->{stream}->write("$len\r\n$sse_data\r\n");
        }
        elsif ($type eq 'sse.comment') {
            return unless $weak_self->{sse_started};

            my $comment = _format_sse_comment($event);

            my $len = sprintf("%x", length($comment));
            $weak_self->{stream}->write("$len\r\n$comment\r\n");
        }
        elsif ($type eq 'sse.keepalive') {
            # SSE keepalive - starts/stops periodic comment timer
            my $interval = $event->{interval} // 0;
            my $comment = $event->{comment};

            if ($interval > 0) {
                $weak_self->_start_sse_keepalive($interval, $comment);
            }
            else {
                $weak_self->_stop_sse_keepalive;
            }
        }
        elsif ($type eq 'http.fullflush') {
            # Fullflush extension - force immediate TCP buffer flush
            # Per spec: servers that don't advertise the extension must reject
            unless (exists $weak_self->{extensions}{fullflush}) {
                warn "PAGI: http.fullflush event rejected - extension not enabled\n";
                die "Extension not enabled: fullflush\n";
            }

            # Force flush by ensuring TCP_NODELAY
            my $handle = $weak_self->{stream}->write_handle;
            if ($handle && $handle->can('setsockopt')) {
                require Socket;
                $handle->setsockopt(Socket::IPPROTO_TCP(), Socket::TCP_NODELAY(), 1);
            }
        }
        else {
            # Per PAGI spec: servers must raise exceptions for unrecognized event types
            _unrecognized_event_type($type, 'sse');
        }

        return;
    };
}

#
# WebSocket Support Methods
#

# WebSocket handshake magic GUID per RFC 6455
use constant WS_GUID => '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';

async sub _handle_websocket_request {
    my ($self, $request) = @_;

    $self->_stop_idle_timer;  # WebSocket connections are long-lived
    $self->_start_ws_idle_timer;  # Start WebSocket-specific idle timer if configured

    my $scope = $self->_create_websocket_scope($request);
    my $receive = $self->_create_websocket_receive($request);
    my $send = $self->_create_websocket_send($request);

    eval {
        await $self->{app}->($scope, $receive, $send);
    };

    if (my $error = $@) {
        # If handshake not yet done, send HTTP error
        if (!$self->{websocket_accepted}) {
            $self->_send_error_response(500, "Internal Server Error");
        }
        warn "PAGI application error (WebSocket): $error\n";
    }

    # Write access log entry (logs at connection close with total duration)
    $self->_write_access_log;

    # Close connection after WebSocket session ends
    $self->_handle_disconnect_and_close('session_complete');
}

sub _create_websocket_scope {
    my ($self, $request) = @_;

    # Extract WebSocket key and subprotocols from headers
    my $ws_key;
    my @subprotocols;

    for my $header (@{$request->{headers}}) {
        my ($name, $value) = @$header;
        if ($name eq 'sec-websocket-key') {
            $ws_key = $value;
        }
        elsif ($name eq 'sec-websocket-protocol') {
            # Parse comma-separated list of subprotocols
            push @subprotocols, map { s/^\s+|\s+$//gr } split /,/, $value;
        }
    }

    # Store ws_key for handshake response
    $self->{ws_key} = $ws_key;

    my $scope = {
        type         => 'websocket',
        pagi         => {
            version      => '0.2',
            spec_version => '0.2',
            features     => {},
        },
        http_version => $request->{http_version},
        scheme       => $self->_get_ws_scheme,
        path         => $request->{path},
        raw_path     => $request->{raw_path},
        query_string => $request->{query_string},
        root_path    => '',
        headers      => $request->{headers},
        client       => [$self->{client_host}, $self->{client_port}],
        server       => [$self->{server_host}, $self->{server_port}],
        subprotocols => \@subprotocols,
        # Optimized: avoid hash copy when state is empty (common case)
        state        => keys %{$self->{state}} ? { %{$self->{state}} } : {},
        extensions   => $self->_get_extensions_for_scope,
    };

    return $scope;
}

sub _create_websocket_receive {
    my ($self, $request) = @_;

    my $connect_sent = 0;
    weaken(my $weak_self = $self);

    return sub {
        return Future->done({ type => 'websocket.disconnect', code => 1006, reason => '' })
            unless $weak_self;

        # Check queue first - drain queued messages even if closed
        if (@{$weak_self->{receive_queue}}) {
            return Future->done(shift @{$weak_self->{receive_queue}});
        }

        return Future->done({ type => 'websocket.disconnect', code => 1006, reason => '' })
            if $weak_self->{closed};

        my $future = (async sub {
            return { type => 'websocket.disconnect', code => 1006, reason => '' }
                unless $weak_self;

            # Check queue first - drain queued messages even if closed
            if (@{$weak_self->{receive_queue}}) {
                return shift @{$weak_self->{receive_queue}};
            }

            return { type => 'websocket.disconnect', code => 1006, reason => '' }
                if $weak_self->{closed};

            # First call returns websocket.connect
            if (!$connect_sent) {
                $connect_sent = 1;
                return { type => 'websocket.connect' };
            }

            # If not in WebSocket mode yet (waiting for accept), wait
            while (!$weak_self->{websocket_mode} && !$weak_self->{closed}) {
                if (!$weak_self->{receive_pending}) {
                    $weak_self->{receive_pending} = Future->new;
                }
                await $weak_self->{receive_pending};
                $weak_self->{receive_pending} = undef;

                if (@{$weak_self->{receive_queue}}) {
                    return shift @{$weak_self->{receive_queue}};
                }
            }

            return { type => 'websocket.disconnect', code => 1006, reason => '' }
                if $weak_self->{closed};

            # Wait for events from frame processing
            while (1) {
                if (@{$weak_self->{receive_queue}}) {
                    return shift @{$weak_self->{receive_queue}};
                }

                return { type => 'websocket.disconnect', code => 1006, reason => '' }
                    if $weak_self->{closed};

                if (!$weak_self->{receive_pending}) {
                    $weak_self->{receive_pending} = Future->new;
                }
                await $weak_self->{receive_pending};
                $weak_self->{receive_pending} = undef;
            }
        })->();

        # Track this Future
        push @{$weak_self->{receive_futures}}, $future;
        @{$weak_self->{receive_futures}} = grep { !$_->is_ready } @{$weak_self->{receive_futures}};

        return $future;
    };
}

sub _create_websocket_send {
    my ($self, $request) = @_;

    weaken(my $weak_self = $self);

    return async sub  {
        my ($event) = @_;
        return Future->done unless $weak_self;
        return Future->done if $weak_self->{closed};

        # Reset WebSocket idle timer on send activity
        $weak_self->_reset_ws_idle_timer;

        my $type = $event->{type} // '';

        # Dev-mode event validation (PAGI spec compliance)
        if ($weak_self->{validate_events}) {
            require PAGI::Server::EventValidator;
            PAGI::Server::EventValidator::validate_websocket_send($event);
        }

        if ($type eq 'websocket.accept') {
            return if $weak_self->{websocket_accepted};

            # Complete the WebSocket handshake
            my $ws_key = $weak_self->{ws_key};
            my $accept_key = sha1_base64($ws_key . WS_GUID);
            # sha1_base64 doesn't add padding, but WebSocket requires it
            $accept_key .= '=' while length($accept_key) % 4;

            my @headers = (
                "HTTP/1.1 101 Switching Protocols\r\n",
                "Upgrade: websocket\r\n",
                "Connection: Upgrade\r\n",
                "Sec-WebSocket-Accept: $accept_key\r\n",
            );

            # Add subprotocol if specified (with validation)
            if (my $subprotocol = $event->{subprotocol}) {
                $subprotocol = _validate_subprotocol($subprotocol);
                push @headers, "Sec-WebSocket-Protocol: $subprotocol\r\n";
            }

            # Add custom headers if specified (with CRLF injection validation)
            if (my $extra_headers = $event->{headers}) {
                for my $h (@$extra_headers) {
                    my ($name, $value) = @$h;
                    $name = _validate_header_name($name);
                    $value = _validate_header_value($value);
                    push @headers, "$name: $value\r\n";
                }
            }

            push @headers, "\r\n";

            $weak_self->{stream}->write(join('', @headers));

            # Switch to WebSocket mode
            $weak_self->{websocket_mode} = 1;
            $weak_self->{websocket_accepted} = 1;
            $weak_self->{websocket_frame} = Protocol::WebSocket::Frame->new(
                max_payload_size => $weak_self->{max_ws_frame_size},
            );
            $weak_self->{response_status} = 101;  # Track for access logging

            # Notify any waiting receive
            if ($weak_self->{receive_pending} && !$weak_self->{receive_pending}->is_ready) {
                my $f = $weak_self->{receive_pending};
                $weak_self->{receive_pending} = undef;
                $f->done;
            }

            # Process any data that arrived before accept
            if (length($weak_self->{buffer}) > 0) {
                $weak_self->_process_websocket_frames;
            }
        }
        elsif ($type eq 'websocket.send') {
            return unless $weak_self->{websocket_mode};

            # --- BACKPRESSURE CHECK ---
            if ($weak_self->_get_write_buffer_size >= $weak_self->{write_high_watermark}) {
                await $weak_self->_wait_for_drain;
                return Future->done unless $weak_self;
                return Future->done if $weak_self->{closed};
            }
            # --- END BACKPRESSURE CHECK ---

            my $frame;
            if (defined $event->{text}) {
                $frame = Protocol::WebSocket::Frame->new(
                    buffer => $event->{text},
                    type   => 'text',
                );
            }
            elsif (defined $event->{bytes}) {
                $frame = Protocol::WebSocket::Frame->new(
                    buffer => $event->{bytes},
                    type   => 'binary',
                );
            }
            else {
                return;  # Nothing to send
            }

            my $bytes = $frame->to_bytes;
            $weak_self->{stream}->write($bytes);
        }
        elsif ($type eq 'websocket.close') {
            # If not accepted yet, send 403 Forbidden
            if (!$weak_self->{websocket_accepted}) {
                $weak_self->_send_error_response(403, 'Forbidden');
                return;
            }

            # Send close frame
            my $code = $event->{code} // 1000;
            my $reason = $event->{reason} // '';

            my $frame = Protocol::WebSocket::Frame->new(
                type   => 'close',
                buffer => pack('n', $code) . $reason,
            );

            $weak_self->{stream}->write($frame->to_bytes);
            $weak_self->{close_sent} = 1;

            # If we received a close frame, close immediately
            # Otherwise wait for close from client (handled in frame processing)
            if ($weak_self->{close_received}) {
                $weak_self->_handle_disconnect_and_close('client_closed');
            }
        }
        elsif ($type eq 'websocket.keepalive') {
            return unless $weak_self->{websocket_mode};

            my $interval = $event->{interval} // 0;
            my $timeout = $event->{timeout};

            if ($interval > 0) {
                $weak_self->_start_ws_keepalive($interval, $timeout);
            }
            else {
                $weak_self->_stop_ws_keepalive;
            }
        }
        else {
            # Per PAGI spec: servers must raise exceptions for unrecognized event types
            _unrecognized_event_type($type, 'websocket');
        }

        return;
    };
}

sub _process_websocket_frames {
    my ($self) = @_;

    return unless $self->{websocket_mode};
    return if $self->{closed};

    # Reset WebSocket idle timer on receive activity
    $self->_reset_ws_idle_timer;

    my $frame = $self->{websocket_frame};

    # Append buffer to frame parser
    $frame->append($self->{buffer});
    $self->{buffer} = '';

    # Process all complete frames - use next_bytes to get raw bytes
    # Protocol::WebSocket::Frame->next() decodes as UTF-8, which corrupts binary data
    while (defined(my $bytes = $frame->next_bytes)) {
        my $opcode = $frame->opcode;

        # RFC 6455 Section 5.2: RSV1-3 MUST be 0 unless extension defines meaning
        # PAGI doesn't support compression extensions, so RSV must always be 0
        my $rsv = $frame->rsv;
        if ($rsv && ref($rsv) eq 'ARRAY') {
            if (grep { $_ } @$rsv) {
                $self->_send_close_frame(1002, 'RSV bits must be 0');
                $self->_handle_disconnect_and_close('protocol_error');
                return;
            }
        }

        # RFC 6455 Section 5.2: Opcodes 3-7 and 11-15 (0xB-0xF) are reserved
        # Must fail connection with 1002 Protocol Error
        if (($opcode >= 3 && $opcode <= 7) || ($opcode >= 11 && $opcode <= 15)) {
            $self->_send_close_frame(1002, 'Reserved opcode');
            $self->_handle_disconnect_and_close('protocol_error');
            return;
        }

        # RFC 6455 Section 5.5: Control frames (close/ping/pong) MUST have
        # payload length <= 125 bytes
        if (($opcode == 8 || $opcode == 9 || $opcode == 10) && length($bytes) > 125) {
            $self->_send_close_frame(1002, 'Control frame too large');
            $self->_handle_disconnect_and_close('protocol_error');
            return;
        }

        if ($opcode == 1) {
            # Text frame - decode as UTF-8
            my $text = eval { Encode::decode('UTF-8', $bytes, Encode::FB_CROAK) };
            unless (defined $text) {
                # Invalid UTF-8 - close with 1007 per RFC 6455
                $self->_send_close_frame(1007, 'Invalid UTF-8');
                $self->_handle_disconnect_and_close('protocol_error');
                return;
            }
            # Check queue limit before adding (DoS protection)
            if (@{$self->{receive_queue}} >= $self->{max_receive_queue}) {
                $self->_send_close_frame(1008, 'Message queue overflow');  # Policy Violation
                $self->_handle_disconnect_and_close('policy_violation');
                return;
            }
            push @{$self->{receive_queue}}, {
                type => 'websocket.receive',
                text => $text,
            };
        }
        elsif ($opcode == 2) {
            # Binary frame - keep as raw bytes
            # Check queue limit before adding (DoS protection)
            if (@{$self->{receive_queue}} >= $self->{max_receive_queue}) {
                $self->_send_close_frame(1008, 'Message queue overflow');  # Policy Violation
                $self->_handle_disconnect_and_close('policy_violation');
                return;
            }
            push @{$self->{receive_queue}}, {
                type  => 'websocket.receive',
                bytes => $bytes,
            };
        }
        elsif ($opcode == 8) {
            # Close frame
            $self->{close_received} = 1;
            my ($code, $reason) = (1005, '');

            # RFC 6455 Section 5.5.1: Close frame payload is 0 or >=2 bytes
            # 1 byte is invalid
            if (length($bytes) == 1) {
                $self->_send_close_frame(1002, 'Invalid close frame');
                $self->_handle_disconnect_and_close('protocol_error');
                return;
            }

            if (length($bytes) >= 2) {
                $code = unpack('n', substr($bytes, 0, 2));
                $reason = substr($bytes, 2) // '';

                # RFC 6455 Section 7.4.1: Validate close code
                # Valid codes: 1000-1003, 1007-1011, 3000-4999
                # Invalid: 0-999, 1004-1006, 1012-2999, 5000+
                my $valid_code = 0;
                if ($code == 1000 || $code == 1001 || $code == 1002 || $code == 1003) {
                    $valid_code = 1;
                }
                elsif ($code >= 1007 && $code <= 1011) {
                    $valid_code = 1;
                }
                elsif ($code >= 3000 && $code <= 4999) {
                    $valid_code = 1;
                }
                unless ($valid_code) {
                    $self->_send_close_frame(1002, 'Invalid close code');
                    $self->_handle_disconnect_and_close('protocol_error');
                    return;
                }

                # RFC 6455: Close reason must be valid UTF-8
                if (length($reason) > 0) {
                    my $reason_copy = $reason;
                    my $decoded = eval { Encode::decode('UTF-8', $reason_copy, Encode::FB_CROAK) };
                    unless (defined $decoded) {
                        $self->_send_close_frame(1007, 'Invalid UTF-8 in close reason');
                        $self->_handle_disconnect_and_close('protocol_error');
                        return;
                    }
                }
            }

            # If we haven't sent close yet, send it now
            if (!$self->{close_sent}) {
                my $close_frame = Protocol::WebSocket::Frame->new(
                    type   => 'close',
                    buffer => pack('n', $code) . $reason,
                );
                $self->{stream}->write($close_frame->to_bytes);
                $self->{close_sent} = 1;
            }

            push @{$self->{receive_queue}}, {
                type   => 'websocket.disconnect',
                code   => $code,
                reason => $reason,
            };
        }
        elsif ($opcode == 9) {
            # Ping - respond with pong (transparent to app)
            my $pong = Protocol::WebSocket::Frame->new(
                type   => 'pong',
                buffer => $bytes,
            );
            $self->{stream}->write($pong->to_bytes);
        }
        elsif ($opcode == 10) {
            # Pong - cancel any pending timeout (response to our ping)
            $self->_cancel_ws_pong_timeout;
        }
    }

    # Notify any waiting receive
    if ($self->{receive_pending} && !$self->{receive_pending}->is_ready && @{$self->{receive_queue}}) {
        my $f = $self->{receive_pending};
        $self->{receive_pending} = undef;
        $f->done;
    }
}

# Async file response - prioritizes speed based on file size:
#   1. Small files (<=64KB): direct in-process read (fastest for small files)
#   2. Large files: async chunked reads via worker pool (non-blocking)
async sub _send_file_response {
    my ($self, $file, $offset, $length, $chunked) = @_;

    # Get file size if length not specified
    my $file_size = -s $file;
    die "Cannot stat file $file: $!" unless defined $file_size;
    $length //= $file_size - $offset;

    $self->{_response_size} += $length;

    my $stream = $self->{stream};

    if ($self->{sync_file_threshold} > 0 && $length <= $self->{sync_file_threshold}) {
        # Small file fast path: read directly in-process
        # For files <= 64KB, a simple read() is fast and avoids async overhead
        open my $fh, '<:raw', $file or die "Cannot open file $file: $!";
        seek($fh, $offset, 0) if $offset;
        my $bytes_read = read($fh, my $data, $length);
        close $fh;

        die "Failed to read file $file: $!" unless defined $bytes_read;

        if ($chunked) {
            my $len = sprintf("%x", length($data));
            $stream->write("$len\r\n$data\r\n");
            $stream->write("0\r\n\r\n");
        }
        else {
            $stream->write($data);
        }
    }
    else {
        # Large file path: async chunked reads via worker pool
        my $loop = $self->{server} ? $self->{server}->loop : undef;
        die "No event loop available for async file I/O" unless $loop;

        await PAGI::Server::AsyncFile->read_file_chunked(
            $loop, $file,
            sub {
                my ($chunk) = @_;
                if ($chunked) {
                    my $len = sprintf("%x", length($chunk));
                    $stream->write("$len\r\n$chunk\r\n");
                }
                else {
                    $stream->write($chunk);
                }
                return;  # Sync callback
            },
            offset     => $offset,
            length     => $length,
            chunk_size => FILE_CHUNK_SIZE,
        );

        # Send final chunk terminator if chunked
        if ($chunked) {
            $stream->write("0\r\n\r\n");
        }
    }
}

# Async filehandle response - uses worker pool for non-blocking reads
# Note: Can't easily use sendfile for arbitrary filehandles (may not have fd,
# may be pipes, may be in-memory). Falls back to chunked reads.
async sub _send_fh_response {
    my ($self, $fh, $offset, $length, $chunked) = @_;

    # Seek to offset if specified
    if ($offset && $offset > 0) {
        seek($fh, $offset, 0) or die "Cannot seek: $!";
    }

    # For filehandles, we can't easily use the worker pool (can't pass fh across fork).
    # Use blocking reads in small chunks - not ideal but practical.
    # TODO: Consider IO::Async::FileStream for better event loop integration.

    my $remaining = $length;  # undef means read to EOF
    my $stream = $self->{stream};

    while (1) {
        my $to_read = FILE_CHUNK_SIZE;
        if (defined $remaining) {
            $to_read = $remaining if $remaining < $to_read;
            last if $to_read <= 0;
        }

        my $bytes_read = read($fh, my $chunk, $to_read);

        last if !defined $bytes_read;  # Error
        last if $bytes_read == 0;      # EOF

        $self->{_response_size} += $bytes_read;

        if ($chunked) {
            my $len = sprintf("%x", length($chunk));
            $stream->write("$len\r\n$chunk\r\n");
        }
        else {
            $stream->write($chunk);
        }

        if (defined $remaining) {
            $remaining -= $bytes_read;
        }
    }

    # Send final chunk if chunked encoding
    if ($chunked) {
        $stream->write("0\r\n\r\n");
    }
}

1;

__END__

=head1 SSE OVER HTTP/2

SSE events (C<sse.start>, C<sse.send>, C<sse.comment>, C<sse.keepalive>)
work transparently over both HTTP/1.1 and HTTP/2. Applications do not need
to change their SSE handling code based on protocol version.

=head2 How It Works

When a request arrives with C<Accept: text/event-stream>, the connection
detects it as SSE regardless of HTTP version. Over HTTP/1.1, SSE data is
sent using chunked Transfer-Encoding. Over HTTP/2, SSE data is sent as
DATA frames via the C<submit_response_streaming>/C<data_callback> mechanism.
This difference is transparent to the application.

The C<http_version> field in the scope hash will be C<'2'> for HTTP/2
connections, allowing applications to distinguish if needed.

=head2 SSE Idle Timeout over HTTP/2

The C<sse_idle_timeout> setting applies at the B<connection level>,
not per-stream. Over HTTP/1.1, this is a non-issue since each SSE
stream occupies its own TCP connection. Over HTTP/2, where multiple
streams share a single connection, an idle SSE stream timeout will
close the B<entire connection>, terminating all active streams.

=head3 Trade-offs

B<Pros:>

=over 4

=item * Simple, consistent behavior across protocols

=item * Matches the approach used by Go (net/http2), Rust (hyper/Axum),
Java (Netty/Reactor Netty/Vert.x), Python (Hypercorn), and gRPC

=item * No additional complexity in stream lifecycle management

=back

B<Cons:>

=over 4

=item * Closing the connection affects all multiplexed HTTP/2 streams,
not just the idle SSE stream

=item * Clients multiplexing SSE + REST on one HTTP/2 connection may
see unexpected disconnects on their REST requests

=back

B<Recommendation:> Use SSE keepalive comments (C<sse.keepalive> event)
with an interval shorter than C<sse_idle_timeout> to prevent the timer
from firing. This is the industry-standard approach used across all
major frameworks. For production deployments behind reverse proxies
(Envoy, Nginx, HAProxy), align your keepalive interval with the
proxy's stream idle timeout.

B<Note:> Per-stream idle timeout (using HTTP/2 RST_STREAM to close
only the idle SSE stream) is a future enhancement. Only Node.js
(http2stream.setTimeout) and Envoy (stream_idle_timeout) implement
this among mainstream servers.

=head1 SEE ALSO

L<PAGI::Server>, L<PAGI::Server::Protocol::HTTP1>

=head1 AUTHOR

John Napiorkowski E<lt>jjnapiork@cpan.orgE<gt>

=head1 LICENSE

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
