package PAGI::App::WrapPSGI;
use strict;
use warnings;
use Future::AsyncAwait;

our $VERSION = '0.001';

=head1 NAME

PAGI::App::WrapPSGI - PSGI-to-PAGI adapter

=head1 SYNOPSIS

    use PAGI::App::WrapPSGI;

    my $psgi_app = sub {
        my ($env) = @_;
        return [200, ['Content-Type' => 'text/plain'], ['Hello']];
    };

    my $wrapper = PAGI::App::WrapPSGI->new(psgi_app => $psgi_app);
    my $pagi_app = $wrapper->to_app;

=head1 DESCRIPTION

PAGI::App::WrapPSGI wraps a PSGI application to make it work with
PAGI servers. It converts PAGI scope to PSGI %env and converts
PSGI responses to PAGI events.

=cut

sub new {
    my ($class, %args) = @_;

    my $self = bless {
        psgi_app => $args{psgi_app},
    }, $class;
    return $self;
}

sub to_app {
    my ($self) = @_;

    my $psgi_app = $self->{psgi_app};

    return async sub  {
        my ($scope, $receive, $send) = @_;
        die "Unsupported scope type: $scope->{type}" if $scope->{type} ne 'http';

        # TODO: Implement in Step 9
        # 1. Build PSGI %env from $scope
        # 2. Collect body from $receive into psgi.input
        # 3. Call $psgi_app->(\%env)
        # 4. Convert response to http.response.* events

        my $env = $self->_build_env($scope);

        # Collect request body
        my $body = '';
        while (1) {
            my $event = await $receive->();
            last if $event->{type} ne 'http.request';
            $body .= $event->{body} // '';
            last unless $event->{more};
        }

        # Create psgi.input
        open my $input, '<', \$body or die $!;
        $env->{'psgi.input'} = $input;

        # Call PSGI app
        my $response = $psgi_app->($env);

        # Handle response - could be arrayref or coderef (streaming)
        if (ref $response eq 'CODE') {
            # Delayed/streaming response
            await $self->_handle_streaming_response($send, $response);
        } else {
            await $self->_send_response($send, $response);
        }
    };
}

sub _build_env {
    my ($self, $scope) = @_;

    # TODO: Implement in Step 9
    my %env = (
        REQUEST_METHOD  => $scope->{method},
        SCRIPT_NAME     => $scope->{root_path},
        PATH_INFO       => $scope->{path},
        QUERY_STRING    => $scope->{query_string},
        SERVER_PROTOCOL => 'HTTP/' . $scope->{http_version},
        'psgi.version'    => [1, 1],
        'psgi.url_scheme' => $scope->{scheme},
        'psgi.errors'     => \*STDERR,
        'psgi.multithread'  => 0,
        'psgi.multiprocess' => 0,
        'psgi.run_once'     => 0,
        'psgi.streaming'    => 1,
        'psgi.nonblocking'  => 1,
    );

    # Add headers
    for my $header (@{$scope->{headers}}) {
        my ($name, $value) = @$header;
        my $key = uc($name);
        $key =~ s/-/_/g;
        if ($key eq 'CONTENT_TYPE') {
            $env{CONTENT_TYPE} = $value;
        } elsif ($key eq 'CONTENT_LENGTH') {
            $env{CONTENT_LENGTH} = $value;
        } else {
            $env{"HTTP_$key"} = $value;
        }
    }

    # Server/client info
    if ($scope->{server}) {
        $env{SERVER_NAME} = $scope->{server}[0];
        $env{SERVER_PORT} = $scope->{server}[1];
    }
    if ($scope->{client}) {
        $env{REMOTE_ADDR} = $scope->{client}[0];
        $env{REMOTE_PORT} = $scope->{client}[1];
    }

    return \%env;
}

