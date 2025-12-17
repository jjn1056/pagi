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
use Scalar::Util qw(weaken refaddr);

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

=item access_log => $filehandle | undef

Access log filehandle. Default: STDERR

Set to C<undef> to disable access logging entirely. This eliminates
per-request I/O overhead, improving throughput by 5-15% depending on
workload. Useful for benchmarking or when access logs are handled
externally (e.g., by a reverse proxy).

    # Disable access logging
    my $server = PAGI::Server->new(
        app        => $app,
        access_log => undef,
    );

=item log_level => $level

Controls the verbosity of server log messages. Default: 'info'

Valid levels (from least to most verbose):

=over 4

=item * B<error> - Only errors (application errors, fatal conditions)

=item * B<warn> - Warnings and errors (connection issues, timeouts)

=item * B<info> - Informational messages and above (startup, shutdown, worker spawning)

=item * B<debug> - Everything (verbose diagnostics, frame-level details)

=back

    my $server = PAGI::Server->new(
        app       => $app,
        log_level => 'debug',  # Very verbose
    );

B<CLI:> C<--log-level debug>

=item workers => $count

Number of worker processes for multi-worker mode. Default: 0 (single process mode).

When set to a value greater than 0, the server uses a pre-fork model:

=item listener_backlog => $number

Value for the listener queue size. Default: 2048

When in multi worker mode, the queue size for those workers inherits
from this value.

=item reuseport => $bool

Enable SO_REUSEPORT mode for multi-worker servers. Default: 0 (disabled).

When enabled, each worker process creates its own listening socket with
SO_REUSEPORT, allowing the kernel to load-balance incoming connections
across workers. This can reduce accept() contention and improve p99
latency under high concurrency.

B<Traditional mode (reuseport=0):> Parent creates one socket before forking,
all workers inherit and share that socket. Workers compete on a single
accept queue (potential thundering herd).

B<Reuseport mode (reuseport=1):> Each worker creates its own socket with
SO_REUSEPORT. The kernel distributes connections across sockets, each
worker has its own accept queue (reduced contention).

B<Platform notes:>

=over 4

=item * B<Linux 3.9+>: Full kernel-level load balancing. Recommended for high
concurrency workloads.

=item * B<macOS/BSD>: SO_REUSEPORT allows multiple binds but does NOT provide
kernel load balancing. May actually decrease performance compared to shared
socket mode. Use with caution - benchmark before deploying.

=back

=item max_receive_queue => $count

Maximum number of messages that can be queued in the WebSocket receive queue
before the connection is closed. This is a DoS protection mechanism.

B<Unit:> Message count (not bytes). Each WebSocket text or binary frame counts
as one message regardless of size.

B<Default:> 1000 messages

B<When exceeded:> The server sends a WebSocket close frame with code 1008
(Policy Violation) and reason "Message queue overflow", then closes the
connection.

B<Tuning guidelines:>

=over 4

=item * B<Memory impact:> Each queued message holds the full message payload.
With default of 1000 messages and average 1KB messages, worst case is ~1MB
per slow connection.

=item * B<Workers:> Total memory risk = workers × max_connections × max_receive_queue × avg_message_size.
For 4 workers, 100 connections each, 1000 queue, 1KB average = 400MB worst case.

=item * B<Fast consumers:> If your app processes messages quickly, the queue
rarely grows. Default of 1000 is generous for most applications.

=item * B<Slow consumers:> If your app does expensive processing per message,
consider lowering to 100-500 to limit memory exposure.

=item * B<High throughput:> If you have trusted clients sending rapid bursts,
you may increase to 5000-10000, but monitor memory usage.

=back

B<CLI:> C<--max-receive-queue 500>

=item max_ws_frame_size => $bytes

Maximum size in bytes for a single WebSocket frame payload. When a client
sends a frame larger than this limit, the connection is closed with a
protocol error.

B<Unit:> Bytes

B<Default:> 65536 (64KB) - matches Protocol::WebSocket default

B<When exceeded:> The server closes the connection. The error is logged as
"PAGI connection error: Payload is too big."

B<Tuning guidelines:>

=over 4

=item * B<Small messages:> For chat apps or control messages, default 64KB is plenty.

