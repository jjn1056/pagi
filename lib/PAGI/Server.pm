package PAGI::Server;
use strict;
use warnings;
use experimental 'signatures';
use parent 'IO::Async::Notifier';
use IO::Async::Listener;
use IO::Async::Stream;
use IO::Async::SSL;
use IO::Async::Loop;
use IO::Socket::INET;
use Future;
use Future::AsyncAwait;
use Scalar::Util qw(weaken);
use POSIX ':sys_wait_h';

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
    $self->{app}             = delete $params->{app} or die "app is required";
    $self->{host}            = delete $params->{host} // '127.0.0.1';
    $self->{port}            = delete $params->{port} // 5000;
    $self->{ssl}             = delete $params->{ssl};
    $self->{extensions}      = delete $params->{extensions} // {};
    $self->{on_error}        = delete $params->{on_error} // sub { warn @_ };
    $self->{access_log}      = delete $params->{access_log} // \*STDERR;
    $self->{quiet}           = delete $params->{quiet} // 0;
    $self->{timeout}         = delete $params->{timeout} // 60;  # Connection idle timeout (seconds)
    $self->{max_header_size} = delete $params->{max_header_size} // 8192;  # Max header size in bytes
    $self->{max_body_size}   = delete $params->{max_body_size};  # Max body size in bytes (undef = unlimited)
    $self->{workers}         = delete $params->{workers} // 0;   # Number of worker processes (0 = single process)

    $self->{running}     = 0;
    $self->{bound_port}  = undef;
    $self->{listener}    = undef;
    $self->{connections} = [];
    $self->{protocol}    = PAGI::Server::Protocol::HTTP1->new(
        max_header_size => $self->{max_header_size},
    );
    $self->{state}       = {};  # Shared state from lifespan
    $self->{worker_pids} = {};  # Track worker PIDs in multi-worker mode
    $self->{is_worker}   = 0;   # True if this is a worker process

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
    if (exists $params{timeout}) {
        $self->{timeout} = delete $params{timeout};
    }
    if (exists $params{max_header_size}) {
        $self->{max_header_size} = delete $params{max_header_size};
    }
    if (exists $params{max_body_size}) {
        $self->{max_body_size} = delete $params{max_body_size};
    }
    if (exists $params{workers}) {
        $self->{workers} = delete $params{workers};
    }

    $self->SUPER::configure(%params);
}

async sub listen ($self) {
    return if $self->{running};

    # Multi-worker mode uses a completely different code path
    if ($self->{workers} && $self->{workers} > 0) {
        return $self->_listen_multiworker;
    }

    return await $self->_listen_singleworker;
}

# Single-worker mode - uses IO::Async normally
async sub _listen_singleworker ($self) {
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

    # Set up signal handlers for graceful shutdown (single-worker mode)
    my $shutdown_triggered = 0;
    my $shutdown_handler = sub {
        return if $shutdown_triggered;
        $shutdown_triggered = 1;
        $self->shutdown->on_done(sub {
            $self->loop->stop;
        })->retain;
    };
    $self->loop->watch_signal(TERM => $shutdown_handler);
    $self->loop->watch_signal(INT => $shutdown_handler);

    unless ($self->{quiet}) {
        my $log = $self->{access_log};
        my $scheme = $self->{tls_enabled} ? 'https' : 'http';
        my $loop_class = ref($self->loop);
        $loop_class =~ s/^IO::Async::Loop:://;  # Shorten for display
        print $log "PAGI Server listening on $scheme://$self->{host}:$self->{bound_port}/ (loop: $loop_class)\n";
    }

    return $self;
}

