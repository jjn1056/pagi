package PAGI::Server;
use strict;
use warnings;

our $VERSION = '0.001011';

# Future::XS support - opt-in via PAGI_FUTURE_XS=1 environment variable
# Must be loaded before Future to take effect, so we check env var in BEGIN
# Note: We declare these without initialization so BEGIN block values persist
our ($FUTURE_XS_AVAILABLE, $FUTURE_XS_ENABLED);
BEGIN {
    $FUTURE_XS_AVAILABLE = eval { require Future::XS; 1 } ? 1 : 0;
    $FUTURE_XS_ENABLED = 0;  # Default to disabled

    if ($ENV{PAGI_FUTURE_XS}) {
        if ($FUTURE_XS_AVAILABLE) {
            # Future::XS is already loaded from the availability check
            $FUTURE_XS_ENABLED = 1;
        } else {
            die <<"END_FUTURE_XS_ERROR";
PAGI_FUTURE_XS=1 set but Future::XS is not installed.

To install Future::XS:
    cpanm Future::XS

Or unset the PAGI_FUTURE_XS environment variable.
END_FUTURE_XS_ERROR
        }
    } elsif ($FUTURE_XS_AVAILABLE) {
        # Available but not requested - unload it
        delete $INC{'Future/XS.pm'};
    }
}

use parent 'IO::Async::Notifier';
use IO::Async::Listener;
use IO::Async::Stream;
use IO::Async::Loop;
use IO::Async::Timer::Periodic;
use IO::Socket::INET;
use Future;
use Future::AsyncAwait;

use Scalar::Util qw(weaken refaddr);
use POSIX ();

use PAGI::Server::Connection;
use PAGI::Server::Protocol::HTTP1;


# Check TLS module availability (cached at load time for banner display)
our $TLS_AVAILABLE;
BEGIN {
    $TLS_AVAILABLE = eval {
        require IO::Async::SSL;
        require IO::Socket::SSL;
        1;
    } ? 1 : 0;
}

sub has_tls { return $TLS_AVAILABLE }

# Check HTTP/2 module availability (cached at load time)
our $HTTP2_AVAILABLE;
BEGIN {
    $HTTP2_AVAILABLE = eval {
        require PAGI::Server::Protocol::HTTP2;
        PAGI::Server::Protocol::HTTP2->available;
    } ? 1 : 0;
}

sub has_http2 { return $HTTP2_AVAILABLE }

# Windows doesn't support Unix signals - signal handling is conditional
use constant WIN32 => $^O eq 'MSWin32';

=encoding utf8

=head1 NAME

PAGI::Server - PAGI Reference Server Implementation

=head1 SYNOPSIS

    use IO::Async::Loop;
    use PAGI::Server;

    # If using Future::IO libraries (Async::Redis, SSE->every, etc.)
    # configure Future::IO BEFORE loading them:
    use Future::IO;
    Future::IO->load_impl('IOAsync');

    my $loop = IO::Async::Loop->new;

    my $server = PAGI::Server->new(
        app  => \&my_pagi_app,
        host => '127.0.0.1',
        port => 5000,
    );

    $loop->add($server);
    $server->listen->get;  # Start accepting connections

See L</LOOP INTEROPERABILITY> for details on Future::IO configuration.

=head1 DESCRIPTION

PAGI::Server is a reference implementation of a PAGI-compliant HTTP server.
It supports HTTP/1.1, WebSocket, and Server-Sent Events (SSE) as defined
in the PAGI specification. It prioritizes spec compliance and code clarity
over performance optimization. It serves as the canonical reference for how
PAGI servers should behave.

=head1 PROTOCOL SUPPORT

B<Currently supported:>

=over 4

=item * HTTP/1.1 (full support including chunked encoding, trailers, keepalive)

=item * HTTP/2 (B<experimental> - via nghttp2, h2 over TLS and h2c cleartext)

=item * WebSocket (RFC 6455, including over HTTP/2 via RFC 8441)

=item * Server-Sent Events (SSE, including over HTTP/2)

=back

B<Not yet implemented:>

=over 4

=item * HTTP/3 (QUIC) - Under consideration

=back

For HTTP/2, see L</ENABLING HTTP/2 SUPPORT (EXPERIMENTAL)>.

=head1 WINDOWS SUPPORT

B<PAGI::Server does not support Windows.>

The server relies on Unix-specific features that are not available on Windows:

=over 4

=item * B<Unix signals> - SIGTERM, SIGINT, SIGHUP for graceful shutdown and worker management

=item * B<fork()> - Multi-worker mode requires real process forking, not thread emulation

=item * B<IO::Async internals> - The event loop has Unix-specific optimizations

=back

For Windows development, consider using WSL (Windows Subsystem for Linux) to
run PAGI::Server in a Linux environment. The PAGI specification and middleware
components can still be developed and unit-tested on Windows, but the reference
server implementation requires a Unix-like operating system.


=head1 CONSTRUCTOR

=head2 new

    my $server = PAGI::Server->new(%options);

Creates a new PAGI::Server instance. Options:

=over 4

=item app => \&coderef (required)

The PAGI application coderef with signature: async sub ($scope, $receive, $send)

=item host => $host

Bind address (IP address or hostname). Default: C<'127.0.0.1'>

The default binds only to the loopback interface, accepting connections only
from localhost. This is B<intentionally secure by default> - development
servers won't accidentally be exposed to the network.

B<Common values:>

    '127.0.0.1'      - Localhost only (default, secure for development)
    '0.0.0.0'        - All IPv4 interfaces (required for remote access)
    '::'             - All IPv6 interfaces (may also accept IPv4)
    '192.168.1.100'  - Specific interface only

B<For headless servers or production deployments> where remote clients need
to connect, bind to all interfaces:

    my $server = PAGI::Server->new(
        app  => $app,
        host => '0.0.0.0',
        port => 8080,
    );

B<Security note:> When binding to C<0.0.0.0>, ensure appropriate firewall
rules are in place. For production, consider a reverse proxy (nginx, etc.)

=item port => $port

Bind port. Default: 5000

=item ssl => \%config

Optional TLS/HTTPS configuration. B<Requires additional modules> - see
L</ENABLING TLS SUPPORT> below.

Configuration keys:

=over 4

=item cert_file => $path

Path to the SSL certificate file (PEM format).

=item key_file => $path

Path to the SSL private key file (PEM format).

=item ca_file => $path

Optional path to CA certificate for client verification.

=item verify_client => $bool

If true, require and verify client certificates.

=item min_version => $version

Minimum TLS version. Default: C<'TLSv1_2'>. Options: C<'TLSv1_2'>, C<'TLSv1_3'>.

=item cipher_list => $string

OpenSSL cipher list. Default uses modern secure ciphers.

=back

Example:

    my $server = PAGI::Server->new(
        app => $app,
        ssl => {
            cert_file => '/path/to/server.crt',
            key_file  => '/path/to/server.key',
        },
    );

=item disable_tls => $bool

Force-disable TLS even if ssl config is provided. Useful for testing
TLS configuration parsing without actually enabling TLS. Default: false.

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

=item access_log_format => $format_or_preset

Access log format string or preset name. Default: C<'clf'>

Named presets:

    clf      - PAGI default: IP, timestamp, method/path, status, duration
    combined - Apache combined: adds Referer and User-Agent
    common   - Apache common: adds response size
    tiny     - Minimal: method, path, status, duration