=item * B<File uploads:> For binary data transfer via WebSocket, increase to 1MB-16MB
depending on expected file sizes.

=item * B<Memory impact:> Each connection can buffer up to max_ws_frame_size bytes
during frame parsing. High values increase memory per connection.

=item * B<DoS protection:> Lower values limit memory exhaustion from malicious clients
sending oversized frames.

=back

B<CLI:> C<--max-ws-frame-size 1048576>

=over 4

=item * A listening socket is created before forking

=item * Worker processes are spawned using C<< $loop->fork() >> which properly
handles IO::Async's C<$ONE_TRUE_LOOP> singleton

=item * Each worker gets a fresh event loop and runs lifespan startup independently

=item * Workers that exit are automatically respawned via C<< $loop->watch_process() >>

=item * SIGTERM/SIGINT triggers graceful shutdown of all workers

=back

=item max_requests => $count

Maximum number of requests a worker process will handle before restarting.
After serving this many requests, the worker gracefully shuts down and the
parent spawns a replacement.

B<Default:> 0 (disabled - workers run indefinitely)

B<When to use:>

=over 4

=item * Long-running deployments where gradual memory growth is a concern

=item * Applications with known memory leaks that can't be easily fixed

=item * Defense against slow memory growth (~6.5 bytes/request observed in PAGI)

=back

B<Note:> Only applies in multi-worker mode (C<workers> > 0). In single-worker
mode, this setting is ignored.

B<CLI:> C<--max-requests 10000>

Example: With 4 workers and max_requests=10000, total capacity before any
restart is 40,000 requests. Workers restart individually without downtime.

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

    # Validate SSL certificate files at startup (fail fast)
    if (my $ssl = $self->{ssl}) {
        if (my $cert = $ssl->{cert_file}) {
            die "SSL certificate file not found: $cert\n" unless -e $cert;
            die "SSL certificate file not readable: $cert\n" unless -r $cert;
        }
        if (my $key = $ssl->{key_file}) {
            die "SSL key file not found: $key\n" unless -e $key;
            die "SSL key file not readable: $key\n" unless -r $key;
        }
        if (my $ca = $ssl->{ca_file}) {
            die "SSL CA file not found: $ca\n" unless -e $ca;
            die "SSL CA file not readable: $ca\n" unless -r $ca;
        }
    }

    $self->{extensions}       = delete $params->{extensions} // {};
    $self->{on_error}         = delete $params->{on_error} // sub { warn @_ };
    $self->{access_log}       = exists $params->{access_log} ? delete $params->{access_log} : \*STDERR;
    $self->{quiet}            = delete $params->{quiet} // 0;
    $self->{log_level}        = delete $params->{log_level} // 'info';
    # Validate log level
    my %valid_levels = (debug => 1, info => 2, warn => 3, error => 4);
    die "Invalid log_level '$self->{log_level}' - must be one of: debug, info, warn, error\n"
        unless $valid_levels{$self->{log_level}};
    $self->{_log_level_num}   = $valid_levels{$self->{log_level}};
    $self->{timeout}          = delete $params->{timeout} // 60;  # Connection idle timeout (seconds)
    $self->{max_header_size}  = delete $params->{max_header_size} // 8192;  # Max header size in bytes
    $self->{max_header_count} = delete $params->{max_header_count} // 100;  # Max number of headers
    $self->{max_body_size}    = delete $params->{max_body_size};  # Max body size in bytes (undef = unlimited)
    $self->{workers}          = delete $params->{workers} // 0;   # Number of worker processes (0 = single process)
    $self->{max_requests}     = delete $params->{max_requests} // 0;  # 0 = unlimited
    $self->{listener_backlog} = delete $params->{listener_backlog} // 2048;   # Listener queue size
    $self->{shutdown_timeout}  = delete $params->{shutdown_timeout} // 30;  # Graceful shutdown timeout (seconds)
    $self->{reuseport}         = delete $params->{reuseport} // 0;  # SO_REUSEPORT mode for multi-worker
    $self->{max_receive_queue} = delete $params->{max_receive_queue} // 1000;  # Max WebSocket receive queue size (messages)
    $self->{max_ws_frame_size} = delete $params->{max_ws_frame_size} // 65536;  # Max WebSocket frame size in bytes (64KB default)

    $self->{running}     = 0;
    $self->{bound_port}  = undef;
    $self->{listener}    = undef;
    $self->{connections} = {};  # Hash keyed by refaddr for O(1) add/remove
    $self->{protocol}    = PAGI::Server::Protocol::HTTP1->new(
        max_header_size  => $self->{max_header_size},
        max_header_count => $self->{max_header_count},
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
    if (exists $params{log_level}) {
        my $level = delete $params{log_level};
        my %valid_levels = (debug => 1, info => 2, warn => 3, error => 4);
        die "Invalid log_level '$level' - must be one of: debug, info, warn, error\n"
            unless $valid_levels{$level};
        $self->{log_level} = $level;
        $self->{_log_level_num} = $valid_levels{$level};
    }
    if (exists $params{timeout}) {
        $self->{timeout} = delete $params{timeout};
    }
    if (exists $params{max_header_size}) {
        $self->{max_header_size} = delete $params{max_header_size};
    }
    if (exists $params{max_header_count}) {
        $self->{max_header_count} = delete $params{max_header_count};
    }
    if (exists $params{max_body_size}) {
        $self->{max_body_size} = delete $params{max_body_size};
    }
    if (exists $params{workers}) {
        $self->{workers} = delete $params{workers};
    }
    if (exists $params{max_requests}) {
        $self->{max_requests} = delete $params{max_requests};
    }
    if (exists $params{listener_backlog}) {
        $self->{listener_backlog} = delete $params{listener_backlog};
    }
    if (exists $params{shutdown_timeout}) {
        $self->{shutdown_timeout} = delete $params{shutdown_timeout};
    }
    if (exists $params{max_receive_queue}) {
        $self->{max_receive_queue} = delete $params{max_receive_queue};
    }
    if (exists $params{max_ws_frame_size}) {
        $self->{max_ws_frame_size} = delete $params{max_ws_frame_size};
    }

    $self->SUPER::configure(%params);
}