# Multi-worker mode - forks workers, each with their own event loop
sub _listen_multiworker ($self) {
    my $workers = $self->{workers};

    # Create the listening socket BEFORE forking
    my $listen_socket = IO::Socket::INET->new(
        LocalAddr => $self->{host},
        LocalPort => $self->{port},
        Proto     => 'tcp',
        Listen    => 128,
        ReuseAddr => 1,
        Blocking  => 0,
    ) or die "Cannot create listening socket: $!";

    $self->{bound_port} = $listen_socket->sockport;
    $self->{running} = 1;

    # Capture the loop class so workers use the same type
    $self->{loop_class} = ref($self->loop);

    unless ($self->{quiet}) {
        my $log = $self->{access_log};
        my $scheme = $self->{ssl} ? 'https' : 'http';
        my $loop_class = $self->{loop_class};
        $loop_class =~ s/^IO::Async::Loop:://;  # Shorten for display
        print $log "PAGI Server (multi-worker) listening on $scheme://$self->{host}:$self->{bound_port}/ with $workers workers (loop: $loop_class)\n";
    }

    # Set up signal handlers in parent
    $self->_setup_parent_signals;

    # Fork the workers
    for my $i (1 .. $workers) {
        $self->_spawn_worker($listen_socket, $i);
    }

    # Store the socket for potential cleanup
    $self->{listen_socket} = $listen_socket;

    # Parent process enters monitoring loop
    $self->_parent_monitor_loop($listen_socket);

    return $self;
}

sub _spawn_worker ($self, $listen_socket, $worker_num) {
    my $pid = fork();
    die "Fork failed: $!" unless defined $pid;

    if ($pid == 0) {
        # Child process - become a worker
        $self->_run_as_worker($listen_socket, $worker_num);
        exit(0);  # Should not reach here
    }

    # Parent - track the worker
    $self->{worker_pids}{$pid} = {
        worker_num => $worker_num,
        started    => time(),
    };

    return $pid;
}

sub _run_as_worker ($self, $listen_socket, $worker_num) {
    # Reset signal handlers to default in worker
    $SIG{CHLD} = 'DEFAULT';
    $SIG{TERM} = 'DEFAULT';
    $SIG{INT}  = 'DEFAULT';

    # Create a fresh event loop for this worker, using the same loop class as parent
    my $loop_class = $self->{loop_class} || 'IO::Async::Loop';
    my $loop = $loop_class->new;

    # Create a fresh server instance for this worker (single-worker mode)
    my $worker_server = PAGI::Server->new(
        app             => $self->{app},
        host            => $self->{host},
        port            => $self->{port},
        ssl             => $self->{ssl},
        extensions      => $self->{extensions},
        on_error        => $self->{on_error},
        access_log      => $self->{access_log},
        quiet           => 1,  # Workers should be quiet
        timeout         => $self->{timeout},
        max_header_size => $self->{max_header_size},
        max_body_size   => $self->{max_body_size},
        workers         => 0,  # Single-worker mode in worker process
    );
    $worker_server->{is_worker} = 1;
    $worker_server->{bound_port} = $listen_socket->sockport;

    $loop->add($worker_server);

    # Set up graceful shutdown on SIGTERM using IO::Async's signal watching
    # (raw $SIG handlers don't work reliably when the loop is running)
    my $shutdown_triggered = 0;
    $loop->watch_signal(TERM => sub {
        return if $shutdown_triggered;
        $shutdown_triggered = 1;
        $worker_server->shutdown->on_done(sub {
            $loop->stop;
        })->retain;
    });

    # Run lifespan startup using a proper async wrapper
    my $startup_done = 0;
    my $startup_error;

    (async sub {
        eval {
            my $startup_result = await $worker_server->_run_lifespan_startup;
            if (!$startup_result->{success}) {
                $startup_error = $startup_result->{message} // 'Lifespan startup failed';
            }
        };
        if ($@) {
            $startup_error = $@;
        }
        $startup_done = 1;
        $loop->stop if $startup_error;  # Stop loop on error
    })->()->retain;

    # Run the loop briefly to let async startup complete
    $loop->loop_once while !$startup_done;

    if ($startup_error) {
        warn "Worker $worker_num ($$): startup failed: $startup_error\n" unless $self->{quiet};
        exit(1);
    }

    # Set up listener using the inherited socket
    weaken(my $weak_server = $worker_server);

    my $listener = IO::Async::Listener->new(
        handle => $listen_socket,
        on_stream => sub ($listener, $stream) {
            return unless $weak_server;
            $weak_server->_on_connection($stream);
        },
    );

    $worker_server->add_child($listener);
    $worker_server->{listener} = $listener;
    $worker_server->{running} = 1;

    # Run the event loop
    $loop->run;

    exit(0);
}

