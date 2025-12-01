package PAGI::Server;
use strict;
use warnings;
use experimental 'signatures';
use parent 'IO::Async::Notifier';
use IO::Async::Listener;
use IO::Async::Stream;
use IO::Async::SSL;
use Future;
use Future::AsyncAwait;
use Scalar::Util qw(weaken);

use PAGI::Server::Connection;
use PAGI::Server::Protocol::HTTP1;

our $VERSION = '0.001';

=head1 NAME

PAGI::Server - PAGI Reference Server Implementation

=head1 SYNOPSIS

    use IO::Async::Loop;
    use PAGI::Server;

    my $loop = IO::Async::Loop->new;

    my $server = PAGI::Server->new(
        app  => \&my_pagi_app,
        host => '127.0.0.1',
        port => 5000,
    );

    $loop->add($server);
    $server->listen->get;  # Start accepting connections

=head1 DESCRIPTION

PAGI::Server is a reference implementation of a PAGI-compliant HTTP server.
It supports HTTP/1.1, WebSocket, and Server-Sent Events (SSE) as defined
in the PAGI specification.

This is NOT a production server - it prioritizes spec compliance and code
clarity over performance optimization. It serves as the canonical reference
for how PAGI servers should behave.

=head1 CONSTRUCTOR

=head2 new

    my $server = PAGI::Server->new(%options);

Creates a new PAGI::Server instance. Options:

=over 4

=item app => \&coderef (required)

The PAGI application coderef with signature: async sub ($scope, $receive, $send)

=item host => $host

Bind address. Default: '127.0.0.1'

=item port => $port

Bind port. Default: 5000

=item ssl => \%config

Optional TLS configuration with keys: cert_file, key_file, ca_file, verify_client

=item extensions => \%extensions

Extensions to advertise (e.g., { fullflush => {} })

=item on_error => \&callback

Error callback receiving ($error)

=item access_log => $filehandle

Access log filehandle. Default: STDERR

=back

=head1 METHODS

=head2 listen

    my $future = $server->listen;

Starts listening for connections. Returns a Future that completes when
the server is ready to accept connections.

=head2 shutdown

    my $future = $server->shutdown;

Initiates graceful shutdown. Returns a Future that completes when
shutdown is complete.

=head2 port

    my $port = $server->port;

Returns the bound port number. Useful when port => 0 is used.

=head2 is_running

    my $bool = $server->is_running;

Returns true if the server is accepting connections.

=cut

sub _init ($self, $params) {
    $self->{app}        = delete $params->{app} or die "app is required";
    $self->{host}       = delete $params->{host} // '127.0.0.1';
    $self->{port}       = delete $params->{port} // 5000;
    $self->{ssl}        = delete $params->{ssl};
    $self->{extensions} = delete $params->{extensions} // {};
    $self->{on_error}   = delete $params->{on_error} // sub { warn @_ };
    $self->{access_log} = delete $params->{access_log} // \*STDERR;
    $self->{quiet}      = delete $params->{quiet} // 0;

    $self->{running}     = 0;
    $self->{bound_port}  = undef;
    $self->{listener}    = undef;
    $self->{connections} = [];
    $self->{protocol}    = PAGI::Server::Protocol::HTTP1->new;
    $self->{state}       = {};  # Shared state from lifespan

    $self->SUPER::_init($params);
}

sub configure ($self, %params) {
    if (exists $params{app}) {
        $self->{app} = delete $params{app};
    }
    if (exists $params{host}) {
        $self->{host} = delete $params{host};
    }
    if (exists $params{port}) {
        $self->{port} = delete $params{port};
    }
    if (exists $params{ssl}) {
        $self->{ssl} = delete $params{ssl};
    }
    if (exists $params{extensions}) {
        $self->{extensions} = delete $params{extensions};
    }
    if (exists $params{on_error}) {
        $self->{on_error} = delete $params{on_error};
    }
    if (exists $params{access_log}) {
        $self->{access_log} = delete $params{access_log};
    }
    if (exists $params{quiet}) {
        $self->{quiet} = delete $params{quiet};
    }

    $self->SUPER::configure(%params);
}