Custom format strings use Apache-style atoms. See L</ACCESS LOG FORMAT>.

    my $server = PAGI::Server->new(
        app               => $app,
        access_log_format => 'combined',
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

=item max_connections => $count

Maximum number of concurrent connections before returning HTTP 503.
B<Default: 1000> (same as Mojolicious).

When at capacity, new connections receive a 503 Service Unavailable
response with a Retry-After header. This prevents resource exhaustion
under heavy load.

B<Example:>

    my $server = PAGI::Server->new(
        app             => $app,
        max_connections => 5000,  # Higher limit for production
    );

B<CLI:> C<--max-connections 5000>

B<Monitoring:> Use C<< $server->connection_count >> and
C<< $server->effective_max_connections >> to monitor usage.

B<Production Tuning:>

For high-traffic production deployments, you'll likely want to increase
this value. The optimal setting depends on your workload, available
memory, and system file descriptor limits.

I<Linux - Check and increase file descriptor limits:>

    # Check current limits
    ulimit -n           # Soft limit (per-process)
    cat /proc/sys/fs/file-max  # System-wide limit

    # Increase for current session
    ulimit -n 65536

    # Permanent: add to /etc/security/limits.conf
    *  soft  nofile  65536
    *  hard  nofile  65536

    # Or for systemd services, in your unit file:
    [Service]
    LimitNOFILE=65536

I<macOS - Check and increase file descriptor limits:>

    # Check current limits
    ulimit -n           # Soft limit
    sysctl kern.maxfilesperproc  # Per-process max

    # Increase for current session
    ulimit -n 65536

    # Permanent: add to /etc/launchd.conf or use launchctl
    sudo launchctl limit maxfiles 65536 200000

I<Rule of thumb:> Set C<max_connections> to roughly 80% of your file
descriptor limit to leave headroom for database connections, log files,
and other resources.

=item write_high_watermark => $bytes

B<Power user setting.> Maximum bytes to buffer in the socket write queue
before applying backpressure. When exceeded, C<< $send->() >> calls will
pause until the buffer drains below C<write_low_watermark>.
Default: 65536 (64KB).

This prevents unbounded memory growth when the server writes data faster
than the client can receive it. The default matches Python's asyncio
transport defaults, providing a good balance between throughput and
memory efficiency.

B<When to adjust:>

=over 4

=item * B<Increase> (e.g., 256KB-1MB) for high-throughput bulk transfers
where you want fewer context switches and higher throughput at the cost
of more per-connection memory.

=item * B<Decrease> (e.g., 16KB-32KB) if supporting many concurrent
connections where memory efficiency is critical.

=back

B<Example:>

    # High-throughput file server - larger buffers
    my $server = PAGI::Server->new(
        app                  => $app,
        write_high_watermark => 262144,  # 256KB
        write_low_watermark  => 65536,   # 64KB
    );

=item write_low_watermark => $bytes

B<Power user setting.> Threshold below which sending resumes after
backpressure was applied. Must be less than or equal to
C<write_high_watermark>. Default: 16384 (16KB, which is high/4).

A larger gap between high and low watermarks reduces oscillation
(frequent pause/resume cycles). A smaller gap provides more responsive
backpressure but may increase context switching.

B<Example:>

    # Minimize oscillation with wider gap
    my $server = PAGI::Server->new(
        app                  => $app,
        write_high_watermark => 131072,  # 128KB
        write_low_watermark  => 16384,   # 16KB (8:1 ratio)
    );

=item max_body_size => $bytes

Maximum request body size in bytes. Default: 10,000,000 (10MB).
Set to 0 for unlimited (not recommended for public-facing servers).

Requests with Content-Length exceeding this limit receive HTTP 413
(Payload Too Large). Chunked requests are also checked as data arrives.

B<Example:>

    my $server = PAGI::Server->new(
        app           => $app,
        max_body_size => 50_000_000,  # 50MB for file uploads
    );

    # Unlimited (use with caution)
    my $server = PAGI::Server->new(
        app           => $app,
        max_body_size => 0,
    );

B<CLI:> C<--max-body-size 50000000>

B<Security note:> Without a body size limit, attackers can exhaust server
memory with large requests. The 10MB default balances security with common
use cases (file uploads, JSON payloads). Increase for specific needs, or
use 0 only behind a reverse proxy that enforces its own limit.

=over 4

=item * A listening socket is created before forking

=item * Worker processes are spawned using C<< $loop->fork() >> which properly
handles IO::Async's C<$ONE_TRUE_LOOP> singleton

=item * Each worker gets a fresh event loop and runs lifespan startup independently

=item * Workers that exit are automatically respawned via C<< $loop->watch_process() >>

=item * SIGTERM/SIGINT triggers graceful shutdown of all workers

=back

=item sync_file_threshold => $bytes

Threshold in bytes for synchronous file reads. Files smaller than this value
are read synchronously in the event loop; larger files use async I/O via
a worker pool.

B<Default:> 65536 (64KB)

Set to 0 for fully async file reads. This is recommended for:

=over 4

=item * Network filesystems (NFS, SMB, cloud storage)

=item * High-latency storage (spinning disks under load)

=item * Docker volumes with overlay filesystem

=back

The default (64KB) is optimized for local SSDs where small synchronous reads
are faster than the overhead of async I/O.

B<CLI:> C<--sync-file-threshold NUM>

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

B<Note:> Only applies in multi-worker mode (C<< workers > 0 >>). In single-worker
mode, this setting is ignored.

B<CLI:> C<--max-requests 10000>

Example: With 4 workers and max_requests=10000, total capacity before any
restart is 40,000 requests. Workers restart individually without downtime.

=item timeout => $seconds

Connection idle timeout in seconds. Closes connections that are idle between
requests (applies to keep-alive connections waiting for the next request).

B<Default:> 60

B<Performance note:> Each connection with a non-zero timeout creates a timer
that is reset on every read event. For maximum throughput in high-performance
scenarios, set C<timeout =E<gt> 0> to disable the idle timer entirely. This
eliminates timer management overhead but means idle connections will never
be automatically closed.

B<Example:>

    # Disable idle timeout for maximum performance
    my $server = PAGI::Server->new(
        app     => $app,
        timeout => 0,
    );

    # Short timeout to reclaim connections quickly
    my $server = PAGI::Server->new(
        app     => $app,
        timeout => 30,
    );

B<CLI:> C<--timeout 0> or C<--timeout 30>

B<Note:> This differs from C<request_timeout> (stall timeout during active
request processing). The C<timeout> applies between requests; the
C<request_timeout> applies during a request. For WebSocket and SSE, use
C<ws_idle_timeout> and C<sse_idle_timeout> respectively.

=item request_timeout => $seconds

Maximum time in seconds a request can stall without any I/O activity before
being terminated. This is a "stall timeout" - the timer resets whenever data
is read from the client or written to the client.

B<Default:> 0 (disabled)

B<Why disabled by default:> Creating per-request timers adds overhead that
impacts throughput on high-performance workloads. For maximum performance,
this is disabled by default. Most production deployments run behind a reverse
proxy (nginx, haproxy) which provides its own timeout protection.

B<When to enable:>

=over 4

=item * Running PAGI directly without a reverse proxy

=item * Small/internal apps where simplicity matters more than max throughput

=item * Untrusted clients that might send data slowly or hang

=item * Defense against application bugs that cause requests to hang indefinitely

=back

B<How it works:>

=over 4

=item * Timer starts when request processing begins

=item * Timer resets on any read activity (receiving request body)

=item * Timer resets on any write activity (sending response)

=item * If timer expires (no I/O for N seconds), connection is closed

=item * Not used for WebSocket/SSE (they have C<ws_idle_timeout>/C<sse_idle_timeout>)

=back

B<Example:>

    # Enable 30 second stall timeout (recommended when not behind proxy)
    my $server = PAGI::Server->new(
        app             => $app,
        request_timeout => 30,
    );

B<CLI:> C<--request-timeout 30>

B<Note:> This differs from C<timeout> (idle connection timeout). The
C<timeout> applies between requests on keep-alive connections. The
C<request_timeout> applies during active request processing.

=item ws_idle_timeout => $seconds

Maximum time in seconds a WebSocket connection can be idle without any
activity (no messages sent or received) before being closed.

B<Default:> 0 (disabled - WebSocket connections can be idle indefinitely)

When enabled, the timer resets on:

=over 4

=item * Sending any WebSocket frame (accept, send, ping, close)

=item * Receiving any WebSocket frame from client

=back

B<Example:>

    # Close idle WebSocket connections after 5 minutes
    my $server = PAGI::Server->new(
        app             => $app,
        ws_idle_timeout => 300,
    );

B<CLI:> C<--ws-idle-timeout 300>

B<Note:> For more sophisticated keep-alive behavior with ping/pong, use
C<< $ws->keepalive($interval, $timeout) >> for protocol-level ping/pong.

=item sse_idle_timeout => $seconds

Maximum time in seconds an SSE connection can be idle without any events
being sent before being closed.

B<Default:> 0 (disabled - SSE connections can be idle indefinitely)

The timer resets each time an event is sent to the client (including
comments and the initial headers).

B<Example:>

    # Close idle SSE connections after 2 minutes
    my $server = PAGI::Server->new(
        app              => $app,
        sse_idle_timeout => 120,
    );

B<CLI:> C<--sse-idle-timeout 120>

B<Note:> For SSE connections that may be legitimately idle, use
C<< $sse->keepalive($interval) >> to send periodic comment keepalives.

B<HTTP/2 caveat:> Over HTTP/2 this timeout applies at the connection level,
not per-stream. See L<PAGI::Server::Connection/SSE Idle Timeout over HTTP/2>
for details and recommendations.

=item heartbeat_timeout => $seconds

Worker liveness timeout in seconds. Only active in multi-worker mode
(C<< workers >= 2 >>). Has no effect in single-worker mode — use
C<timeout> for idle connection management there.

Each worker sends a heartbeat to the parent process via a Unix pipe at
an interval of C<heartbeat_timeout / 5>. The parent checks for missed
heartbeats every C<heartbeat_timeout / 2>. If a worker has not sent a
heartbeat within C<heartbeat_timeout> seconds, the parent kills it with
SIGKILL and respawns a replacement.

B<What this detects:> Event loop starvation — when the worker's event
loop is completely blocked and cannot process any events. This happens
with blocking syscalls (C<sleep()>, synchronous DNS, blocking database
drivers), deadlocks, runaway CPU-bound computation, or any code that
does not yield to the event loop.

B<What this does NOT detect:> Slow async operations. A request handler
that does C<< await $db->query(...) >> for 5 minutes is fine — the
C<await> returns control to the event loop, so heartbeats continue
normally. This value should be larger than the maximum time you expect
any single operation to block the event loop without yielding.

B<Default:> 50 (seconds). Set to 0 to disable.

B<Example:>

    # Tighter heartbeat for latency-sensitive service
    my $server = PAGI::Server->new(
        app               => $app,
        workers           => 4,
        heartbeat_timeout => 20,
    );

    # Disable heartbeat monitoring
    my $server = PAGI::Server->new(
        app               => $app,
        workers           => 4,
        heartbeat_timeout => 0,
    );

B<CLI:> C<--heartbeat-timeout 20>

=item loop_type => $backend

Specifies the IO::Async::Loop subclass to use when calling C<run()>.
This option is ignored when embedding the server in an existing loop.

B<Default:> Auto-detect (IO::Async chooses the best available backend)

B<Common values:>

    'EPoll'   - Linux epoll (recommended for Linux)
    'EV'      - libev-based (cross-platform, requires EV module)
    'Poll'    - POSIX poll() (portable fallback)
    'Select'  - select() (most portable, least scalable)

B<Example:>

    my $server = PAGI::Server->new(
        app       => $app,
        loop_type => 'EPoll',
    );
    $server->run;

B<CLI:> C<--loop EPoll> (via pagi-server)

B<Note:> The specified backend module must be installed. For example,
C<loop_type =E<gt> 'EPoll'> requires L<IO::Async::Loop::EPoll>.

=item h2_max_concurrent_streams => $count

B<(Experimental - HTTP/2 support may change in future releases.)>

Maximum number of concurrent HTTP/2 streams per connection. Each stream
represents an in-flight request/response exchange. Limits resource consumption
and provides protection against rapid-reset attacks.

B<Default:> 100

This matches Apache httpd, H2O, and Hypercorn defaults. The RFC 7540 default
is unlimited, but 100 is the industry consensus for a safe maximum.

B<Tuning:> Increase for API gateways handling many small concurrent requests.
Decrease for memory-constrained environments or when each request is expensive.

=item h2_initial_window_size => $bytes

B<(Experimental)>

Initial HTTP/2 flow control window size per stream, in bytes. Controls how
much data a client can send before the server must acknowledge receipt. Also
affects how much response data the server can buffer per stream before the
client acknowledges.

B<Default:> 65535 (64KB minus 1, the RFC 7540 default)

B<Tuning:> Increase to 131072-262144 for high-throughput file upload/download
workloads where the default window causes flow control stalls on high-latency
connections. The tradeoff is higher per-stream memory usage.

=item h2_max_frame_size => $bytes

B<(Experimental)>

Maximum size of a single HTTP/2 frame payload, in bytes. Must be between
16384 (16KB, the RFC minimum) and 16777215 (16MB, the RFC maximum).

B<Default:> 16384 (16KB, the RFC 7540 default)

Most servers use the RFC default. Larger frames reduce framing overhead but
increase head-of-line blocking within a stream.

=item h2_enable_push => $bool

B<(Experimental)>

Enable HTTP/2 server push (SETTINGS_ENABLE_PUSH). When enabled, the server
can proactively push resources to the client before they are requested.

B<Default:> 0 (disabled)

Server push is effectively deprecated. Chrome removed support in 2022,
and nginx deprecated it in version 1.25.1. Unless you have a specific use
case requiring server push, leave this disabled.

=item h2_enable_connect_protocol => $bool

B<(Experimental)>

Enable the Extended CONNECT protocol (RFC 8441, SETTINGS_ENABLE_CONNECT_PROTOCOL).
Required for WebSocket-over-HTTP/2 tunneling.

B<Default:> 1 (enabled)

When enabled, clients can use the Extended CONNECT method with a C<:protocol>
pseudo-header to establish WebSocket connections over HTTP/2 streams. Disable
this only if you do not need WebSocket support over HTTP/2.

=item h2_max_header_list_size => $bytes

B<(Experimental)>

Maximum total size of the header block that the server will accept, in bytes.
This is the sum of all header name lengths, value lengths, and 32-byte per-entry
overhead as defined by RFC 7540 Section 6.5.2.

B<Default:> 65536 (64KB)

Matches Hypercorn and Node.js defaults. Provides a guard against header-based
memory exhaustion attacks while being generous enough for normal use including
large cookies and authorization tokens.

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

=head2 connection_count

    my $count = $server->connection_count;

Returns the current number of active connections.

=head2 effective_max_connections

    my $max = $server->effective_max_connections;

Returns the effective maximum connections limit. If C<max_connections>
was set explicitly, returns that value. Otherwise returns the default
of 1000.

=head1 FILE RESPONSE STREAMING

PAGI::Server supports efficient file streaming via the C<file> and C<fh>
keys in C<http.response.body> events:

    # Stream entire file
    await $send->({
        type => 'http.response.body',
        file => '/path/to/file.mp4',
        more => 0,
    });

    # Stream partial file (for Range requests)
    await $send->({
        type => 'http.response.body',
        file => '/path/to/file.mp4',
        offset => 1000,
        length => 5000,
        more => 0,
    });

    # Stream from filehandle
    open my $fh, '<:raw', $file;
    await $send->({
        type => 'http.response.body',
        fh => $fh,
        length => $size,
        more => 0,
    });
    close $fh;

The server streams files in 64KB chunks to avoid memory bloat. Small files
(under 64KB) are read synchronously for speed; larger files use async I/O
via a worker pool to avoid blocking the event loop.

=head2 Production Recommendations for Static Files

B<For production deployments, we strongly recommend delegating static file
serving to a reverse proxy:>

=over 4

=item 1. B<Use nginx, Apache, or a CDN>

Place a reverse proxy in front of PAGI::Server and let it handle static
files directly. This provides:

=over 4

=item * Optimized file serving with kernel sendfile

=item * Efficient caching and compression

=item * Protection from slow client attacks

=item * HTTP/2 and HTTP/3 support

=back

=item 2. B<Use L<PAGI::Middleware::XSendfile>>

For files that require authentication or authorization, use the XSendfile
middleware to delegate file serving to the reverse proxy:

    use PAGI::Middleware::Builder;

    my $app = builder {
        enable 'XSendfile',
            type    => 'X-Accel-Redirect',  # For Nginx
            mapping => { '/var/www/protected/' => '/internal/' };
        $my_app;
    };

See L<PAGI::Middleware::XSendfile> for details.

=back

=head1 ENABLING TLS SUPPORT

PAGI::Server supports HTTPS/TLS connections, but requires additional modules
that are not installed by default. This keeps the base installation minimal
for users who don't need TLS.

=head2 When You Need TLS

You need TLS if you want to:

=over 4

=item * Serve HTTPS traffic directly from PAGI::Server

=item * Test TLS locally during development

=item * Use client certificate authentication

=back

You B<don't> need TLS if you:

=over 4

=item * Use a reverse proxy (nginx, Apache) that handles TLS termination

=item * Only serve HTTP traffic on localhost for development

=item * Deploy behind a load balancer that provides TLS

=back

B<Production recommendation:> Use a reverse proxy (nginx, HAProxy, etc.) for
TLS termination. They offer better performance, easier certificate management,
and battle-tested security. PAGI::Server's TLS support is primarily for
development and testing.

=head2 Installing TLS Modules

To enable TLS support, install the required modules:

B<Using cpanm:>

    cpanm IO::Async::SSL IO::Socket::SSL

B<Using system packages (Debian/Ubuntu):>

    apt-get install libio-socket-ssl-perl

B<Using system packages (RHEL/CentOS):>

    yum install perl-IO-Socket-SSL

B<Verifying installation:>

    perl -MIO::Async::SSL -MIO::Socket::SSL -e 'print "TLS modules installed\n"'

=head2 Basic TLS Configuration

Once the modules are installed, configure TLS with certificate and key files:

    my $server = PAGI::Server->new(
        app  => $app,
        host => '0.0.0.0',
        port => 5000,
        ssl  => {
            cert_file => '/path/to/server.crt',
            key_file  => '/path/to/server.key',
        },
    );

=head2 Generating Self-Signed Certificates (Development)

For local development and testing, you can generate a self-signed certificate:

B<Quick self-signed certificate (1 year validity):>

    openssl req -x509 -newkey rsa:4096 -nodes \
        -keyout server.key -out server.crt -days 365 \
        -subj "/CN=localhost"

B<With Subject Alternative Names (recommended):>

    # Create config file
    cat > ssl.conf <<EOF
    [req]
    distinguished_name = req_distinguished_name
    x509_extensions = v3_req
    prompt = no

    [req_distinguished_name]
    CN = localhost

    [v3_req]
    subjectAltName = @alt_names

    [alt_names]
    DNS.1 = localhost
    DNS.2 = *.localhost
    IP.1 = 127.0.0.1
    EOF

    # Generate certificate
    openssl req -x509 -newkey rsa:4096 -nodes \
        -keyout server.key -out server.crt -days 365 \
        -config ssl.conf -extensions v3_req

B<Testing your TLS configuration:>

    # Start server
    pagi-server --app myapp.pl --ssl-cert server.crt --ssl-key server.key

    # Test with curl (ignore self-signed cert warning)
    curl -k https://localhost:5000/

B<Production certificates:>

For production, use certificates from a trusted CA (Let's Encrypt, etc.):

    # Let's Encrypt with certbot
    certbot certonly --standalone -d yourdomain.com

    # Then configure PAGI::Server
    my $server = PAGI::Server->new(
        app => $app,
        ssl => {
            cert_file => '/etc/letsencrypt/live/yourdomain.com/fullchain.pem',
            key_file  => '/etc/letsencrypt/live/yourdomain.com/privkey.pem',
        },
    );

=head2 Advanced TLS Configuration

See the C<ssl> option in L</CONSTRUCTOR> for details on:

=over 4

=item * Client certificate verification (C<verify_client>, C<ca_file>)

=item * TLS version requirements (C<min_version>)

=item * Custom cipher suites (C<cipher_list>)

=back

=head1 ENABLING HTTP/2 SUPPORT (EXPERIMENTAL)

B<HTTP/2 support is experimental.> The API and behavior may change in future
releases. Please report issues and provide feedback.

PAGI::Server provides native HTTP/2 support via the nghttp2 C library
(L<Net::HTTP2::nghttp2>). When enabled, the server supports both TLS-based
HTTP/2 (h2 via ALPN negotiation) and cleartext HTTP/2 (h2c).

=head2 Requirements

L<Net::HTTP2::nghttp2> must be installed, which requires the nghttp2 C library:

    # Install the C library
    brew install nghttp2          # macOS
    apt-get install libnghttp2-dev  # Debian/Ubuntu

    # Install the Perl bindings
    cpanm Net::HTTP2::nghttp2

=head2 Enabling HTTP/2

B<Via CLI (pagi-server):>

    # HTTP/2 over TLS (recommended for production)
    pagi-server --http2 --ssl-cert cert.pem --ssl-key key.pem --app myapp.pl

    # HTTP/2 cleartext (h2c, for development/testing)
    pagi-server --http2 --app myapp.pl

B<Via constructor:>

    my $server = PAGI::Server->new(
        app   => $app,
        http2 => 1,
        ssl   => { cert_file => 'cert.pem', key_file => 'key.pem' },
    );

=head2 How It Works

With TLS, the server advertises C<h2> and C<http/1.1> via ALPN during the
TLS handshake. Clients that support HTTP/2 will negotiate C<h2> automatically;
others fall back to HTTP/1.1 transparently.

Without TLS, the server detects HTTP/2 via the client connection preface
(h2c mode). HTTP/1.1 clients are handled normally.

=head2 HTTP/2 Features

=over 4

=item * Stream multiplexing (100 concurrent streams per connection by default)

=item * HPACK header compression

=item * Per-stream and connection-level flow control

=item * GOAWAY graceful session shutdown

=item * Stream state validation (RST_STREAM on protocol violations)

=item * WebSocket over HTTP/2 via Extended CONNECT (RFC 8441)

=back

=head2 Conformance

Tested against h2spec (the HTTP/2 conformance test suite): B<137/146 (93.8%)>.
All 9 remaining failures are shared with the bare nghttp2 C library and cannot
be fixed at the application level.

Load tested with h2load: 60,000 requests across 50 concurrent connections with
zero failures.

See L<PAGI::Server::Compliance> for full compliance details.

=head2 Configuration

HTTP/2 protocol settings are tuned via constructor options prefixed with
C<h2_>. See L</CONSTRUCTOR> for details on:

=over 4

=item * C<h2_max_concurrent_streams> - Max streams per connection (default: 100)

=item * C<h2_initial_window_size> - Flow control window (default: 65535)

=item * C<h2_max_frame_size> - Max frame payload (default: 16384)

=item * C<h2_enable_push> - Server push (default: disabled)

=item * C<h2_enable_connect_protocol> - WebSocket over HTTP/2 (default: enabled)

=item * C<h2_max_header_list_size> - Max header block size (default: 65536)

=back

=head1 SIGNAL HANDLING

PAGI::Server responds to Unix signals for process management. Signal behavior
differs between single-worker and multi-worker modes.

=head2 Supported Signals

=over 4

=item B<SIGTERM> - Graceful shutdown

Initiates graceful shutdown. The server stops accepting new connections,
waits for active requests to complete (up to C<shutdown_timeout> seconds),
then exits. In multi-worker mode, SIGTERM is forwarded to all workers.

    kill -TERM <pid>

=item B<SIGINT> - Graceful shutdown (Ctrl-C)

Same behavior as SIGTERM. Triggered by Ctrl-C in the terminal. In multi-worker
mode, the parent process catches SIGINT and coordinates shutdown of all workers
to ensure proper lifespan.shutdown handling.

    kill -INT <pid>
    # or press Ctrl-C in terminal

=item B<SIGHUP> - Graceful worker restart (multi-worker only)

Performs a zero-downtime worker restart by spawning new workers before
terminating old ones. Useful for recycling workers to reclaim leaked memory
or reset per-worker state without dropping active connections.

B<Note:> This does NOT reload application code. New workers fork from the
existing parent process and inherit the same loaded code. For code deploys,
perform a full server restart (SIGTERM + start).

    kill -HUP <pid>

In single-worker mode, SIGHUP is logged but ignored (no graceful restart
possible without multiple workers).

=item B<SIGTTIN> - Increase worker count (multi-worker only)

Spawns an additional worker process. Use this to scale up capacity dynamically.

    kill -TTIN <pid>

=item B<SIGTTOU> - Decrease worker count (multi-worker only)

Gracefully terminates one worker process. The minimum worker count is 1;
sending SIGTTOU when only one worker remains has no effect.

    kill -TTOU <pid>

=back

=head2 Signal Handling in Multi-Worker Mode

When running with C<< workers => N >> (where N > 1):

=over 4

=item * Parent process manages the worker pool

=item * Workers handle requests; parent handles signals

=item * SIGTERM/SIGINT to parent triggers coordinated shutdown of all workers

=item * Each worker runs lifespan.shutdown before exiting

=item * Workers that crash are automatically respawned

=item * Heartbeat monitoring detects workers with blocked event loops and replaces them automatically (see C<heartbeat_timeout>)

=back

=head2 Examples

B<Zero-downtime deployment:>

    # Deploy new code, then signal graceful restart
    kill -HUP $(cat /var/run/pagi.pid)

B<Scale workers based on load:>

    # Add workers during peak hours
    kill -TTIN $(cat /var/run/pagi.pid)
    kill -TTIN $(cat /var/run/pagi.pid)

    # Remove workers during quiet periods
    kill -TTOU $(cat /var/run/pagi.pid)

B<Graceful shutdown for maintenance:>

    # Stop accepting new connections, drain existing ones
    kill -TERM $(cat /var/run/pagi.pid)

=cut

sub _init {
    my ($self, $params) = @_;

    $self->{app}              = delete $params->{app} or die "app is required";
    $self->{host}             = delete $params->{host} // '127.0.0.1';
    $self->{port}             = delete $params->{port} // 5000;
    $self->{ssl}              = delete $params->{ssl};
    $self->{disable_tls}      = delete $params->{disable_tls} // 0;  # Extract early for validation

    # Validate SSL certificate files at startup (fail fast)
    # Skip validation if TLS is explicitly disabled
    if (my $ssl = $self->{ssl}) {
        if ($self->{disable_tls}) {
            die "TLS is disabled via disable_tls option\n";
        }
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
    $self->{access_log_format} = delete $params->{access_log_format} // 'clf';
    $self->{_access_log_formatter} = $self->_compile_access_log_format(
        $self->{access_log_format}
    );
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
    $self->{max_body_size}    = delete $params->{max_body_size} // 10_000_000;  # Max body size in bytes (10MB default, 0 = unlimited)
    $self->{workers}          = delete $params->{workers} // 0;   # Number of worker processes (0 = single process)
    $self->{max_requests}     = delete $params->{max_requests} // 0;  # 0 = unlimited
    $self->{listener_backlog} = delete $params->{listener_backlog} // 2048;   # Listener queue size
    $self->{shutdown_timeout}  = delete $params->{shutdown_timeout} // 30;  # Graceful shutdown timeout (seconds)
    $self->{reuseport}         = delete $params->{reuseport} // 0;  # SO_REUSEPORT mode for multi-worker
    $self->{max_receive_queue} = delete $params->{max_receive_queue} // 1000;  # Max WebSocket receive queue size (messages)
    $self->{max_ws_frame_size} = delete $params->{max_ws_frame_size} // 65536;  # Max WebSocket frame size in bytes (64KB default)
    $self->{max_connections}     = delete $params->{max_connections} // 0;  # 0 = use default (1000)
    $self->{sync_file_threshold} = delete $params->{sync_file_threshold} // 65536;  # Threshold for sync file reads (0=always async)
    $self->{request_timeout}     = delete $params->{request_timeout} // 0;  # Request stall timeout in seconds (0 = disabled, default for performance)
    $self->{ws_idle_timeout}     = delete $params->{ws_idle_timeout} // 0;   # WebSocket idle timeout (0 = disabled)
    $self->{sse_idle_timeout}    = delete $params->{sse_idle_timeout} // 0;  # SSE idle timeout (0 = disabled)
    $self->{heartbeat_timeout}   = delete $params->{heartbeat_timeout} // 50;  # Worker heartbeat timeout (0 = disabled)
    $self->{write_high_watermark} = delete $params->{write_high_watermark} // 65536;   # 64KB - pause sending above this
    $self->{write_low_watermark}  = delete $params->{write_low_watermark}  // 16384;   # 16KB - resume sending below this
    $self->{loop_type}           = delete $params->{loop_type};  # Optional loop backend (EPoll, EV, Poll, etc.)
    # Dev-mode event validation: explicit flag, or auto-enable in development mode
    $self->{validate_events}     = delete $params->{validate_events}
        // (($ENV{PAGI_ENV} // '') eq 'development' ? 1 : 0);

    # HTTP/2 support (opt-in, experimental)
    $self->{http2} = delete $params->{http2} // $ENV{_PAGI_SERVER_HTTP2} // 0;

    # HTTP/2 protocol settings (only used when http2 is enabled)
    my $h2_max_concurrent_streams  = delete $params->{h2_max_concurrent_streams}  // 100;
    my $h2_initial_window_size     = delete $params->{h2_initial_window_size}     // 65535;
    my $h2_max_frame_size          = delete $params->{h2_max_frame_size}          // 16384;
    my $h2_enable_push             = delete $params->{h2_enable_push}             // 0;
    my $h2_enable_connect_protocol = delete $params->{h2_enable_connect_protocol} // 1;
    my $h2_max_header_list_size    = delete $params->{h2_max_header_list_size}    // 65536;

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

    # Initialize HTTP/2 protocol handler if enabled and available
    if ($self->{http2}) {
        if ($HTTP2_AVAILABLE) {
            $self->{http2_protocol} = PAGI::Server::Protocol::HTTP2->new(
                max_concurrent_streams  => $h2_max_concurrent_streams,
                initial_window_size     => $h2_initial_window_size,
                max_frame_size          => $h2_max_frame_size,
                enable_push             => $h2_enable_push,
                enable_connect_protocol => $h2_enable_connect_protocol,
                max_header_list_size    => $h2_max_header_list_size,
            );
            $self->{http2_enabled} = 1;

            # h2c mode: HTTP/2 over cleartext (no TLS)
            if (!$self->{ssl}) {
                $self->{h2c_enabled} = 1;
            }
        } else {
            die <<"END_HTTP2_ERROR";
HTTP/2 support requested but Net::HTTP2::nghttp2 is not installed.

To install:
    cpanm Net::HTTP2::nghttp2

Or disable HTTP/2:
    http2 => 0
END_HTTP2_ERROR
        }
    }

    $self->SUPER::_init($params);
}

sub configure {
    my ($self, %params) = @_;

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
    if (exists $params{max_connections}) {
        $self->{max_connections} = delete $params{max_connections};
    }
    if (exists $params{request_timeout}) {
        $self->{request_timeout} = delete $params{request_timeout};
    }
    if (exists $params{ws_idle_timeout}) {
        $self->{ws_idle_timeout} = delete $params{ws_idle_timeout};
    }
    if (exists $params{sse_idle_timeout}) {
        $self->{sse_idle_timeout} = delete $params{sse_idle_timeout};
    }
    if (exists $params{http2}) {
        $self->{http2} = delete $params{http2};
    }

    $self->SUPER::configure(%params);
}

# Log levels: debug=1, info=2, warn=3, error=4
my %_LOG_LEVELS = (debug => 1, info => 2, warn => 3, error => 4);

sub _log {
    my ($self, $level, $msg) = @_;

    my $level_num = $_LOG_LEVELS{$level} // 2;
    return if $level_num < $self->{_log_level_num};
    return if $self->{quiet} && $level ne 'error';
    warn "$msg\n";
}

# Returns a human-readable TLS status string for the startup banner
sub _tls_status_string {
    my ($self) = @_;

    if ($self->{disable_tls}) {
        return $TLS_AVAILABLE ? 'disabled' : 'n/a (disabled)';
    }
    if ($self->{tls_enabled}) {
        return 'on';
    }
    return $TLS_AVAILABLE ? 'available' : 'not installed';
}

# Returns a human-readable HTTP/2 status string for the startup banner
sub _http2_status_string {
    my ($self) = @_;

    if ($self->{http2_enabled}) {
        return $self->{h2c_enabled} ? 'on (h2c)' : 'on';
    }
    return $HTTP2_AVAILABLE ? 'available' : 'not installed';
}

# Returns a human-readable Future::XS status string for the startup banner
sub _future_xs_status_string {
    return 'on' if $FUTURE_XS_ENABLED;
    return 'available' if $FUTURE_XS_AVAILABLE;
    return 'not installed';
}

# Check if TLS modules are available
sub _check_tls_available {
    my ($self) = @_;

    # Allow forcing TLS off for testing
    if ($self->{disable_tls}) {
        die "TLS is disabled via disable_tls option\n";
    }

    return 1 if $TLS_AVAILABLE;

    die <<"END_TLS_ERROR";
TLS support requested but required modules not installed.

To enable HTTPS/TLS support, install:

    cpanm IO::Async::SSL IO::Socket::SSL

Or on Debian/Ubuntu:

    apt-get install libio-socket-ssl-perl

Then restart your application.
END_TLS_ERROR
}

# Build SSL configuration parameters for use by both single-worker and multi-worker modes.
# Returns a hashref of SSL params (including SSL_reuse_ctx) or undef if no SSL configured.
sub _build_ssl_config {
    my ($self) = @_;
    my $ssl = $self->{ssl} or return;

    $self->_check_tls_available;

    my %ssl_params;
    $ssl_params{SSL_server}      = 1;
    $ssl_params{SSL_cert_file}   = $ssl->{cert_file} if $ssl->{cert_file};
    $ssl_params{SSL_key_file}    = $ssl->{key_file}  if $ssl->{key_file};
    $ssl_params{SSL_version}     = $ssl->{min_version} // 'TLSv1_2';
    $ssl_params{SSL_cipher_list} = $ssl->{cipher_list}
        // 'ECDHE+AESGCM:DHE+AESGCM:ECDHE+CHACHA20:!aNULL:!eNULL:!EXPORT:!DES:!RC4:!MD5:!PSK:!aECDH:!EDH-DSS-DES-CBC3-SHA:!KRB5-DES-CBC3-SHA';

    if ($ssl->{verify_client}) {
        # SSL_VERIFY_PEER (0x01) | SSL_VERIFY_FAIL_IF_NO_PEER_CERT (0x02)
        $ssl_params{SSL_verify_mode} = 0x03;
        $ssl_params{SSL_ca_file} = $ssl->{ca_file} if $ssl->{ca_file};
    } else {
        $ssl_params{SSL_verify_mode} = 0x00;  # SSL_VERIFY_NONE
    }

    # ALPN negotiation for HTTP/2 support
    if ($self->{http2} && $HTTP2_AVAILABLE) {
        $ssl_params{SSL_alpn_protocols} = ['h2', 'http/1.1'];
        $self->{http2_enabled} = 1;
        $self->{h2c_enabled} = 0;  # TLS mode, not cleartext
    }

    # Pre-create shared SSL context to avoid per-connection CA bundle parsing
    my $ssl_ctx = IO::Socket::SSL::SSL_Context->new(\%ssl_params);
    $self->{_ssl_ctx} = $ssl_ctx;
    $ssl_params{SSL_reuse_ctx} = $ssl_ctx;

    # Mark TLS enabled and auto-add tls extension
    $self->{tls_enabled} = 1;
    $self->{extensions}{tls} = {} unless exists $self->{extensions}{tls};

    return \%ssl_params;
}

=head2 run

    $server->run;

Standalone entry point that creates an event loop, starts the server,
and runs until shutdown. This is the simplest way to run a PAGI server:

    my $server = PAGI::Server->new(
        app  => $app,
        port => 8080,
    );
    $server->run;

For embedding in an existing IO::Async application, use the traditional
pattern instead:

    my $loop = IO::Async::Loop->new;
    $loop->add($server);
    $server->listen->get;
    $loop->run;

The C<run()> method handles:

=over 4

=item * Creating the event loop (respecting C<loop_type> if set)

=item * Adding the server to the loop

=item * Starting the listener

=item * Setting up signal handlers for graceful shutdown

=item * Running the event loop until shutdown

=back

=cut

sub run {
    my ($self) = @_;

    my $loop = $self->_create_loop;
    $loop->add($self);

    # Start listening with error handling
    eval { $self->listen->get };
    if ($@) {
        my $error = $@;
        my $port = $self->{port};
        if ($error =~ /Address already in use/i) {
            die "Error: Port $port is already in use\n";
        }
        elsif ($error =~ /Permission denied/i) {
            die "Error: Permission denied to bind to port $port\n";
        }
        die "Error starting server: $error\n";
    }

    # Run the event loop (signal handlers were set up by listen())
    $loop->run;
}

# Create an event loop, respecting loop_type config
sub _create_loop {
    my ($self) = @_;

    if (my $loop_type = $self->{loop_type}) {
        my $loop_class = "IO::Async::Loop::$loop_type";
        eval "require $loop_class"
            or die "Cannot load loop backend '$loop_type': $@\n" .
                   "Install it with: cpanm $loop_class\n";
        return $loop_class->new;
    }

    require IO::Async::Loop;
    return IO::Async::Loop->new;
}

async sub listen {
    my ($self) = @_;

    return if $self->{running};

    # Multi-worker mode uses a completely different code path
    if ($self->{workers} && $self->{workers} > 0) {
        return $self->_listen_multiworker;
    }

    return await $self->_listen_singleworker;
}

# Single-worker mode - uses IO::Async normally
async sub _listen_singleworker {
    my ($self) = @_;

    weaken(my $weak_self = $self);

    # Run lifespan startup before accepting connections
    my $startup_result = await $self->_run_lifespan_startup;

    if (!$startup_result->{success}) {
        my $message = $startup_result->{message} // 'Lifespan startup failed';
        $self->_log(error => "PAGI Server startup failed: $message");
        die "Lifespan startup failed: $message\n";
    }

    my $listener = IO::Async::Listener->new(
        on_stream => sub  {
        my ($listener, $stream) = @_;
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
    if (my $ssl_params = $self->_build_ssl_config) {
        $listen_opts{extensions} = ['SSL'];
        %listen_opts = (%listen_opts, %$ssl_params);

        $listen_opts{on_ssl_error} = sub {
            return unless $weak_self;
            $weak_self->_log(debug => "SSL handshake failed: $_[0]");
        };
    }

    # Start listening
    my $listen_future = $listener->listen(%listen_opts);

    await $listen_future;

    # Configure accept error handler after listen() to avoid SSL extension conflicts
    # Note: SSL extensions may wrap the listener, so try to configure but ignore if it fails
    eval {
        $listener->configure(
            on_accept_error => sub  {
        my ($listener, $error) = @_;
                return unless $weak_self;
                $weak_self->_on_accept_error($error);
            },
        );
    };
    if ($@) {
        $self->_log(debug => "Could not configure on_accept_error (likely SSL listener): $@");
    }

    # Store the actual bound port from the listener's read handle
    my $socket = $listener->read_handle;
    $self->{bound_port} = $socket->sockport if $socket && $socket->can('sockport');
    $self->{running} = 1;

    # Set up signal handlers for graceful shutdown (single-worker mode)
    # Note: Windows doesn't support Unix signals, so this is skipped there
    unless (WIN32) {
        my $shutdown_triggered = 0;
        my $shutdown_handler = sub {
            return if $shutdown_triggered;
            $shutdown_triggered = 1;
            $self->adopt_future(
                $self->shutdown->on_done(sub {
                    $self->loop->stop;
                })->on_fail(sub {
                    my ($error) = @_;
                    $self->_log(error => "Shutdown error: $error");
                    $self->loop->stop;  # Still stop even on error
                })
            );
        };
        $self->loop->watch_signal(TERM => $shutdown_handler);
        $self->loop->watch_signal(INT => $shutdown_handler);

        # HUP in single-worker mode just warns (graceful restart requires multi-worker)
        my $weak_self = $self;
        weaken($weak_self);
        $self->loop->watch_signal(HUP => sub {
            $weak_self->_log(warn => "Received HUP signal (graceful restart only works in multi-worker mode)")
                if $weak_self && !$weak_self->{quiet};
        });
    }

    my $scheme = $self->{tls_enabled} ? 'https' : 'http';
    my $loop_class = ref($self->loop);
    $loop_class =~ s/^IO::Async::Loop:://;  # Shorten for display
    my $max_conn = $self->effective_max_connections;
    my $tls_status = $self->_tls_status_string;
    my $http2_status = $self->_http2_status_string;
    my $future_xs_status = $self->_future_xs_status_string;

    # Warn if access_log is a terminal (slow for benchmarks)
    if ($self->{access_log} && -t $self->{access_log}) {
        $self->_log(warn =>
            "access_log is a terminal; this may impact performance. " .
            "Consider redirecting to a file or setting access_log => undef for benchmarks."
        );
    }

    $self->_log(info => "PAGI Server listening on $scheme://$self->{host}:$self->{bound_port}/ (loop: $loop_class, max_conn: $max_conn, http2: $http2_status, tls: $tls_status, future_xs: $future_xs_status)");

    # Warn in production if using default max_connections
    if (($ENV{PAGI_ENV} // '') eq 'production' && !$self->{max_connections}) {
        $self->_log(warn =>
            "Using default max_connections (1000). For production, consider tuning this value " .
            "based on your workload. See 'perldoc PAGI::Server' for guidance."
        );
    }

    return $self;
}

# Multi-worker mode - forks workers, each with their own event loop
sub _listen_multiworker {
    my ($self) = @_;

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

    # Validate TLS modules and set tls_enabled before forking workers
    if ($self->{ssl}) {
        $self->_check_tls_available;
        $self->{tls_enabled} = 1;
    }

    my $scheme = $self->{ssl} ? 'https' : 'http';
    my $loop_class = ref($self->loop);
    $loop_class =~ s/^IO::Async::Loop:://;  # Shorten for display
    my $mode = $reuseport ? 'reuseport' : 'shared-socket';
    my $max_conn = $self->effective_max_connections;
    my $tls_status = $self->_tls_status_string;
    my $http2_status = $self->_http2_status_string;
    my $future_xs_status = $self->_future_xs_status_string;

    # Warn if access_log is a terminal (slow for benchmarks)
    if ($self->{access_log} && -t $self->{access_log}) {
        $self->_log(warn =>
            "access_log is a terminal; this may impact performance. " .
            "Consider redirecting to a file or setting access_log => undef for benchmarks."
        );
    }

    $self->_log(info => "PAGI Server (multi-worker, $mode) listening on $scheme://$self->{host}:$self->{bound_port}/ with $workers workers (loop: $loop_class, max_conn: $max_conn/worker, http2: $http2_status, tls: $tls_status, future_xs: $future_xs_status)");

    # Warn in production if using default max_connections
    if (($ENV{PAGI_ENV} // '') eq 'production' && !$self->{max_connections}) {
        $self->_log(warn =>
            "Using default max_connections (1000). For production, consider tuning this value " .
            "based on your workload. See 'perldoc PAGI::Server' for guidance."
        );
    }

    my $loop = $self->loop;

    # Fork the workers FIRST, before setting up signal handlers.
    # This prevents children from inheriting the parent's sigpipe setup,
    # which can cause issues with Ctrl-C signal delivery on macOS.
    for my $i (1 .. $workers) {
        $self->_spawn_worker($listen_socket, $i);
    }

    # Set up signal handlers for parent process AFTER forking
    # Note: Windows doesn't support Unix signals, so this is skipped there
    unless (WIN32) {
        $loop->watch_signal(TERM => sub { $self->_initiate_multiworker_shutdown });
        $loop->watch_signal(INT  => sub { $self->_initiate_multiworker_shutdown });
        $loop->watch_signal(HUP => sub { $self->_graceful_restart });
        $loop->watch_signal(TTIN => sub { $self->_increase_workers });
        $loop->watch_signal(TTOU => sub { $self->_decrease_workers });
    }

    # Start heartbeat monitor if enabled
    if ($self->{heartbeat_timeout} && $self->{heartbeat_timeout} > 0) {
        my $hb_timeout = $self->{heartbeat_timeout};
        my $check_interval = $hb_timeout / 2;
        weaken(my $weak_self = $self);

        my $hb_check_timer = IO::Async::Timer::Periodic->new(
            interval => $check_interval,
            on_tick  => sub {
                return unless $weak_self;
                return if $weak_self->{shutting_down};

                my $now = time();
                for my $pid (keys %{$weak_self->{worker_pids}}) {
                    my $info = $weak_self->{worker_pids}{$pid};
                    next unless $info->{heartbeat_rd};

                    # Drain all available heartbeat bytes
                    while (sysread($info->{heartbeat_rd}, my $buf, 64)) {
                        $info->{last_heartbeat} = $now;
                    }

                    # Kill if heartbeat expired
                    if ($now - $info->{last_heartbeat} > $hb_timeout) {
                        $weak_self->_log(warn =>
                            "Worker $pid (worker $info->{worker_num}) heartbeat " .
                            "timeout after ${hb_timeout}s, sending SIGKILL");
                        kill 'KILL', $pid;
                    }
                }
            },
        );

        $self->add_child($hb_check_timer);
        $hb_check_timer->start;
        $self->{_heartbeat_check_timer} = $hb_check_timer;
    }

    # Store the socket for cleanup during shutdown (only in traditional mode)
    $self->{listen_socket} = $listen_socket if $listen_socket;

    # Return immediately - caller (Runner) will call $loop->run()
    # This is consistent with single-worker mode behavior
    return $self;
}

# Initiate graceful shutdown in multi-worker mode
sub _initiate_multiworker_shutdown {
    my ($self) = @_;

    return if $self->{shutting_down};
    $self->{shutting_down} = 1;
    $self->{running} = 0;

    # Stop heartbeat monitoring — shutdown escalation timer handles stuck workers
    if ($self->{_heartbeat_check_timer}) {
        $self->{_heartbeat_check_timer}->stop;
        $self->remove_child($self->{_heartbeat_check_timer});
        delete $self->{_heartbeat_check_timer};
    }

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
        return;
    }

    # Escalate to SIGKILL after shutdown_timeout for workers that ignore SIGTERM
    my $timeout = $self->{shutdown_timeout} // 30;
    weaken(my $weak_self = $self);
    $self->{_shutdown_kill_timer} = $self->loop->watch_time(
        after => $timeout,
        code  => sub {
            return unless $weak_self;
            for my $pid (keys %{$weak_self->{worker_pids}}) {
                $weak_self->_log(warn =>
                    "Worker $pid did not exit after ${timeout}s, sending SIGKILL");
                kill 'KILL', $pid;
            }
        },
    );
}

# Graceful restart: replace all workers one by one
sub _graceful_restart {
    my ($self) = @_;

    return if $self->{shutting_down};

    $self->_log(info => "Received HUP, performing graceful restart");

    # Signal all current workers to shutdown
    # watch_process callbacks will respawn them
    my $timeout = $self->{shutdown_timeout} // 30;
    for my $pid (keys %{$self->{worker_pids}}) {
        kill 'TERM', $pid;

        # Escalate to SIGKILL if worker doesn't exit within shutdown_timeout
        weaken(my $weak_self = $self);
        $self->{_restart_kill_timers}{$pid} = $self->loop->watch_time(
            after => $timeout,
            code  => sub {
                return unless $weak_self;
                if (exists $weak_self->{worker_pids}{$pid}) {
                    $weak_self->_log(warn =>
                        "Worker $pid did not exit after ${timeout}s during restart, sending SIGKILL");
                    kill 'KILL', $pid;
                }
            },
        );
    }
}

# Increase worker pool by 1
sub _increase_workers {
    my ($self) = @_;

    return if $self->{shutting_down};

    my $current = scalar keys %{$self->{worker_pids}};
    my $new_worker_num = $current + 1;

    $self->_log(info => "Received TTIN, spawning worker $new_worker_num (total: $new_worker_num)");
    $self->_spawn_worker($self->{listen_socket}, $new_worker_num);
}

# Decrease worker pool by 1
sub _decrease_workers {
    my ($self) = @_;

    return if $self->{shutting_down};

    my @pids = keys %{$self->{worker_pids}};
    return unless @pids > 1;  # Keep at least 1 worker

    my $victim_pid = $pids[-1];  # Kill most recent
    my $remaining = scalar(@pids) - 1;

    $self->_log(info => "Received TTOU, killing worker (remaining: $remaining)");

    # Mark as "don't respawn" by setting a flag before killing
    $self->{_dont_respawn}{$victim_pid} = 1;
    kill 'TERM', $victim_pid;
}

sub _spawn_worker {
    my ($self, $listen_socket, $worker_num) = @_;

    my $loop = $self->loop;
    weaken(my $weak_self = $self);

    # Create heartbeat pipe if enabled
    my ($hb_rd, $hb_wr);
    if ($self->{heartbeat_timeout} && $self->{heartbeat_timeout} > 0) {
        pipe($hb_rd, $hb_wr) or die "Cannot create heartbeat pipe: $!";
    }

    # Set IGNORE before fork - child inherits it. IO::Async only resets
    # CODE refs, so 'IGNORE' (a string) survives. Child must NOT call
    # watch_signal(INT) or it will overwrite the IGNORE.
    my $old_sigint = $SIG{INT};
    $SIG{INT} = 'IGNORE' unless WIN32;

    my $pid = $loop->fork(
        code => sub {
            close($hb_rd) if $hb_rd;
            $self->_run_as_worker($listen_socket, $worker_num, $hb_wr);
            return 0;
        },
    );

    # Restore parent's SIGINT handler
    $SIG{INT} = $old_sigint unless WIN32;

    die "Fork failed" unless defined $pid;

    # Parent — close write end, set read end non-blocking
    if ($hb_wr) {
        close($hb_wr);
        $hb_rd->blocking(0);
    }

    # Parent - track the worker
    $self->{worker_pids}{$pid} = {
        worker_num     => $worker_num,
        started        => time(),
        heartbeat_rd   => $hb_rd,
        last_heartbeat => time(),
    };

    # Use watch_process to handle worker exit (replaces manual SIGCHLD handling)
    $loop->watch_process($pid => sub {
        my ($exit_pid, $exitcode) = @_;
        return unless $weak_self;

        # Close heartbeat pipe read end
        if (my $info = $weak_self->{worker_pids}{$exit_pid}) {
            close($info->{heartbeat_rd}) if $info->{heartbeat_rd};
        }

        # Remove from tracking
        delete $weak_self->{worker_pids}{$exit_pid};

        # Cancel per-worker restart kill timer if one exists
        if (my $timer_id = delete $weak_self->{_restart_kill_timers}{$exit_pid}) {
            $loop->unwatch_time($timer_id);
        }

        # Check exit code: exit(2) = startup failure, don't respawn
        my $exit_code = $exitcode >> 8;
        if ($exit_code == 2) {
            $weak_self->_log(warn => "Worker $worker_num startup failed, not respawning");
            # Don't respawn - startup failure would just repeat
        }
        # Respawn if still running and not shutting down
        elsif ($weak_self->{running} && !$weak_self->{shutting_down}) {
            # Don't respawn if this was a TTOU reduction
            unless (delete $weak_self->{_dont_respawn}{$exit_pid}) {
                $weak_self->_spawn_worker($listen_socket, $worker_num);
            }
        }

        # Check if all workers have exited (for shutdown)
        if ($weak_self->{shutting_down} && !keys %{$weak_self->{worker_pids}}) {
            # Cancel the shutdown SIGKILL escalation timer
            if ($weak_self->{_shutdown_kill_timer}) {
                $loop->unwatch_time($weak_self->{_shutdown_kill_timer});
                delete $weak_self->{_shutdown_kill_timer};
            }
            $loop->stop;
        }
    });

    return $pid;
}

sub _run_as_worker {
    my ($self, $listen_socket, $worker_num, $heartbeat_wr) = @_;

    # Note: $ONE_TRUE_LOOP already cleared by $loop->fork(), so this creates a fresh loop
    # Note: $SIG{INT} = 'IGNORE' inherited from parent - do NOT call watch_signal(INT)
    #       or it will overwrite the IGNORE with a CODE ref!
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
        http2           => $self->{http2},
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
        shutdown_timeout    => $self->{shutdown_timeout},
        request_timeout     => $self->{request_timeout},
        ws_idle_timeout     => $self->{ws_idle_timeout},
        sse_idle_timeout    => $self->{sse_idle_timeout},
        sync_file_threshold => $self->{sync_file_threshold},
        max_receive_queue   => $self->{max_receive_queue},
        max_ws_frame_size   => $self->{max_ws_frame_size},
        write_high_watermark => $self->{write_high_watermark},
        write_low_watermark  => $self->{write_low_watermark},
        workers          => 0,  # Single-worker mode in worker process
    );
    $worker_server->{is_worker} = 1;
    $worker_server->{worker_num} = $worker_num;  # Store for lifespan scope
    $worker_server->{_request_count} = 0;  # Track requests handled
    $worker_server->{bound_port} = $listen_socket->sockport;

    $loop->add($worker_server);

    # Build SSL config for this worker (each worker gets its own SSL context post-fork)
    my $ssl_params = $worker_server->_build_ssl_config;

    # Set up graceful shutdown on SIGTERM using IO::Async's signal watching
    # (raw $SIG handlers don't work reliably when the loop is running)
    # Note: Windows doesn't support Unix signals, so this is skipped there
    # Note: We do NOT set up watch_signal(INT) here - workers inherit $SIG{INT}='IGNORE'
    #       from parent, so they ignore SIGINT (including Ctrl-C). Parent sends SIGTERM.
    unless (WIN32) {
        my $shutdown_triggered = 0;
        $loop->watch_signal(TERM => sub {
            return if $shutdown_triggered;
            $shutdown_triggered = 1;
            $worker_server->adopt_future(
                $worker_server->shutdown->on_done(sub {
                    $loop->stop;
                })->on_fail(sub {
                    my ($error) = @_;
                    $worker_server->_log(error => "Worker shutdown error: $error");
                    $loop->stop;  # Still stop even on error
                })
            );
        });
    }

    # Run lifespan startup using a proper async wrapper
    my $startup_done = 0;
    my $startup_error;

    my $startup_future = (async sub {
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
    })->();

    # Use adopt_future instead of retain
    $worker_server->adopt_future($startup_future);

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
        on_stream => sub {
            my ($listener, $stream) = @_;
            return unless $weak_server;

            if ($ssl_params) {
                $loop->SSL_upgrade(
                    handle        => $stream,
                    SSL_server    => 1,
                    SSL_reuse_ctx => $worker_server->{_ssl_ctx},
                )->on_done(sub {
                    $weak_server->_on_connection($stream) if $weak_server;
                })->on_fail(sub {
                    my ($failure) = @_;
                    $weak_server->_log(debug => "SSL handshake failed: $failure")
                        if $weak_server;
                });
            } else {
                $weak_server->_on_connection($stream);
            }
        },
    );

    $worker_server->add_child($listener);
    $worker_server->{listener} = $listener;

    # Set up heartbeat writer: periodically signal liveness to parent
    if ($heartbeat_wr) {
        my $interval = ($self->{heartbeat_timeout} || 50) / 5;
        my $hb_timer = IO::Async::Timer::Periodic->new(
            interval => $interval,
            on_tick  => sub {
                syswrite($heartbeat_wr, "\x00", 1);
            },
        );
        $worker_server->add_child($hb_timer);
        $hb_timer->start;
    }

    # Configure accept error handler - try but ignore if it fails (SSL listeners may not support it)
    eval {
        $listener->configure(
            on_accept_error => sub  {
        my ($listener, $error) = @_;
                return unless $weak_server;
                $weak_server->_on_accept_error($error);
            },
        );
    };
    # Silently ignore configuration errors in workers

    $worker_server->{running} = 1;

    # Run the event loop
    $loop->run;

    # Clean up FDs before exit
    close($heartbeat_wr)  if $heartbeat_wr;
    close($listen_socket) if $listen_socket;
    exit(0);
}

sub _on_connection {
    my ($self, $stream) = @_;

    weaken(my $weak_self = $self);

    # Check if we're at capacity
    my $max = $self->effective_max_connections;
    if ($self->connection_count >= $max) {
        # Over capacity - send 503 and close
        $self->_send_503_and_close($stream);
        return;
    }

    # Detect ALPN-negotiated protocol from TLS handle
    my $alpn_protocol;
    if ($self->{tls_enabled} && $self->{http2_enabled}) {
        my $handle = $stream->write_handle // $stream->read_handle;
        if ($handle && $handle->can('alpn_selected')) {
            $alpn_protocol = eval { $handle->alpn_selected };
        }
    }

    my $conn = PAGI::Server::Connection->new(
        stream            => $stream,
        app               => $self->{app},
        protocol          => $self->{protocol},
        server            => $self,
        extensions        => $self->{extensions},
        state             => $self->{state},
        tls_enabled       => $self->{tls_enabled} // 0,
        timeout           => $self->{timeout},
        request_timeout   => $self->{request_timeout},
        ws_idle_timeout   => $self->{ws_idle_timeout},
        sse_idle_timeout  => $self->{sse_idle_timeout},
        max_body_size     => $self->{max_body_size},
        access_log        => $self->{access_log},
        _access_log_formatter => $self->{_access_log_formatter},
        max_receive_queue => $self->{max_receive_queue},
        max_ws_frame_size => $self->{max_ws_frame_size},
        sync_file_threshold => $self->{sync_file_threshold},
        validate_events   => $self->{validate_events},
        write_high_watermark => $self->{write_high_watermark},
        write_low_watermark  => $self->{write_low_watermark},
        ($self->{http2_enabled} ? (
            h2_protocol   => $self->{http2_protocol},
            alpn_protocol => $alpn_protocol,
            h2c_enabled   => $self->{h2c_enabled} // 0,
        ) : ()),
    );

    # Track the connection (O(1) hash insert)
    $self->{connections}{refaddr($conn)} = $conn;

    # Configure stream with callbacks BEFORE adding to loop
    $conn->start;

    # Add stream to the loop so it can read/write
    $self->add_child($stream);
}

sub _send_503_and_close {
    my ($self, $stream) = @_;

    my $body = "503 Service Unavailable - Server at capacity\r\n";
    my $response = join("\r\n",
        "HTTP/1.1 503 Service Unavailable",
        "Content-Type: text/plain",
        "Content-Length: " . length($body),
        "Connection: close",
        "Retry-After: 5",
        "",
        $body
    );

    # Configure stream with minimal on_read handler (required by IO::Async)
    $stream->configure(
        on_read => sub { 0 },  # Ignore any incoming data
    );

    # Add stream to loop so it can write
    $self->add_child($stream);

    # Write response and close
    $stream->write($response);
    $stream->close_when_empty;

    $self->_log(warn => "Connection rejected: at capacity (" . $self->connection_count . "/" . $self->effective_max_connections . ")");
}

sub _on_accept_error {
    my ($self, $error) = @_;

    # EMFILE = "Too many open files" - we're out of file descriptors
    # ENFILE = System-wide FD limit reached
    if ($error =~ /Too many open files|EMFILE|ENFILE/i) {
        # Only log the first EMFILE in a burst (when we're not already paused)
        unless ($self->{_accept_paused}) {
            $self->_log(warn => "Accept error (FD exhaustion): $error - pausing accept for 100ms");
        }

        # Pause accepting for a short time to let connections drain
        $self->_pause_accepting(0.1);
    }
    else {
        # Log other accept errors but don't crash
        $self->_log(error => "Accept error: $error");
    }
}

sub _pause_accepting {
    my ($self, $duration) = @_;

    return if $self->{_accept_paused};
    $self->{_accept_paused} = 1;

    # Cancel any existing timer before creating new one
    if ($self->{_accept_pause_timer}) {
        $self->loop->unwatch_time($self->{_accept_pause_timer});
        delete $self->{_accept_pause_timer};
    }

    # Temporarily disable the listener
    if ($self->{listener} && $self->{listener}->read_handle) {
        $self->{listener}->want_readready(0);
    }

    # Re-enable after duration
    my $timer_id = $self->loop->watch_time(after => $duration, code => sub {
        return unless $self->{running};
        $self->{_accept_paused} = 0;
        delete $self->{_accept_pause_timer};
        if ($self->{listener} && $self->{listener}->read_handle) {
            $self->{listener}->want_readready(1);
        }
        $self->_log(debug => "Accept resumed after FD exhaustion pause");
    });

    # Store the timer ID for cleanup
    $self->{_accept_pause_timer} = $timer_id;
}

sub _log_connection_stats {
    my ($self) = @_;

    my $current = $self->connection_count;
    my $max = $self->effective_max_connections;
    my $pct = int(($current / $max) * 100);

    $self->_log(info => "Connections: $current/$max ($pct%)");
}

# Called when a request completes (for max_requests tracking)
sub _on_request_complete {
    my ($self) = @_;

    return unless $self->{is_worker};
    return unless $self->{max_requests} && $self->{max_requests} > 0;

    $self->{_request_count}++;

    if ($self->{_request_count} >= $self->{max_requests}) {
        return if $self->{_max_requests_shutdown_triggered};  # Prevent duplicate shutdowns
        $self->{_max_requests_shutdown_triggered} = 1;
        $self->_log(info => "Worker $$: reached max_requests ($self->{max_requests}), shutting down");
        # Initiate graceful shutdown (finish current connections, then exit)
        $self->adopt_future(
            $self->shutdown->on_done(sub {
                $self->loop->stop;
            })->on_fail(sub {
                my ($error) = @_;
                $self->_log(error => "Worker $$: max_requests shutdown error: $error");
                $self->loop->stop;  # Still stop even on error
            })
        );
    }
}

# Lifespan Protocol Implementation

async sub _run_lifespan_startup {
    my ($self) = @_;

    # Create lifespan scope
    my $scope = {
        type => 'lifespan',
        pagi => {
            version      => '0.2',
            spec_version => '0.2',
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
    my $send = async sub  {
        my ($event) = @_;
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
        # Per spec: if the app throws an exception for lifespan scope,
        # the server should continue without lifespan support.
        # This matches Uvicorn/Hypercorn "auto" mode behavior.
        # Apps that don't support lifespan should: die if $scope->{type} ne 'websocket';
        $lifespan_supported = 0;
        if (!$startup_complete->is_ready) {
            $self->_log(info => "Lifespan not supported, continuing without it");
            $startup_complete->done({ success => 1, lifespan_supported => 0 });
        }
    })->();

    # Keep the app future so we can trigger shutdown later
    $self->{lifespan_app_future} = $app_future;
    # Use adopt_future instead of retain for proper error handling
    $self->adopt_future($app_future);

    # Wait for startup complete (with timeout)
    my $result = await $startup_complete;

    # Track if lifespan is supported
    $self->{lifespan_supported} = $result->{lifespan_supported} // 1;

    return $result;
}

async sub _run_lifespan_shutdown {
    my ($self) = @_;

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

async sub shutdown {
    my ($self) = @_;

    return unless $self->{running};
    $self->{running} = 0;
    $self->{shutting_down} = 1;

    # Cancel accept pause timer if active
    if ($self->{_accept_pause_timer}) {
        $self->loop->unwatch_time($self->{_accept_pause_timer});
        delete $self->{_accept_pause_timer};
        $self->{_accept_paused} = 0;
    }

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
async sub _drain_connections {
    my ($self) = @_;

    my $timeout = $self->{shutdown_timeout} // 30;
    my $loop = $self->loop;

    # First, close all idle connections immediately (not processing a request)
    # Keep-alive connections waiting for next request should be closed
    my @idle = grep { !$_->{handling_request} } values %{$self->{connections}};
    for my $conn (@idle) {
        $conn->_handle_disconnect_and_close('server_shutdown');
    }

    # Also close long-lived connections (SSE, WebSocket) immediately
    # These never become "idle" so would wait for full timeout otherwise
    my @longlived = grep { $_->{sse_mode} || $_->{websocket_mode} } values %{$self->{connections}};
    for my $conn (@longlived) {
        $conn->_handle_disconnect_and_close('server_shutdown');
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

# --- Access log format compiler ---

my %ACCESS_LOG_PRESETS = (
    clf      => '%h - - [%t] "%m %U%q" %s %ds',
    combined => '%h - - [%t] "%r" %s %b "%{Referer}i" "%{User-Agent}i"',
    common   => '%h - - [%t] "%r" %s %b',
    tiny     => '%m %U%q %s %Dms',
);

sub _compile_access_log_format {
    my ($class_or_self, $format) = @_;

    # Resolve preset names
    if (exists $ACCESS_LOG_PRESETS{$format}) {
        $format = $ACCESS_LOG_PRESETS{$format};
    }

    # Parse format string into a list of fragments (closures or literal strings)
    my @fragments;
    my $pos = 0;
    my $len = length($format);

    while ($pos < $len) {
        my $ch = substr($format, $pos, 1);

        if ($ch eq '%') {
            $pos++;
            last if $pos >= $len;

            my $next = substr($format, $pos, 1);

            if ($next eq '%') {
                # Literal percent
                push @fragments, '%';
                $pos++;
            }
            elsif ($next eq '{') {
                # Header extraction: %{Name}i
                my $end = index($format, '}', $pos);
                die "Unterminated %{...} in access log format\n" if $end < 0;
                my $header_name = substr($format, $pos + 1, $end - $pos - 1);
                $pos = $end + 1;

                # Must be followed by 'i' (request header)
                die "Expected 'i' after %{$header_name} in access log format\n"
                    if $pos >= $len || substr($format, $pos, 1) ne 'i';
                $pos++;

                my $lc_name = lc($header_name);
                push @fragments, sub {
                    my ($info) = @_;
                    for my $h (@{$info->{request_headers}}) {
                        return $h->[1] if lc($h->[0]) eq $lc_name;
                    }
                    return '-';
                };
            }
            else {
                # Simple atom
                my $atom = $next;
                $pos++;

                my $frag = _access_log_atom($atom);
                push @fragments, $frag;
            }
        }
        else {
            # Literal text: collect until next %
            my $next_pct = index($format, '%', $pos);
            if ($next_pct < 0) {
                push @fragments, substr($format, $pos);
                $pos = $len;
            }
            else {
                push @fragments, substr($format, $pos, $next_pct - $pos);
                $pos = $next_pct;
            }
        }
    }

    # Build a single closure from fragments
    return sub {
        my ($info) = @_;
        return join('', map { ref $_ ? $_->($info) : $_ } @fragments);
    };
}

sub _access_log_atom {
    my ($atom) = @_;

    my %atoms = (
        h => sub { $_[0]->{client_ip} // '-' },
        l => sub { '-' },
        u => sub { '-' },
        t => sub { $_[0]->{timestamp} // '-' },
        r => sub {
            my $i = $_[0];
            my $uri = $i->{path} // '/';
            my $qs = $i->{query};
            $uri .= "?$qs" if defined $qs && length $qs;
            sprintf('%s %s HTTP/%s', $i->{method} // '-', $uri, $i->{http_version} // '1.1');
        },
        m => sub { $_[0]->{method} // '-' },
        U => sub { $_[0]->{path} // '/' },
        q => sub {
            my $qs = $_[0]->{query};
            (defined $qs && length $qs) ? "?$qs" : '';
        },
        H => sub { 'HTTP/' . ($_[0]->{http_version} // '1.1') },
        s => sub { $_[0]->{status} // '-' },
        b => sub {
            my $size = $_[0]->{size} // 0;
            $size ? $size : '-';
        },
        B => sub { $_[0]->{size} // 0 },
        d => sub { sprintf('%.3f', $_[0]->{duration} // 0) },
        D => sub { int(($_[0]->{duration} // 0) * 1_000_000) },
        T => sub { int($_[0]->{duration} // 0) },
    );

    if (my $frag = $atoms{$atom}) {
        return $frag;
    }

    die "Unknown access log format atom '%$atom'\n";
}

sub port {
    my ($self) = @_;

    return $self->{bound_port} // $self->{port};
}

sub is_running {
    my ($self) = @_;

    return $self->{running} ? 1 : 0;
}

sub connection_count {
    my ($self) = @_;

    return scalar keys %{$self->{connections}};
}

sub effective_max_connections {
    my ($self) = @_;

    # If explicitly set, use that; otherwise default to 1000
    # (Same default as Mojolicious - simple, predictable, no platform-specific hacks)
    return $self->{max_connections} && $self->{max_connections} > 0
        ? $self->{max_connections}
        : 1000;
}

1;

__END__

=head1 PERFORMANCE

PAGI::Server is designed as a reference implementation prioritizing spec
compliance and code clarity, yet delivers competitive performance suitable
for production workloads.

=head2 Benchmark Results

Tested on a 2.4 GHz 8-Core Intel Core i9 Mac with 8 workers, using
L<hey|https://github.com/rakyll/hey> against a PAGI hello world
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

=head1 ACCESS LOG FORMAT

The C<access_log_format> option accepts Apache-style format strings or preset
names. Format strings are pre-compiled into closures at server startup for
fast per-request formatting.

=head2 Format Atoms

=over 4

=item C<%h> - Client IP address

=item C<%l> - Remote logname (always C<->)

=item C<%u> - Remote user (always C<->)

=item C<%t> - CLF timestamp (e.g., C<10/Feb/2026:12:34:56 +0000>)

=item C<%r> - Request line (e.g., C<GET /path?query HTTP/1.1>)

=item C<%m> - Request method

=item C<%U> - URL path (without query string)

=item C<%q> - Query string (with leading C<?>, or empty)

=item C<%H> - Protocol (e.g., C<HTTP/1.1>)

=item C<%s> - Response status code

=item C<%b> - Response body size in bytes (C<-> if zero)

=item C<%B> - Response body size in bytes (C<0> if zero)

=item C<%d> - Duration in seconds with 3 decimal places (e.g., C<0.123>)

=item C<%D> - Duration in microseconds (integer)

=item C<%T> - Duration in seconds (integer)

=item C<%{Header}i> - Value of request header (case-insensitive, C<-> if missing)

=item C<%%> - Literal percent sign

=back

=head2 Named Presets

=over 4

=item C<clf> (default)

C<%h - - [%t] "%m %U%q" %s %ds> - PAGI's default format with fractional
second duration.

=item C<combined>

C<%h - - [%t] "%r" %s %b "%{Referer}i" "%{User-Agent}i"> - Apache combined
format with referrer and user agent.

=item C<common>

C<%h - - [%t] "%r" %s %b> - Apache common log format with response size.

=item C<tiny>

C<%m %U%q %s %Dms> - Minimal format showing method, path, status, and
duration in milliseconds.

=back

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

=head1 LOOP INTEROPERABILITY

PAGI::Server uses L<IO::Async> as its event loop. When using C<pagi-server>
(the CLI), if L<Future::IO> is installed, it is automatically configured to use
the IO::Async backend. This enables seamless integration with Future::IO-based
libraries like L<Async::Redis>.

=head2 Programmatic Usage

If you're using PAGI::Server programmatically (embedding it in your own
script rather than using pagi-server), you must configure Future::IO
yourself before loading any Future::IO-based libraries:

    #!/usr/bin/env perl
    use strict;
    use warnings;
    use IO::Async::Loop;
    use PAGI::Server;

    # Configure Future::IO BEFORE loading Future::IO-based libraries
    use Future::IO;
    Future::IO->load_impl('IOAsync');

    # Now Future::IO libraries work correctly
    use Async::Redis;

    my $app = sub { ... };

    my $loop = IO::Async::Loop->new;
    my $server = PAGI::Server->new(
        app  => $app,
        port => 8080,
    );

    $loop->add($server);
    $server->listen->get;
    $loop->run;

=head2 Why This Matters

L<Future::IO> provides event loop-agnostic async I/O operations (sleep,
read, write). Libraries built on Future::IO can work with any event loop,
but Future::IO must be told which backend to use.

When using C<pagi-server>, this is handled automatically. When embedding
PAGI::Server, you control the setup and must configure Future::IO explicitly
if you use libraries that depend on it.

Features that require Future::IO configuration:

=over 4

=item * L<PAGI::SSE/every> - Periodic SSE events

=item * L<Async::Redis> - Redis client

=item * Other Future::IO-based libraries

=back

If Future::IO is not configured, these features will fail with a helpful
error message explaining how to fix it.

=head1 SEE ALSO

L<PAGI::Server::Connection>, L<PAGI::Server::Protocol::HTTP1>,
L<PAGI::Server::Protocol::HTTP2>, L<PAGI::Server::Compliance>,
L<Net::HTTP2::nghttp2>, L<Future::IO>

=head1 AUTHOR

John Napiorkowski E<lt>jjnapiork@cpan.orgE<gt>

=head1 LICENSE

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
