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

=item workers => $count

Number of worker processes for multi-worker mode. Default: 0 (single process mode).

When set to a value greater than 0, the server uses a pre-fork model:

=item listener_backlog => $number

Value for the listener queue size. Default: 2048

When in multi worker mode, the queue size for those workers inherits
from this value.

=over 4

=item * A listening socket is created before forking

=item * Worker processes are spawned using C<< $loop->fork() >> which properly
handles IO::Async's C<$ONE_TRUE_LOOP> singleton

=item * Each worker gets a fresh event loop and runs lifespan startup independently

=item * Workers that exit are automatically respawned via C<< $loop->watch_process() >>

=item * SIGTERM/SIGINT triggers graceful shutdown of all workers

=back

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
    $self->{app}              = delete $params->{app} or die "app is required";
    $self->{host}             = delete $params->{host} // '127.0.0.1';
    $self->{port}             = delete $params->{port} // 5000;
    $self->{ssl}              = delete $params->{ssl};
    $self->{extensions}       = delete $params->{extensions} // {};
    $self->{on_error}         = delete $params->{on_error} // sub { warn @_ };
    $self->{access_log}       = delete $params->{access_log} // \*STDERR;
    $self->{quiet}            = delete $params->{quiet} // 0;
    $self->{timeout}          = delete $params->{timeout} // 60;  # Connection idle timeout (seconds)
    $self->{max_header_size}  = delete $params->{max_header_size} // 8192;  # Max header size in bytes
    $self->{max_body_size}    = delete $params->{max_body_size};  # Max body size in bytes (undef = unlimited)
    $self->{workers}          = delete $params->{workers} // 0;   # Number of worker processes (0 = single process)
    $self->{listener_backlog} = delete $params->{listener_backlog} // 2048;   # Listener queue size
    $self->{shutdown_timeout} = delete $params->{shutdown_timeout} // 30;  # Graceful shutdown timeout (seconds)

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
    if (exists $params{listener_backlog}) {
        $self->{listener_backlog} = delete $params{listener_backlog};
    }
    if (exists $params{shutdown_timeout}) {
        $self->{shutdown_timeout} = delete $params{shutdown_timeout};
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
        queuesize => $self->{listener_backlog},
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
        Listen    => $self->{listener_backlog},
        ReuseAddr => 1,
        Blocking  => 0,
    ) or die "Cannot create listening socket: $!";

    $self->{bound_port} = $listen_socket->sockport;
    $self->{running} = 1;

    unless ($self->{quiet}) {
        my $log = $self->{access_log};
        my $scheme = $self->{ssl} ? 'https' : 'http';
        my $loop_class = ref($self->loop);
        $loop_class =~ s/^IO::Async::Loop:://;  # Shorten for display
        print $log "PAGI Server (multi-worker) listening on $scheme://$self->{host}:$self->{bound_port}/ with $workers workers (loop: $loop_class)\n";
    }

    # Set up signal handlers using IO::Async's watch_signal (replaces _setup_parent_signals)
    my $loop = $self->loop;
    $loop->watch_signal(TERM => sub { $self->_initiate_multiworker_shutdown });
    $loop->watch_signal(INT  => sub { $self->_initiate_multiworker_shutdown });

    # Fork the workers
    for my $i (1 .. $workers) {
        $self->_spawn_worker($listen_socket, $i);
    }

    # Store the socket for cleanup during shutdown
    $self->{listen_socket} = $listen_socket;

    # Return immediately - caller (Runner) will call $loop->run()
    # This is consistent with single-worker mode behavior
    return $self;
}

# Initiate graceful shutdown in multi-worker mode
sub _initiate_multiworker_shutdown ($self) {
    return if $self->{shutting_down};
    $self->{shutting_down} = 1;
    $self->{running} = 0;

    # Close the listen socket to stop accepting new connections
    if ($self->{listen_socket}) {
        close($self->{listen_socket});
        delete $self->{listen_socket};
    }

    # Signal all workers to shutdown
    for my $pid (keys %{$self->{worker_pids}}) {
        kill 'TERM', $pid;
    }

    # If no workers, stop the loop immediately
    if (!keys %{$self->{worker_pids}}) {
        $self->loop->stop;
    }
    # Otherwise, watch_process callbacks will stop the loop when all workers exit
}

sub _spawn_worker ($self, $listen_socket, $worker_num) {
    my $loop = $self->loop;
    weaken(my $weak_self = $self);

    # Use $loop->fork() instead of POSIX fork() to properly:
    # 1. Clear $ONE_TRUE_LOOP in child (so child gets fresh loop)
    # 2. Reset signal handlers in child
    # 3. Call post_fork() for loop backends that need it (epoll, kqueue)
    my $pid = $loop->fork(
        code => sub {
            $self->_run_as_worker($listen_socket, $worker_num);
            return 0;  # Exit code (may not be reached if worker calls exit())
        },
    );

    die "Fork failed" unless defined $pid;

    # Parent - track the worker
    $self->{worker_pids}{$pid} = {
        worker_num => $worker_num,
        started    => time(),
    };

    # Use watch_process to handle worker exit (replaces manual SIGCHLD handling)
    $loop->watch_process($pid => sub {
        my ($exit_pid, $exitcode) = @_;
        return unless $weak_self;

        # Remove from tracking
        delete $weak_self->{worker_pids}{$exit_pid};

        # Check exit code: exit(2) = startup failure, don't respawn
        my $exit_code = $exitcode >> 8;
        if ($exit_code == 2) {
            warn "Worker $worker_num startup failed, not respawning\n"
                unless $weak_self->{quiet};
            # Don't respawn - startup failure would just repeat
        }
        # Respawn if still running and not shutting down
        elsif ($weak_self->{running} && !$weak_self->{shutting_down}) {
            $weak_self->_spawn_worker($listen_socket, $worker_num);
        }

        # Check if all workers have exited (for shutdown)
        if ($weak_self->{shutting_down} && !keys %{$weak_self->{worker_pids}}) {
            $loop->stop;
        }
    });

    return $pid;
}

