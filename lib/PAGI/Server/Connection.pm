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
use IO::Async::Timer::Countdown;
use Time::HiRes qw(gettimeofday tv_interval);
use PAGI::Util::AsyncFile;

our $VERSION = '0.001';

use constant FILE_CHUNK_SIZE => 65536;  # 64KB chunks for file streaming

# Try to load Sys::Sendfile for zero-copy file transfers
# Falls back to chunked reads if not available
my $HAS_SENDFILE;
BEGIN {
    eval {
        require Sys::Sendfile;
        Sys::Sendfile->import('sendfile');
        $HAS_SENDFILE = 1;
    };
    $HAS_SENDFILE //= 0;
}

# Class method to check if sendfile is available at the system level
sub has_sendfile { return $HAS_SENDFILE }

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

=item * Protocol upgrades (WebSocket)

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
        max_body_size     => $args{max_body_size},  # undef = unlimited
        access_log        => $args{access_log},     # Filehandle for access logging
        max_receive_queue => $args{max_receive_queue} // 1000,  # Max WebSocket receive queue size
        max_ws_frame_size => $args{max_ws_frame_size} // 65536,  # Max WebSocket frame size in bytes
        disable_sendfile  => $args{disable_sendfile} // 0,  # Disable sendfile even if available
        tls_info      => undef,  # Populated on first request if TLS
        buffer        => '',
        closed        => 0,
        response_started => 0,
        response_status  => undef,  # Track response status for logging
        request_start    => undef,  # Track request start time for logging
        idle_timer    => undef,  # IO::Async::Timer for idle timeout
        # Event queue for $receive
        receive_queue   => [],
        receive_pending => undef,
        # Track all pending receive Futures to cancel on close
        receive_futures => [],
        # Track request handling Future to prevent "lost future" warning
        request_future  => undef,
        # WebSocket state
        websocket_mode    => 0,
        websocket_frame   => undef,  # Protocol::WebSocket::Frame for parsing
        websocket_accepted => 0,
        # SSE state
        sse_mode          => 0,
        sse_started       => 0,
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

    # Set up idle timeout timer
    if ($self->{timeout} && $self->{timeout} > 0 && $self->{server}) {
        my $timer = IO::Async::Timer::Countdown->new(
            delay => $self->{timeout},
            on_expire => sub {
                return unless $weak_self;
                return if $weak_self->{closed};
                # Close idle connection
                $weak_self->_close;
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

            $weak_self->{buffer} .= $$buffref;
            $$buffref = '';

            if ($eof) {
                $weak_self->_handle_disconnect;
                return 0;
            }

            # Wrap processing in eval to prevent exceptions from crashing the event loop
            # This is critical - Protocol::WebSocket::Frame can throw exceptions for
            # oversized payloads, and other parsing code may throw as well
            eval {
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
                $weak_self->_close;
            }
            return 0;
        },
        on_closed => sub {
            return unless $weak_self;
            $weak_self->_handle_disconnect;
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
        $self->_send_error_response($request->{error}, $request->{message});
        $self->_close;
        return;
    }

    # Check Content-Length against max_body_size limit
    if (defined $self->{max_body_size} && defined $request->{content_length}) {
        if ($request->{content_length} > $self->{max_body_size}) {
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
        $self->{request_future} = $self->_handle_request($request);
    }

    # Retain the future to prevent warning if connection is destroyed
    # while request is still being processed
    $self->{request_future}->retain;
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
    # - HTTP method is GET
    # - Accept header includes text/event-stream
    # - Request has not been upgraded to WebSocket (already checked)
    return 0 unless $request->{method} eq 'GET';

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
        $self->_close;
        return;
    }

    # Write access log entry
    $self->_write_access_log;

    # Notify server that request completed (for max_requests tracking)
    $self->{server}->_on_request_complete if $self->{server};

    # Determine if we should keep the connection alive
    my $keep_alive = $self->_should_keep_alive($request);

    if ($keep_alive) {
        # Reset for next request
        $self->{handling_request} = 0;
        $self->{response_started} = 0;
        $self->{response_status} = undef;
        $self->{request_start} = undef;
        $self->{current_request} = undef;
        $self->{request_future} = undef;

        # Check if there's more data in the buffer (pipelining)
        if (length($self->{buffer}) > 0) {
            $self->_try_handle_request;
        }
    } else {
        $self->_close;
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

    # Get the event loop from the server for async operations
    my $loop = $self->{server} ? $self->{server}->loop : undef;

    my $scope = {
        type         => 'http',
        pagi         => {
            version      => '0.1',
            spec_version => '0.1',
            features     => {},
            loop         => $loop,  # IO::Async::Loop for async operations
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
        state        => %{$self->{state}} ? { %{$self->{state}} } : {},
        extensions   => $self->_get_extensions_for_scope,
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
                    $weak_self->_send_error_response($data->{error}, $data->{message} // 'Bad Request');
                    $weak_self->_close;
                    return { type => 'http.disconnect' };
                }

                if ($consumed > 0) {
                    substr($weak_self->{buffer}, 0, $consumed) = '';

                    # Track total bytes read for max_body_size check
                    $bytes_read += length($data // '');

                    # Check max_body_size for chunked requests
                    if (defined $weak_self->{max_body_size} && $bytes_read > $weak_self->{max_body_size}) {
                        # Body too large - close connection
                        $weak_self->_send_error_response(413, 'Payload Too Large');
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

        my $type = $event->{type} // '';

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
    my $method = $request->{method} // '-';
    my $path = $request->{raw_path} // '/';
    my $query = $request->{query_string};
    $path .= "?$query" if defined $query && length $query;

    my $status = $self->{response_status} // '-';

    # Calculate request duration
    my $duration = '-';
    if ($self->{request_start}) {
        $duration = sprintf("%.3f", tv_interval($self->{request_start}));
    }

    # Get client IP
    my $client_ip = '-';
    my $handle = $self->{stream} ? $self->{stream}->read_handle : undef;
    if ($handle && $handle->can('peerhost')) {
        $client_ip = $handle->peerhost // '-';
    }

    # Format: client_ip - - [timestamp] "METHOD /path" status duration
    my @gmt = gmtime(time);
    my @months = qw(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec);
    my $timestamp = sprintf("%02d/%s/%04d:%02d:%02d:%02d +0000",
        $gmt[3], $months[$gmt[4]], $gmt[5] + 1900,
        $gmt[2], $gmt[1], $gmt[0]);

    my $log = $self->{access_log};
    print $log "$client_ip - - [$timestamp] \"$method $path\" $status ${duration}s\n";
}

sub _handle_disconnect {
    my ($self) = @_;

    # Determine disconnect event type based on mode
    my $disconnect_event;
    if ($self->{websocket_mode}) {
        $disconnect_event = { type => 'websocket.disconnect', code => 1006, reason => '' };
    } elsif ($self->{sse_mode}) {
        $disconnect_event = { type => 'sse.disconnect' };
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

    # Complete any pending receive with disconnect
    $self->_handle_disconnect;

    # Determine disconnect event type based on mode
    my $disconnect_event;
    if ($self->{websocket_mode}) {
        $disconnect_event = { type => 'websocket.disconnect', code => 1006, reason => '' };
    } elsif ($self->{sse_mode}) {
        $disconnect_event = { type => 'sse.disconnect' };
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
    if ($self->{sse_started} && !$self->{closed}) {
        $self->{stream}->write("0\r\n\r\n");
    }

    # Write access log entry (logs at connection close with total duration)
    $self->_write_access_log;

    # Close connection after SSE stream ends
    $self->_close;
}

sub _create_sse_scope {
    my ($self, $request) = @_;

    # Get the event loop from the server for async operations
    my $loop = $self->{server} ? $self->{server}->loop : undef;

    my $scope = {
        type         => 'sse',
        pagi         => {
            version      => '0.1',
            spec_version => '0.1',
            features     => {},
            loop         => $loop,
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
        state        => %{$self->{state}} ? { %{$self->{state}} } : {},
        extensions   => $self->_get_extensions_for_scope,
    };

    return $scope;
}

sub _create_sse_receive {
    my ($self, $request) = @_;

    weaken(my $weak_self = $self);

    return sub {
        return Future->done({ type => 'sse.disconnect' })
            unless $weak_self;
        return Future->done({ type => 'sse.disconnect' })
            if $weak_self->{closed};

        my $future = (async sub {
            return { type => 'sse.disconnect' }
                unless $weak_self;
            return { type => 'sse.disconnect' }
                if $weak_self->{closed};

            # Check queue first
            if (@{$weak_self->{receive_queue}}) {
                return shift @{$weak_self->{receive_queue}};
            }

            # Wait for disconnect
            while (1) {
                if (@{$weak_self->{receive_queue}}) {
                    return shift @{$weak_self->{receive_queue}};
                }

                return { type => 'sse.disconnect' }
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

sub _create_sse_send {
    my ($self, $request) = @_;

    weaken(my $weak_self = $self);

    return async sub  {
        my ($event) = @_;
        return Future->done unless $weak_self;
        return Future->done if $weak_self->{closed};

        my $type = $event->{type} // '';

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
        }
        elsif ($type eq 'sse.send') {
            return unless $weak_self->{sse_started};

            # Format SSE event
            my $sse_data = '';

            # event: field (optional)
            if (defined $event->{event} && length $event->{event}) {
                $sse_data .= "event: $event->{event}\n";
            }

            # data: field (required) - handle multi-line data
            my $data = $event->{data} // '';
            for my $line (split /\n/, $data, -1) {
                $sse_data .= "data: $line\n";
            }

            # id: field (optional)
            if (defined $event->{id} && length $event->{id}) {
                $sse_data .= "id: $event->{id}\n";
            }

            # retry: field (optional)
            if (defined $event->{retry}) {
                $sse_data .= "retry: $event->{retry}\n";
            }

            # Empty line to end the event
            $sse_data .= "\n";

            # Send as chunked data
            my $len = sprintf("%x", length($sse_data));
            $weak_self->{stream}->write("$len\r\n$sse_data\r\n");
        }
        elsif ($type eq 'sse.comment') {
            # SSE comment - sent as-is without data: prefix
            # Used for keepalives that shouldn't trigger onmessage
            return unless $weak_self->{sse_started};

            my $comment = $event->{comment} // '';
            # Ensure comment starts with : and ends with newlines
            $comment = ":$comment" unless $comment =~ /^:/;
            $comment .= "\n\n";

            my $len = sprintf("%x", length($comment));
            $weak_self->{stream}->write("$len\r\n$comment\r\n");
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
    $self->_close;
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

    # Get the event loop from the server for async operations
    my $loop = $self->{server} ? $self->{server}->loop : undef;

    my $scope = {
        type         => 'websocket',
        pagi         => {
            version      => '0.1',
            spec_version => '0.1',
            features     => {},
            loop         => $loop,
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
        state        => %{$self->{state}} ? { %{$self->{state}} } : {},
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
        return Future->done({ type => 'websocket.disconnect', code => 1006, reason => '' })
            if $weak_self->{closed};

        my $future = (async sub {
            return { type => 'websocket.disconnect', code => 1006, reason => '' }
                unless $weak_self;
            return { type => 'websocket.disconnect', code => 1006, reason => '' }
                if $weak_self->{closed};

            # Check queue first
            if (@{$weak_self->{receive_queue}}) {
                return shift @{$weak_self->{receive_queue}};
            }

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

        my $type = $event->{type} // '';

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
                $weak_self->_close;
            }
        }

        return;
    };
}

sub _process_websocket_frames {
    my ($self) = @_;

    return unless $self->{websocket_mode};
    return if $self->{closed};

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
                $self->_close;
                return;
            }
        }

        # RFC 6455 Section 5.2: Opcodes 3-7 and 11-15 (0xB-0xF) are reserved
        # Must fail connection with 1002 Protocol Error
        if (($opcode >= 3 && $opcode <= 7) || ($opcode >= 11 && $opcode <= 15)) {
            $self->_send_close_frame(1002, 'Reserved opcode');
            $self->_close;
            return;
        }

        # RFC 6455 Section 5.5: Control frames (close/ping/pong) MUST have
        # payload length <= 125 bytes
        if (($opcode == 8 || $opcode == 9 || $opcode == 10) && length($bytes) > 125) {
            $self->_send_close_frame(1002, 'Control frame too large');
            $self->_close;
            return;
        }

        if ($opcode == 1) {
            # Text frame - decode as UTF-8
            my $text = eval { Encode::decode('UTF-8', $bytes, Encode::FB_CROAK) };
            unless (defined $text) {
                # Invalid UTF-8 - close with 1007 per RFC 6455
                $self->_send_close_frame(1007, 'Invalid UTF-8');
                $self->_close;
                return;
            }
            # Check queue limit before adding (DoS protection)
            if (@{$self->{receive_queue}} >= $self->{max_receive_queue}) {
                $self->_send_close_frame(1008, 'Message queue overflow');  # Policy Violation
                $self->_close;
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
                $self->_close;
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
                $self->_close;
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
                    $self->_close;
                    return;
                }

                # RFC 6455: Close reason must be valid UTF-8
                if (length($reason) > 0) {
                    my $decoded = eval { Encode::decode('UTF-8', $reason, Encode::FB_CROAK) };
                    unless (defined $decoded) {
                        $self->_send_close_frame(1007, 'Invalid UTF-8 in close reason');
                        $self->_close;
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
            # Pong - ignore (response to our ping, if any)
        }
    }

    # Notify any waiting receive
    if ($self->{receive_pending} && !$self->{receive_pending}->is_ready && @{$self->{receive_queue}}) {
        my $f = $self->{receive_pending};
        $self->{receive_pending} = undef;
        $f->done;
    }
}

# Check if we can use sendfile() for this connection
sub _can_use_sendfile {
    my ($self, $chunked) = @_;

    return 0 unless $HAS_SENDFILE;
    return 0 if $self->{disable_sendfile};  # Explicitly disabled
    return 0 if $self->{tls_enabled};       # Can't sendfile over TLS
    return 0 if $chunked;                   # Can't sendfile with chunked encoding (need headers)
    return 1;
}

# Async file response - prioritizes speed based on file size:
#   1. Small files (<=64KB): direct in-process read (fastest for small files)
#   2. Large files with sendfile: zero-copy kernel transfer (fastest for large files)
#   3. Large files without sendfile: worker pool (non-blocking fallback)
async sub _send_file_response {
    my ($self, $file, $offset, $length, $chunked) = @_;

    # Get file size if length not specified
    my $file_size = -s $file;
    die "Cannot stat file $file: $!" unless defined $file_size;
    $length //= $file_size - $offset;

    if ($length <= FILE_CHUNK_SIZE) {
        # Small file fast path: read directly in-process (no syscall/IPC overhead)
        # For files <= 64KB, a simple read() beats sendfile() due to syscall overhead
        open my $fh, '<:raw', $file or die "Cannot open file $file: $!";
        seek($fh, $offset, 0) if $offset;
        my $bytes_read = read($fh, my $data, $length);
        close $fh;

        die "Failed to read file $file: $!" unless defined $bytes_read;

        my $stream = $self->{stream};
        if ($chunked) {
            my $len = sprintf("%x", length($data));
            $stream->write("$len\r\n$data\r\n");
            $stream->write("0\r\n\r\n");
        }
        else {
            $stream->write($data);
        }
    }
    elsif ($self->_can_use_sendfile($chunked)) {
        # Large file sendfile path: zero-copy kernel transfer
        # Ensure headers are flushed before sendfile (sendfile bypasses IO::Async buffer)
        await $self->{stream}->write('');

        open my $fh, '<:raw', $file or die "Cannot open file $file: $!";
        my $socket = $self->{stream}->write_handle;

        # sendfile may not send all bytes in one call, loop until done
        # Sys::Sendfile expects filehandles, not file descriptor numbers
        my $sent = 0;
        while ($sent < $length) {
            my $to_send = $length - $sent;
            my $current_offset = $offset + $sent;
            my $result = sendfile($socket, $fh, $to_send, $current_offset);
            if (!defined $result || $result < 0) {
                close $fh;
                die "sendfile failed: $!";
            }
            $sent += $result;
            last if $result == 0;  # EOF
        }
        close $fh;
    }
    else {
        # Worker pool path - non-blocking chunked reads for large files
        # Used when sendfile unavailable (TLS, chunked encoding, no Sys::Sendfile)
        my $loop = $self->{server} ? $self->{server}->loop : undef;
        die "No event loop available for async file I/O" unless $loop;

        my $stream = $self->{stream};

        await PAGI::Util::AsyncFile->read_file_chunked(
            $loop, $file,
            sub  {
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

=head1 SEE ALSO

L<PAGI::Server>, L<PAGI::Server::Protocol::HTTP1>

=head1 AUTHOR

John Napiorkowski E<lt>jjnapiork@cpan.orgE<gt>

=head1 LICENSE

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