# Log levels: debug=1, info=2, warn=3, error=4
my %_LOG_LEVELS = (debug => 1, info => 2, warn => 3, error => 4);

sub _log ($self, $level, $msg) {
    my $level_num = $_LOG_LEVELS{$level} // 2;
    return if $level_num < $self->{_log_level_num};
    return if $self->{quiet} && $level ne 'error';
    warn "$msg\n";
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
        $self->_log(error => "PAGI Server startup failed: $message");
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

        # TLS hardening: minimum version TLS 1.2 (configurable)
        $listen_opts{SSL_version} = $ssl->{min_version} // 'TLSv1_2';

        # TLS hardening: secure cipher suites (configurable)
        $listen_opts{SSL_cipher_list} = $ssl->{cipher_list} //
            'ECDHE+AESGCM:DHE+AESGCM:ECDHE+CHACHA20:!aNULL:!eNULL:!EXPORT:!DES:!RC4:!MD5:!PSK:!aECDH:!EDH-DSS-DES-CBC3-SHA:!KRB5-DES-CBC3-SHA';

        # Client certificate verification
        if ($ssl->{verify_client}) {
            # SSL_VERIFY_PEER (0x01) | SSL_VERIFY_FAIL_IF_NO_PEER_CERT (0x02)
            $listen_opts{SSL_verify_mode} = 0x03;
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

    my $scheme = $self->{tls_enabled} ? 'https' : 'http';
    my $loop_class = ref($self->loop);
    $loop_class =~ s/^IO::Async::Loop:://;  # Shorten for display
    $self->_log(info => "PAGI Server listening on $scheme://$self->{host}:$self->{bound_port}/ (loop: $loop_class)");

    return $self;
}

# Multi-worker mode - forks workers, each with their own event loop
sub _listen_multiworker ($self) {
    my $workers = $self->{workers};
    my $reuseport = $self->{reuseport};

    my $listen_socket;

    if ($reuseport) {
        # SO_REUSEPORT mode: each worker creates its own socket
        # Parent just needs to know the port for display purposes
        # We do a quick bind to validate port availability and get actual port if 0
        my $probe_socket = IO::Socket::INET->new(
            LocalAddr => $self->{host},
            LocalPort => $self->{port},
            Proto     => 'tcp',
            Listen    => 1,
            ReuseAddr => 1,
            ReusePort => 1,
        ) or die "Cannot bind to $self->{host}:$self->{port}: $!";
        $self->{bound_port} = $probe_socket->sockport;
        close($probe_socket);  # Workers will create their own sockets
    }
    else {
        # Traditional mode: parent creates socket, workers inherit it
        $listen_socket = IO::Socket::INET->new(
            LocalAddr => $self->{host},
            LocalPort => $self->{port},
            Proto     => 'tcp',
            Listen    => $self->{listener_backlog},
            ReuseAddr => 1,
            Blocking  => 0,
        ) or die "Cannot create listening socket: $!";
        $self->{bound_port} = $listen_socket->sockport;
    }

    $self->{running} = 1;

    my $scheme = $self->{ssl} ? 'https' : 'http';
    my $loop_class = ref($self->loop);
    $loop_class =~ s/^IO::Async::Loop:://;  # Shorten for display
    my $mode = $reuseport ? 'reuseport' : 'shared-socket';
    $self->_log(info => "PAGI Server (multi-worker, $mode) listening on $scheme://$self->{host}:$self->{bound_port}/ with $workers workers (loop: $loop_class)");

    # Set up signal handlers using IO::Async's watch_signal (replaces _setup_parent_signals)
    my $loop = $self->loop;
    $loop->watch_signal(TERM => sub { $self->_initiate_multiworker_shutdown });
    $loop->watch_signal(INT  => sub { $self->_initiate_multiworker_shutdown });
    # HUP = graceful restart (replace all workers)
    $loop->watch_signal(HUP => sub { $self->_graceful_restart });

    # Fork the workers
    for my $i (1 .. $workers) {
        $self->_spawn_worker($listen_socket, $i);
    }

    # Store the socket for cleanup during shutdown (only in traditional mode)
    $self->{listen_socket} = $listen_socket if $listen_socket;

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

# Graceful restart: replace all workers one by one
sub _graceful_restart ($self) {
    return if $self->{shutting_down};

    $self->_log(info => "Received HUP, performing graceful restart");

    # Signal all current workers to shutdown
    # watch_process callbacks will respawn them
    for my $pid (keys %{$self->{worker_pids}}) {
        kill 'TERM', $pid;
    }
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
            $weak_self->_log(warn => "Worker $worker_num startup failed, not respawning");
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

    # In reuseport mode, each worker creates its own listening socket
    my $reuseport = $self->{reuseport};
    if ($reuseport && !$listen_socket) {
        $listen_socket = IO::Socket::INET->new(
            LocalAddr => $self->{host},
            LocalPort => $self->{bound_port},  # Use the port determined by parent
            Proto     => 'tcp',
            Listen    => $self->{listener_backlog},
            ReuseAddr => 1,
            ReusePort => 1,
            Blocking  => 0,
        ) or die "Worker $worker_num: Cannot create listening socket: $!";
    }

    # Create a fresh server instance for this worker (single-worker mode)
    my $worker_server = PAGI::Server->new(
        app             => $self->{app},
        host            => $self->{host},
        port            => $self->{port},
        ssl             => $self->{ssl},
        extensions      => $self->{extensions},
        on_error        => $self->{on_error},
        access_log      => $self->{access_log},
        log_level       => $self->{log_level},
        quiet           => 1,  # Workers should be quiet
        timeout         => $self->{timeout},
        max_header_size  => $self->{max_header_size},
        max_header_count => $self->{max_header_count},
        max_body_size    => $self->{max_body_size},
        max_requests     => $self->{max_requests},
        workers          => 0,  # Single-worker mode in worker process
    );
    $worker_server->{is_worker} = 1;
    $worker_server->{worker_num} = $worker_num;  # Store for lifespan scope
    $worker_server->{_request_count} = 0;  # Track requests handled
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
        $self->_log(error => "Worker $worker_num ($$): startup failed: $startup_error");
        close($listen_socket) if $listen_socket;  # Clean up FD before exit
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

    # Clean up listen socket before exit (avoid FD leak)
    close($listen_socket) if $listen_socket;
    exit(0);
}

sub _on_connection ($self, $stream) {
    weaken(my $weak_self = $self);

    my $conn = PAGI::Server::Connection->new(
        stream            => $stream,
        app               => $self->{app},
        protocol          => $self->{protocol},
        server            => $self,
        extensions        => $self->{extensions},
        state             => $self->{state},
        tls_enabled       => $self->{tls_enabled} // 0,
        timeout           => $self->{timeout},
        max_body_size     => $self->{max_body_size},
        access_log        => $self->{access_log},
        max_receive_queue => $self->{max_receive_queue},
        max_ws_frame_size => $self->{max_ws_frame_size},
    );

    # Track the connection (O(1) hash insert)
    $self->{connections}{refaddr($conn)} = $conn;

    # Configure stream with callbacks BEFORE adding to loop
    $conn->start;

    # Add stream to the loop so it can read/write
    $self->add_child($stream);
}

# Called when a request completes (for max_requests tracking)
sub _on_request_complete ($self) {
    return unless $self->{is_worker};
    return unless $self->{max_requests} && $self->{max_requests} > 0;

    $self->{_request_count}++;

    if ($self->{_request_count} >= $self->{max_requests}) {
        return if $self->{_max_requests_shutdown_triggered};  # Prevent duplicate shutdowns
        $self->{_max_requests_shutdown_triggered} = 1;
        $self->_log(info => "Worker $$: reached max_requests ($self->{max_requests}), shutting down");
        # Initiate graceful shutdown (finish current connections, then exit)
        $self->shutdown->on_done(sub {
            $self->loop->stop;
        })->retain;
    }
}

# Lifespan Protocol Implementation

async sub _run_lifespan_startup ($self) {
    # Create lifespan scope
    my $scope = {
        type => 'lifespan',
        pagi => {
            version      => '0.1',
            spec_version => '0.1',
            is_worker    => $self->{is_worker} // 0,
            worker_num   => $self->{worker_num},  # undef for single-worker, 1-N for multi-worker
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
                    $self->_log(error => "PAGI lifespan handler error: $error");
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

    $self->{shutdown_pending} = $self->loop->new_future;

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

    # Wait for shutdown complete (with timeout to prevent hanging)
    my $timeout = $self->{shutdown_timeout} // 30;
    my $timeout_f = $self->loop->delay_future(after => $timeout);

    my $result = await Future->wait_any($self->{shutdown_pending}, $timeout_f);

    # If timeout won, return failure
    if ($timeout_f->is_ready && !$self->{shutdown_pending}->is_ready) {
        return { success => 0, message => "Lifespan shutdown timed out after ${timeout}s" };
    }

    return $result // { success => 1 };
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
        $self->_log(warn => "PAGI Server shutdown warning: $message");
    }

    return $self;
}

# Wait for active connections to complete, with timeout
# Uses event-driven approach: Connection._close() signals when last one closes
async sub _drain_connections ($self) {
    my $timeout = $self->{shutdown_timeout} // 30;
    my $loop = $self->loop;

    # First, close all idle connections immediately (not processing a request)
    # Keep-alive connections waiting for next request should be closed
    my @idle = grep { !$_->{handling_request} } values %{$self->{connections}};
    for my $conn (@idle) {
        $conn->_close if $conn && $conn->can('_close');
    }

    # Also close long-lived connections (SSE, WebSocket) immediately
    # These never become "idle" so would wait for full timeout otherwise
    my @longlived = grep { $_->{sse_mode} || $_->{websocket_mode} } values %{$self->{connections}};
    for my $conn (@longlived) {
        $conn->_close if $conn && $conn->can('_close');
    }

    # If all connections are now closed, we're done
    return if keys %{$self->{connections}} == 0;

    # Create a Future that Connection._close() will resolve when last one closes
    $self->{drain_complete} = $loop->new_future;

    # Wait for either: all connections close OR timeout
    my $timeout_f = $loop->delay_future(after => $timeout);

    await Future->wait_any($self->{drain_complete}, $timeout_f);

    # Brief pause to let any final socket writes flush
    # (stream->write is async; data may still be in kernel buffer)
    await $loop->delay_future(after => 0.05) if keys %{$self->{connections}} == 0;

    # If timeout won (connections still remain), force close them
    if (keys %{$self->{connections}} > 0) {
        my $remaining = scalar keys %{$self->{connections}};
        $self->_log(warn => "Shutdown timeout: force-closing $remaining active connections");

        for my $conn (values %{$self->{connections}}) {
            $conn->_close if $conn && $conn->can('_close');
        }
    }

    delete $self->{drain_complete};
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

PAGI::Server is designed as a reference implementation prioritizing spec
compliance and code clarity, yet delivers competitive performance suitable
for production workloads.

=head2 Benchmark Results

Tested on a 2.4 GHz 8-Core Intel Core i9 Mac with 8 workers, using
L<hey|https://github.com/rakyll/hey> against a PAGI::Simple hello world
application:

B<Peak Performance (100 concurrent, 10 seconds):>

    Endpoint        Req/sec     p50      p99      Response
    ----------------------------------------------------------------
    / (text)        12,455      7.7ms    13.2ms   13 bytes
    /html           10,932      8.4ms    19.3ms   143 bytes
    /json           9,806       8.8ms    28.2ms   50 bytes
    /greet/:name    10,722      8.9ms    15.4ms   17 bytes (path params)

B<Concurrency Scaling:>

    Concurrent    Req/sec     p50       p99
    -----------------------------------------
    10            9,757       0.9ms     2.1ms
    100           12,100      7.8ms     14.1ms
    500           11,299      43.3ms    63.7ms

B<Sustained Load (30 seconds, 200 concurrent):>

    Requests/sec:    9,934
    Total requests:  298,171
    Latency p99:     39.5ms
    Errors:          0

=head2 Comparison

    Server                  Req/sec     p99 Latency   Notes
    ---------------------------------------------------------------
    PAGI (8 workers)        10-12k      13-40ms       Async, zero errors
    Uvicorn (Python)        10-15k      varies        ASGI reference
    Hypercorn (Python)      8-12k       varies        ASGI
    Starman (Perl)          8-10k       2-3ms*        Sync prefork

    * Starman shows lower latency at low concurrency but experiences
      request timeouts under high concurrent load (500+ connections)
      due to its synchronous prefork model.

=head2 Key Findings

=over 4

=item * B<Keep-alive is essential> - Without it, throughput drops 6x and
port exhaustion errors occur under load.

=item * B<Zero errors under sustained load> - 298k requests over 30 seconds
with no failures when using keep-alive connections.

=item * B<Consistent tail latency> - p99 is typically only 2x p50, indicating
predictable performance without major outliers.

=item * B<JSON overhead> - JSON serialization adds ~20% overhead vs plain text.

=back

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

=head1 RECOMMENDED MIDDLEWARE

For production deployments, consider enabling these middleware components:

=head2 SecurityHeaders

Adds important security headers to all responses. Addresses common security
scanner findings (e.g., nikto, OWASP ZAP).

    use PAGI::Middleware::Builder;

    my $app = builder {
        enable 'SecurityHeaders',
            x_frame_options           => 'DENY',           # Clickjacking protection
            x_content_type_options    => 'nosniff',        # MIME sniffing protection
            content_security_policy   => "default-src 'self'",  # XSS protection
            strict_transport_security => 'max-age=31536000';    # HSTS (HTTPS only)
        $my_app;
    };

Default headers (enabled automatically):

=over 4

=item * X-Frame-Options: SAMEORIGIN

=item * X-Content-Type-Options: nosniff

=item * X-XSS-Protection: 1; mode=block

=item * Referrer-Policy: strict-origin-when-cross-origin

=back

See L<PAGI::Middleware::SecurityHeaders> for full documentation.

=head2 Other Recommended Middleware

=over 4

=item * L<PAGI::Middleware::ContentLength> - Ensures Content-Length header

=item * L<PAGI::Middleware::AccessLog> - Request logging (if not using server's built-in)

=item * L<PAGI::Middleware::RateLimit> - Protection against abuse

=item * L<PAGI::Middleware::CORS> - Cross-origin resource sharing

=item * L<PAGI::Middleware::GZip> - Response compression

=back

=head1 SEE ALSO

L<PAGI::Server::Connection>, L<PAGI::Server::Protocol::HTTP1>

=head1 AUTHOR

John Napiorkowski E<lt>jjnapiork@cpan.orgE<gt>

=head1 LICENSE

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