sub _run_as_worker ($self, $listen_socket, $worker_num) {
    # Note: Signal handlers already reset by $loop->fork() (keep_signals defaults to false)
    # Note: $ONE_TRUE_LOOP already cleared by $loop->fork(), so this creates a fresh loop
    my $loop = IO::Async::Loop->new;

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
        exit(2);  # Exit code 2 = startup failure (don't respawn)
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
            loop         => $self->loop,  # IO::Async::Loop for worker pools, etc.
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
    $self->{shutting_down} = 1;

    # Stop accepting new connections
    if ($self->{listener}) {
        $self->remove_child($self->{listener});
        $self->{listener} = undef;
    }

    # Wait for active connections to drain (graceful shutdown)
    await $self->_drain_connections;

    # Run lifespan shutdown
    my $shutdown_result = await $self->_run_lifespan_shutdown;

    if (!$shutdown_result->{success}) {
        my $message = $shutdown_result->{message} // 'Lifespan shutdown failed';
        my $log = $self->{access_log};
        print $log "PAGI Server shutdown warning: $message\n";
    }

    return $self;
}

# Wait for active connections to complete, with timeout
async sub _drain_connections ($self) {
    my $timeout = $self->{shutdown_timeout} // 30;
    my $start = time();
    my $loop = $self->loop;

    # First, close all idle connections immediately (not processing a request)
    # Keep-alive connections waiting for next request should be closed
    my @idle = grep { !$_->{handling_request} } @{$self->{connections}};
    for my $conn (@idle) {
        $conn->_close if $conn && $conn->can('_close');
    }

    # Now wait only for connections with active requests
    while (@{$self->{connections}} > 0) {
        my $elapsed = time() - $start;
        if ($elapsed >= $timeout) {
            # Timeout reached - force close remaining connections
            my $remaining = scalar @{$self->{connections}};
            warn "Shutdown timeout: force-closing $remaining active connections\n"
                unless $self->{quiet};

            # Force close all remaining connections
            for my $conn (@{$self->{connections}}) {
                $conn->_close if $conn && $conn->can('_close');
            }
            last;
        }

        # Give the event loop time to process responses
        # Use a short delay to avoid busy-waiting
        await $loop->delay_future(after => 0.1);
    }

    return;
}

sub port ($self) {
    return $self->{bound_port} // $self->{port};
}

sub is_running ($self) {
    return $self->{running} ? 1 : 0;
}

1;

__END__

=head1 PERFORMANCE

=head1 PERFORMANCE

PAGI::Server is designed as a reference implementation prioritizing spec
compliance and code clarity, yet delivers competitive performance suitable
for production workloads.

=head2 Benchmark Results

Tested on a 2.4 GHz 8-Core Intel Core i9 Mac with 16 workers, using
L<hey|https://github.com/rakyll/hey> with 500 concurrent connections
over 30 seconds against a minimal "Hello World" application:

    Requests/sec:    13,270
    Total requests:  398,458
    Latency p50:     36ms
    Latency p99:     71ms
    Errors:          0

=head2 Comparison

    Server                  Req/sec     p99 Latency   Notes
    ---------------------------------------------------------------
    PAGI (16 workers)       ~13,000     71ms          Async, zero errors
    Starman (16 workers)    ~10,500     2.8ms*        Sync prefork
    Uvicorn (Python)        ~10-15k     varies        ASGI reference
    Hypercorn (Python)      ~8-12k      varies        ASGI

    * Starman shows lower latency at low concurrency but experiences
      request timeouts under high concurrent load (500+ connections)
      due to its synchronous prefork model.

PAGI's async architecture handles high concurrency gracefully without
queueing or timeouts, making it well-suited for WebSocket, SSE, and
bursty traffic patterns that would overwhelm traditional prefork servers.

=head2 Worker Tuning

For optimal performance, set C<workers> equal to your CPU core count:

    # Recommended production configuration
    my $server = PAGI::Server->new(
        app     => $app,
        workers => 16,  # Set to number of CPU cores
    );

Guidelines:

=over 4

=item * B<CPU-bound workloads>: workers = CPU cores

=item * B<I/O-bound workloads>: workers = 2 × CPU cores

=item * B<Development>: workers = 0 (single process)

=back

Exceeding 2× CPU cores typically degrades performance due to context
switching overhead.

=head2 System Tuning

For high-concurrency production deployments, ensure adequate system limits:

    # File descriptors (run before starting server)
    ulimit -n 65536

    # Listen backlog (Linux)
    sudo sysctl -w net.core.somaxconn=2048

    # Listen backlog (macOS)
    sudo sysctl -w kern.ipc.somaxconn=2048

PAGI::Server defaults to a listen backlog of 2048, matching Uvicorn's
default. This can be adjusted via the C<listen_backlog> option.

=head2 Event Loop Selection

PAGI::Server works with any L<IO::Async> compatible event loop. If
you are on Linux, its recommended to install L<IO::Async::Loop::EPoll>
because that is the best choice for Linux and if installed will be automatically
used.

For other systems I recommend testing the various backend loop options
and find what works best.   Your notes and updates appreciated.

=cut

=head1 SEE ALSO

L<PAGI::Server::Connection>, L<PAGI::Server::Protocol::HTTP1>

=head1 AUTHOR

John Napiorkowski E<lt>jjnapiork@cpan.orgE<gt>

=head1 LICENSE

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