async sub listen ($self) {
    return if $self->{running};

    weaken(my $weak_self = $self);

    # Run lifespan startup before accepting connections
    my $startup_result = await $self->_run_lifespan_startup;

    if (!$startup_result->{success}) {
        my $message = $startup_result->{message} // 'Lifespan startup failed';
        my $log = $self->{access_log};
        print $log "PAGI Server startup failed: $message\n";
        die "Lifespan startup failed: $message\n";
    }

    my $listener = IO::Async::Listener->new(
        on_stream => sub ($listener, $stream) {
            return unless $weak_self;
            $weak_self->_on_connection($stream);
        },
    );

    $self->add_child($listener);
    $self->{listener} = $listener;

    # Build listener options
    my %listen_opts = (
        addr => {
            family   => 'inet',
            socktype => 'stream',
            ip       => $self->{host},
            port     => $self->{port},
        },
    );

    # Add SSL options if configured
    if (my $ssl = $self->{ssl}) {
        $listen_opts{extensions} = ['SSL'];
        $listen_opts{SSL_server} = 1;
        $listen_opts{SSL_cert_file} = $ssl->{cert_file} if $ssl->{cert_file};
        $listen_opts{SSL_key_file} = $ssl->{key_file} if $ssl->{key_file};

        # Client certificate verification
        if ($ssl->{verify_client}) {
            $listen_opts{SSL_verify_mode} = 0x01;  # SSL_VERIFY_PEER
            $listen_opts{SSL_ca_file} = $ssl->{ca_file} if $ssl->{ca_file};
        } else {
            $listen_opts{SSL_verify_mode} = 0x00;  # SSL_VERIFY_NONE
        }

        # Mark that TLS is enabled
        $self->{tls_enabled} = 1;

        # Auto-add tls extension when SSL is configured
        $self->{extensions}{tls} = {} unless exists $self->{extensions}{tls};
    }

    # Start listening
    my $listen_future = $listener->listen(%listen_opts);

    await $listen_future;

    # Store the actual bound port from the listener's read handle
    my $socket = $listener->read_handle;
    $self->{bound_port} = $socket->sockport if $socket && $socket->can('sockport');
    $self->{running} = 1;

    unless ($self->{quiet}) {
        my $log = $self->{access_log};
        my $scheme = $self->{tls_enabled} ? 'https' : 'http';
        print $log "PAGI Server listening on $scheme://$self->{host}:$self->{bound_port}/\n";
    }

    return $self;
}

sub _on_connection ($self, $stream) {
    weaken(my $weak_self = $self);

    my $conn = PAGI::Server::Connection->new(
        stream      => $stream,
        app         => $self->{app},
        protocol    => $self->{protocol},
        server      => $self,
        extensions  => $self->{extensions},
        state       => $self->{state},
        tls_enabled => $self->{tls_enabled} // 0,
    );

    # Track the connection
    push @{$self->{connections}}, $conn;

    # Configure stream with callbacks BEFORE adding to loop
    $conn->start;

    # Add stream to the loop so it can read/write
    $self->add_child($stream);
}

# Lifespan Protocol Implementation