async sub _send_response {
    my ($self, $send, $response) = @_;

    my ($status, $headers, $body) = @$response;

    await $send->({
        type    => 'http.response.start',
        status  => $status,
        headers => [ map { [lc($_->[0]), $_->[1]] } @{_pairs($headers)} ],
    });

    if (ref $body eq 'ARRAY') {
        my $content = join '', @$body;
        await $send->({
            type => 'http.response.body',
            body => $content,
            more => 0,
        });
    } elsif (ref $body eq 'CODE') {
        # Streaming response body (coderef)
        # This is the "pull" pattern where we call the coderef repeatedly
        while (1) {
            my $chunk = $body->();
            last unless defined $chunk;
            await $send->({
                type => 'http.response.body',
                body => $chunk,
                more => 1,
            });
        }
        await $send->({
            type => 'http.response.body',
            body => '',
            more => 0,
        });
    } else {
        # Filehandle
        local $/;
        my $content = <$body>;
        await $send->({
            type => 'http.response.body',
            body => $content // '',
            more => 0,
        });
    }
}

# Handle PSGI delayed/streaming response pattern
async sub _handle_streaming_response {
    my ($self, $send, $responder_callback) = @_;

    my @body_chunks;
    my $response_started = 0;
    my $writer;

    # Create a writer object for streaming
    my $create_writer = sub  {
        my ($send_ref, $status, $headers) = @_;
        return {
            write => sub {
                my ($chunk) = @_;
                push @body_chunks, $chunk;
            },
            close => sub {
                # Mark as closed - will be handled after responder returns
            },
        };
    };

    # Create the responder callback for the PSGI app
    my $responder = sub {
        my ($response) = @_;

        if (@$response == 3) {
            # Complete response [status, headers, body]
            my ($status, $headers, $body) = @$response;
            $response_started = 1;

            # Store for later sending
            push @body_chunks, { status => $status, headers => $headers, body => $body };
            return;
        } elsif (@$response == 2) {
            # Streaming response [status, headers] - return writer
            my ($status, $headers) = @$response;
            $response_started = 1;

            # Store header info
            push @body_chunks, { status => $status, headers => $headers };

            # Return a writer object
            $writer = bless {
                chunks => \@body_chunks,
            }, 'PAGI::App::WrapPSGI::Writer';

            return $writer;
        }
    };

    # Call the PSGI delayed response callback
    $responder_callback->($responder);

    # Now send all the collected response data
    if (@body_chunks) {
        my $first = shift @body_chunks;

        if (ref $first eq 'HASH') {
            my $status = $first->{status};
            my $headers = $first->{headers};
            my $body = $first->{body};

            await $send->({
                type    => 'http.response.start',
                status  => $status,
                headers => [ map { [lc($_->[0]), $_->[1]] } @{_pairs($headers)} ],
            });

            if (defined $body) {
                # Complete response with body
                await $self->_send_body($send, $body);
            } else {
                # Streaming - send collected chunks
                for my $chunk (@body_chunks) {
                    await $send->({
                        type => 'http.response.body',
                        body => $chunk,
                        more => 1,
                    });
                }
                await $send->({
                    type => 'http.response.body',
                    body => '',
                    more => 0,
                });
            }
        }
    }
}

async sub _send_body {
    my ($self, $send, $body) = @_;

    if (ref $body eq 'ARRAY') {
        my $content = join '', @$body;
        await $send->({
            type => 'http.response.body',
            body => $content,
            more => 0,
        });
    } elsif (ref $body eq 'GLOB' || (ref $body && $body->can('getline'))) {
        # Filehandle
        local $/;
        my $content = <$body>;
        await $send->({
            type => 'http.response.body',
            body => $content // '',
            more => 0,
        });
    } else {
        await $send->({
            type => 'http.response.body',
            body => $body // '',
            more => 0,
        });
    }
}

# Simple writer class for streaming responses
package PAGI::App::WrapPSGI::Writer;

sub write {
    my ($self, $chunk) = @_;
    push @{$self->{chunks}}, $chunk;
}

sub close {
    my ($self) = @_;
    # Nothing special needed - chunks are already collected
}

package PAGI::App::WrapPSGI;

sub _pairs {
    my ($arrayref) = @_;

    my @pairs;
    for (my $i = 0; $i < @$arrayref; $i += 2) {
        push @pairs, [$arrayref->[$i], $arrayref->[$i+1]];
    }
    return \@pairs;
}

1;

__END__

=head1 SEE ALSO

L<PAGI::Server>, L<PSGI>

=head1 AUTHOR

John Napiorkowski E<lt>jjnapiork@cpan.orgE<gt>

=head1 LICENSE

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
