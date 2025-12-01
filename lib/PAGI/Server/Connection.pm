package PAGI::Server::Connection;
use strict;
use warnings;
use experimental 'signatures';
use Future;
use Future::AsyncAwait;
use Scalar::Util qw(weaken);
use Protocol::WebSocket::Handshake::Server;
use Protocol::WebSocket::Frame;
use Digest::SHA qw(sha1_base64);
use Encode;

our $VERSION = '0.001';

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

sub new ($class, %args) {
    my $self = bless {
        stream      => $args{stream},
        app         => $args{app},
        protocol    => $args{protocol},
        server      => $args{server},
        extensions  => $args{extensions} // {},
        state       => $args{state} // {},
        buffer      => '',
        closed      => 0,
        response_started => 0,
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
    }, $class;

    return $self;
}

sub start ($self) {
    my $stream = $self->{stream};
    weaken(my $weak_self = $self);

    # Set up read handler
    $stream->configure(
        on_read => sub ($s, $buffref, $eof) {
            return 0 unless $weak_self;

            $weak_self->{buffer} .= $$buffref;
            $$buffref = '';

            if ($eof) {
                $weak_self->_handle_disconnect;
                return 0;
            }

            # If in WebSocket mode, process WebSocket frames
            if ($weak_self->{websocket_mode}) {
                $weak_self->_process_websocket_frames;
                return 0;
            }

            # If we're waiting for body data, notify the receive handler
            if ($weak_self->{receive_pending} && !$weak_self->{receive_pending}->is_ready) {
                my $f = $weak_self->{receive_pending};
                $weak_self->{receive_pending} = undef;
                $f->done;
            }

            $weak_self->_try_handle_request;
            return 0;
        },
        on_closed => sub {
            return unless $weak_self;
            $weak_self->_handle_disconnect;
        },
    );
}

sub _try_handle_request ($self) {
    return if $self->{closed};
    return if $self->{handling_request};

    # Try to parse a request from the buffer
    my ($request, $consumed) = $self->{protocol}->parse_request($self->{buffer});

    return unless $request;

    # Remove consumed bytes from buffer
    substr($self->{buffer}, 0, $consumed) = '';

    # Check if this is a WebSocket upgrade request
    my $is_websocket = $self->_is_websocket_upgrade($request);

    # Handle the request - store the Future to prevent "lost future" warning
    $self->{handling_request} = 1;

    if ($is_websocket) {
        $self->{request_future} = $self->_handle_websocket_request($request);
    } else {
        $self->{request_future} = $self->_handle_request($request);
    }

    # Retain the future to prevent warning if connection is destroyed
    # while request is still being processed
    $self->{request_future}->retain;
}

sub _is_websocket_upgrade ($self, $request) {
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

async sub _handle_request ($self, $request) {
    my $scope = $self->_create_scope($request);
    my $receive = $self->_create_receive($request);
    my $send = $self->_create_send($request);

    eval {
        await $self->{app}->($scope, $receive, $send);
    };

    if (my $error = $@) {
        # Handle application error
        $self->_send_error_response(500, "Internal Server Error");
        warn "PAGI application error: $error\n";
    }

    # Close connection after response (no keep-alive for now)
    $self->_close;
}

sub _create_scope ($self, $request) {
    my $stream = $self->{stream};
    my $handle = $stream->read_handle;

    # Get client and server addresses
    my ($client_host, $client_port) = ('127.0.0.1', 0);
    my ($server_host, $server_port) = ('127.0.0.1', 5000);

    if ($handle && $handle->can('peerhost')) {
        $client_host = $handle->peerhost // '127.0.0.1';
        $client_port = $handle->peerport // 0;
        $server_host = $handle->sockhost // '127.0.0.1';
        $server_port = $handle->sockport // 5000;
    }

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
        scheme       => 'http',  # Will be 'https' when TLS is enabled
        path         => $request->{path},
        raw_path     => $request->{raw_path},
        query_string => $request->{query_string},
        root_path    => '',
        headers      => $request->{headers},
        client       => [$client_host, $client_port],
        server       => [$server_host, $server_port],
        state        => $self->{state},
        extensions   => $self->{extensions},
    };

    return $scope;
}