sub _setup_parent_signals ($self) {
    # Handle child exits
    $SIG{CHLD} = sub {
        # Reap all finished children
        while ((my $pid = waitpid(-1, WNOHANG)) > 0) {
            if (exists $self->{worker_pids}{$pid}) {
                my $info = delete $self->{worker_pids}{$pid};
                my $worker_num = $info->{worker_num};

                # If we're still running, restart the worker
                if ($self->{running} && !$self->{shutting_down}) {
                    $self->_spawn_worker($self->{listen_socket}, $worker_num);
                }
            }
        }
    };

    # Handle graceful shutdown
    $SIG{TERM} = sub {
        $self->{shutting_down} = 1;
        $self->{running} = 0;

        # Signal all workers to shutdown
        for my $pid (keys %{$self->{worker_pids}}) {
            kill 'TERM', $pid;
        }
    };

    $SIG{INT} = $SIG{TERM};
}

sub _parent_monitor_loop ($self, $listen_socket) {
    # Parent just waits for signals and manages workers
    # Use self-pipe trick for reliable signal handling across all platforms

    # Create a self-pipe for signal notification
    pipe(my $sig_read, my $sig_write) or die "pipe() failed: $!";

    # Set the write end to non-blocking so signal handler never blocks
    require Fcntl;
    my $flags = fcntl($sig_write, Fcntl::F_GETFL(), 0) or die "fcntl F_GETFL: $!";
    fcntl($sig_write, Fcntl::F_SETFL(), $flags | Fcntl::O_NONBLOCK()) or die "fcntl F_SETFL: $!";

    my $shutdown_handler = sub {
        $self->{shutting_down} = 1;
        $self->{running} = 0;
        # Signal all workers to shutdown
        for my $pid (keys %{$self->{worker_pids}}) {
            kill 'TERM', $pid;
        }
        # Write to self-pipe to wake up select() - ignore errors (pipe may be full)
        syswrite($sig_write, "X", 1);
    };

    # Install signal handlers
    local $SIG{INT}  = $shutdown_handler;
    local $SIG{TERM} = $shutdown_handler;
    local $SIG{CHLD} = sub {
        # Just write to wake up select() - we'll reap in the main loop
        syswrite($sig_write, "C", 1);
    };

    while (1) {
        # Check if we should exit
        last if $self->{shutting_down} && !keys %{$self->{worker_pids}};
        last if !$self->{running} && !keys %{$self->{worker_pids}};

        # Non-blocking check for exited children
        while ((my $pid = waitpid(-1, WNOHANG)) > 0) {
            if (exists $self->{worker_pids}{$pid}) {
                my $info = delete $self->{worker_pids}{$pid};
                my $worker_num = $info->{worker_num};

                # Restart worker if still running and not shutting down
                if ($self->{running} && !$self->{shutting_down}) {
                    $self->_spawn_worker($listen_socket, $worker_num);
                }
            }
        }

        # Check again after reaping
        last if $self->{shutting_down} && !keys %{$self->{worker_pids}};

        # Wait on self-pipe with timeout - wakes on signal or timeout
        my $rin = '';
        vec($rin, fileno($sig_read), 1) = 1;
        my $nfound = select($rin, undef, undef, 0.5);

        # Drain the self-pipe if there's data
        if ($nfound > 0) {
            my $buf;
            while (sysread($sig_read, $buf, 256)) { }
        }
    }

    # Close self-pipe
    close($sig_read);
    close($sig_write);

    # Close listening socket
    close($listen_socket);

    # In multi-worker mode, the parent should exit after shutdown
    # (otherwise control returns to the caller who would try to run the event loop)
    exit(0);
}

sub _on_connection ($self, $stream) {
    weaken(my $weak_self = $self);

    my $conn = PAGI::Server::Connection->new(
        stream        => $stream,
        app           => $self->{app},
        protocol      => $self->{protocol},
        server        => $self,
        extensions    => $self->{extensions},
        state         => $self->{state},
        tls_enabled   => $self->{tls_enabled} // 0,
        timeout       => $self->{timeout},
        max_body_size => $self->{max_body_size},
        access_log    => $self->{access_log},
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
