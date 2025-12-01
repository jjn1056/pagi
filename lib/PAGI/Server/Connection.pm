package PAGI::Server::Connection;
use strict;
use warnings;
use experimental 'signatures';
use Future;
use Future::AsyncAwait;
use Scalar::Util qw(weaken);

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

    # Handle the request
    $self->{handling_request} = 1;
    $self->_handle_request($request);
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

    my $scope = {
        type         => 'http',
        pagi         => {
            version      => '0.1',
            spec_version => '0.1',
            features     => {},
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
    my $content_length = $request->{content_length} // 0;
    my $body_sent = 0;

    weaken(my $weak_self = $self);

    return async sub {
        return { type => 'http.disconnect' } unless $weak_self;
        return { type => 'http.disconnect' } if $weak_self->{closed};

        # Check queue first - events from disconnect handler
        if (@{$weak_self->{receive_queue}}) {
            return shift @{$weak_self->{receive_queue}};
        }

        # For requests without body, return empty body immediately (first call only)
        if (!$content_length && !$body_sent) {
            $body_sent = 1;
            return {
                type => 'http.request',
                body => '',
                more => 0,
            };
        }

        # Wait for body data from buffer (for POST/PUT with body)
        if (!$body_sent && length $weak_self->{buffer} > 0) {
            my $body = $weak_self->{buffer};
            $weak_self->{buffer} = '';
            $body_sent = 1;
            return {
                type => 'http.request',
                body => $body,
                more => 0,
            };
        }

        # No body data in buffer but not yet sent empty body
        if (!$body_sent) {
            $body_sent = 1;
            return {
                type => 'http.request',
                body => '',
                more => 0,
            };
        }

        # Body already sent - wait for disconnect event
        # Create a pending Future that will be completed when disconnect happens
        if (!$weak_self->{receive_pending}) {
            $weak_self->{receive_pending} = Future->new;
        }

        # Return disconnect if connection already closed
        if ($weak_self->{closed}) {
            my $f = $weak_self->{receive_pending};
            $weak_self->{receive_pending} = undef;
            return { type => 'http.disconnect' };
        }

        # Wait for the pending future to be completed
        return await $weak_self->{receive_pending};
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
    # Queue disconnect event (do this even if already closed)
    push @{$self->{receive_queue}}, { type => 'http.disconnect' };

    # Complete any pending receive
    if ($self->{receive_pending} && !$self->{receive_pending}->is_ready) {
        $self->{receive_pending}->done({ type => 'http.disconnect' });
        $self->{receive_pending} = undef;
    }
}

sub _close ($self) {
    return if $self->{closed};
    $self->{closed} = 1;

    # Complete any pending receive with disconnect
    $self->_handle_disconnect;

    if ($self->{stream}) {
        $self->{stream}->close_when_empty;
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