sub _create_receive ($self, $request) {
    my $content_length = $request->{content_length};
    my $is_chunked = $request->{chunked} // 0;
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

                if ($consumed > 0) {
                    substr($weak_self->{buffer}, 0, $consumed) = '';

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

sub _create_send ($self, $request) {
    my $chunked = 0;
    my $response_started = 0;
    my $expects_trailers = 0;
    my $body_complete = 0;

    weaken(my $weak_self = $self);

    return async sub ($event) {
        return Future->done unless $weak_self;
        return Future->done if $weak_self->{closed};

        my $type = $event->{type} // '';

        if ($type eq 'http.response.start') {
            return if $response_started;
            $response_started = 1;
            $weak_self->{response_started} = 1;
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

            $chunked = !$has_content_length;

            my $response = $weak_self->{protocol}->serialize_response_start(
                $status, \@final_headers, $chunked
            );

            $weak_self->{stream}->write($response);
        }
        elsif ($type eq 'http.response.body') {
            return unless $response_started;
            return if $body_complete;

            my $body = $event->{body} // '';
            my $more = $event->{more} // 0;

            if ($chunked) {
                # For chunked encoding, send the chunk
                if (length $body) {
                    my $len = sprintf("%x", length($body));
                    $weak_self->{stream}->write("$len\r\n$body\r\n");
                }

                # If no more body data coming
                if (!$more) {
                    $body_complete = 1;
                    # If trailers are expected, don't send final chunk terminator yet
                    # The trailers event will send it
                    if (!$expects_trailers) {
                        $weak_self->{stream}->write("0\r\n\r\n");
                    }
                }
            }
            else {
                # Non-chunked: just send the body
                $weak_self->{stream}->write($body) if length $body;
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

        return;
    };
}

sub _send_error_response ($self, $status, $message) {
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
}

sub _handle_disconnect ($self) {
    # Determine disconnect event type based on mode
    my $disconnect_event;
    if ($self->{websocket_mode}) {
        $disconnect_event = { type => 'websocket.disconnect', code => 1006, reason => '' };
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

sub _close ($self) {
    return if $self->{closed};
    $self->{closed} = 1;

    # Complete any pending receive with disconnect
    $self->_handle_disconnect;

    # Determine disconnect event type based on mode
    my $disconnect_event = $self->{websocket_mode}
        ? { type => 'websocket.disconnect', code => 1006, reason => '' }
        : { type => 'http.disconnect' };

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
# WebSocket Support Methods
#

# WebSocket handshake magic GUID per RFC 6455
use constant WS_GUID => '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';

async sub _handle_websocket_request ($self, $request) {
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

    # Close connection after WebSocket session ends
    $self->_close;
}

sub _create_websocket_scope ($self, $request) {
    my $stream = $self->{stream};
    my $handle = $stream->read_handle;

    # Get client and server addresses
    my ($client_host, $client_port) = ('127.0.0.1', 0);
    my ($server_host, $server_port) = ('127.0.0.1', 5000);

    if ($handle && $handle->can('peerhost')) {
        $client_host = $handle->peerhost // '127.0.0.1';
        $client_port = $handle->peerport // 0;
        $server_host = $handle->sockhost // '127.0.0.1';
        $server_port = $handle->sockport // 5000;
    }

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
        scheme       => 'ws',  # Will be 'wss' when TLS is enabled
        path         => $request->{path},
        raw_path     => $request->{raw_path},
        query_string => $request->{query_string},
        root_path    => '',
        headers      => $request->{headers},
        client       => [$client_host, $client_port],
        server       => [$server_host, $server_port],
        subprotocols => \@subprotocols,
        state        => $self->{state},
        extensions   => $self->{extensions},
    };

    return $scope;
}

sub _create_websocket_receive ($self, $request) {
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

sub _create_websocket_send ($self, $request) {
    weaken(my $weak_self = $self);

    return async sub ($event) {
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

            # Add subprotocol if specified
            if (my $subprotocol = $event->{subprotocol}) {
                push @headers, "Sec-WebSocket-Protocol: $subprotocol\r\n";
            }

            # Add custom headers if specified
            if (my $extra_headers = $event->{headers}) {
                for my $h (@$extra_headers) {
                    my ($name, $value) = @$h;
                    push @headers, "$name: $value\r\n";
                }
            }

            push @headers, "\r\n";

            $weak_self->{stream}->write(join('', @headers));

            # Switch to WebSocket mode
            $weak_self->{websocket_mode} = 1;
            $weak_self->{websocket_accepted} = 1;
            $weak_self->{websocket_frame} = Protocol::WebSocket::Frame->new;

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

            $weak_self->{stream}->write($frame->to_bytes);
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

sub _process_websocket_frames ($self) {
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

        if ($opcode == 1) {
            # Text frame - decode as UTF-8
            my $text = Encode::decode('UTF-8', $bytes);
            push @{$self->{receive_queue}}, {
                type => 'websocket.receive',
                text => $text,
            };
        }
        elsif ($opcode == 2) {
            # Binary frame - keep as raw bytes
            push @{$self->{receive_queue}}, {
                type  => 'websocket.receive',
                bytes => $bytes,
            };
        }
        elsif ($opcode == 8) {
            # Close frame
            $self->{close_received} = 1;
            my ($code, $reason) = (1005, '');

            if (length($bytes) >= 2) {
                $code = unpack('n', substr($bytes, 0, 2));
                $reason = substr($bytes, 2) // '';
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