async sub _run_lifespan_startup ($self) {
    # Create lifespan scope
    my $scope = {
        type => 'lifespan',
        pagi => {
            version      => '0.1',
            spec_version => '0.1',
        },
        state => $self->{state},  # App can populate this
    };

    # Create receive/send for lifespan protocol
    my @send_queue;
    my $receive_pending;
    my $startup_complete = Future->new;
    my $lifespan_supported = 1;  # Track if app supports lifespan

    # $receive for the app - returns events from the server
    my $receive = sub {
        if (@send_queue) {
            return Future->done(shift @send_queue);
        }
        $receive_pending = Future->new;
        return $receive_pending;
    };

    # $send for the app - handles app responses
    my $send = async sub ($event) {
        my $type = $event->{type} // '';

        if ($type eq 'lifespan.startup.complete') {
            $startup_complete->done({ success => 1 });
        }
        elsif ($type eq 'lifespan.startup.failed') {
            my $message = $event->{message} // '';
            $startup_complete->done({ success => 0, message => $message });
        }
        elsif ($type eq 'lifespan.shutdown.complete') {
            # Store for shutdown handling
            $self->{shutdown_complete} = 1;
            if ($self->{shutdown_pending}) {
                $self->{shutdown_pending}->done({ success => 1 });
            }
        }
        elsif ($type eq 'lifespan.shutdown.failed') {
            my $message = $event->{message} // '';
            $self->{shutdown_complete} = 1;
            if ($self->{shutdown_pending}) {
                $self->{shutdown_pending}->done({ success => 0, message => $message });
            }
        }

        return;
    };

    # Queue the startup event
    push @send_queue, { type => 'lifespan.startup' };
    if ($receive_pending && !$receive_pending->is_ready) {
        my $f = $receive_pending;
        $receive_pending = undef;
        $f->done(shift @send_queue);
    }

    # Store lifespan handlers for shutdown
    $self->{lifespan_receive} = $receive;
    $self->{lifespan_send} = $send;
    $self->{lifespan_send_queue} = \@send_queue;
    $self->{lifespan_receive_pending} = \$receive_pending;

    # Start the lifespan app handler
    # We run it in the background and wait for startup.complete
    my $app_future = (async sub {
        eval {
            await $self->{app}->($scope, $receive, $send);
        };
        if (my $error = $@) {
            # Per spec: if the app throws an exception for lifespan scope,
            # the server should continue without lifespan support
            $lifespan_supported = 0;
            if (!$startup_complete->is_ready) {
                # Check if it's an "unsupported scope type" error
                if ($error =~ /unsupported.*scope.*type|unsupported.*lifespan/i) {
                    # App doesn't support lifespan - that's OK, continue without it
                    $startup_complete->done({ success => 1, lifespan_supported => 0 });
                }
                else {
                    # Some other error - could be a real startup failure
                    warn "PAGI lifespan handler error: $error\n";
                    $startup_complete->done({ success => 0, message => "Exception: $error" });
                }
            }
        }
    })->();

    # Keep the app future so we can trigger shutdown later
    $self->{lifespan_app_future} = $app_future;
    $app_future->retain;

    # Wait for startup complete (with timeout)
    my $result = await $startup_complete;

    # Track if lifespan is supported
    $self->{lifespan_supported} = $result->{lifespan_supported} // 1;

    return $result;
}

async sub _run_lifespan_shutdown ($self) {
    # If lifespan is not supported or no lifespan was started, just return success
    return { success => 1 } unless $self->{lifespan_supported};
    return { success => 1 } unless $self->{lifespan_send_queue};

    $self->{shutdown_pending} = Future->new;

    # Queue the shutdown event
    my $send_queue = $self->{lifespan_send_queue};
    my $receive_pending_ref = $self->{lifespan_receive_pending};

    push @$send_queue, { type => 'lifespan.shutdown' };

    # Trigger pending receive if waiting
    if ($$receive_pending_ref && !$$receive_pending_ref->is_ready) {
        my $f = $$receive_pending_ref;
        $$receive_pending_ref = undef;
        $f->done(shift @$send_queue);
    }

    # Wait for shutdown complete
    my $result = await $self->{shutdown_pending};

    return $result;
}

async sub shutdown ($self) {
    return unless $self->{running};
    $self->{running} = 0;

    # Stop accepting new connections
    if ($self->{listener}) {
        $self->remove_child($self->{listener});
        $self->{listener} = undef;
    }

    # Run lifespan shutdown
    my $shutdown_result = await $self->_run_lifespan_shutdown;

    if (!$shutdown_result->{success}) {
        my $message = $shutdown_result->{message} // 'Lifespan shutdown failed';
        my $log = $self->{access_log};
        print $log "PAGI Server shutdown warning: $message\n";
    }

    return $self;
}

sub port ($self) {
    return $self->{bound_port} // $self->{port};
}

sub is_running ($self) {
    return $self->{running} ? 1 : 0;
}

1;

__END__

=head1 SEE ALSO

L<PAGI::Server::Connection>, L<PAGI::Server::Protocol::HTTP1>

=head1 AUTHOR

John Napiorkowski E<lt>jjnapiork@cpan.orgE<gt>

=head1 LICENSE

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
