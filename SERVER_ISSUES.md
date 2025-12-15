# PAGI::Server Production Readiness Audit

This document contains a comprehensive audit of PAGI::Server identifying issues that should be addressed before production deployment. Each issue includes the exact file location, code snippets, risk assessment, and recommended fix.

**Audit Date:** 2024-12-14
**Files Audited:** `lib/PAGI/Server.pm`, `lib/PAGI/Server/*.pm`
**Total Issues Found:** 29 (5 Critical, 3 High, 17 Medium, 4 Low)
**Issues Fixed:** 21 (1.1-1.5, 2.1, 2.3, 2.4, 2.5, 3.3, 3.5, 3.6, 3.7, 3.8, 3.9, 3.10, 3.12, 3.15, 3.16, 4.2, 4.4)
**Issues Removed:** 4 (1.6, 2.2, 3.4, 4.3 - not real issues)

---

## Table of Contents

1. [Critical Issues](#1-critical-issues)
2. [High Severity Issues](#2-high-severity-issues)
3. [Medium Severity Issues](#3-medium-severity-issues)
4. [Low Severity Issues](#4-low-severity-issues)
5. [Summary and Priority Order](#5-summary-and-priority-order)

---

## 1. Critical Issues

### 1.1 Missing `_send_close_frame()` Method

**Status:** FIXED (2024-12-14)
**File:** `lib/PAGI/Server/Connection.pm`
**Line:** 1477

**Problem:**
Code calls a method that doesn't exist, causing a crash when WebSocket receives invalid UTF-8 data.

**Current Code:**
```perl
# Around line 1477 in Connection.pm
$self->_send_close_frame(1007, 'Invalid UTF-8');
```

**Impact:**
- WebSocket connections with invalid UTF-8 cause fatal server errors
- Connection handler crashes instead of graceful close
- Potential DoS vector - send malformed UTF-8 to crash connections

**Recommended Fix:**
Implement the `_send_close_frame()` method:

```perl
sub _send_close_frame ($self, $code, $reason = '') {
    my $frame = Protocol::WebSocket::Frame->new(
        type    => 'close',
        buffer  => pack('n', $code) . $reason,
        masked  => 0,
    );
    $self->{stream}->write($frame->to_bytes);
}
```

---

### 1.2 Header Injection Vulnerability in HTTP Response

**Status:** FIXED (2024-12-14)
**File:** `lib/PAGI/Server/Protocol/HTTP1.pm`
**Lines:** 251-257

**Problem:**
Response headers from the application are directly concatenated without CRLF validation, allowing response splitting attacks.

**Current Code:**
```perl
# Protocol/HTTP1.pm lines 227-230
for my $header (@$headers) {
    my ($name, $value) = @$header;
    $response .= "$name: $value\r\n";  # NO VALIDATION
}
```

**Attack Vector:**
```perl
# Malicious application code could do:
$c->res->header('X-Custom' => "foo\r\nSet-Cookie: evil=value");
# Results in response splitting - injecting arbitrary headers
```

**Impact:**
- HTTP Response Splitting attacks
- Cache poisoning
- Session hijacking via injected Set-Cookie
- XSS via injected Content-Type

**Recommended Fix:**
```perl
sub _validate_header_value ($value) {
    die "Invalid header value: contains CRLF" if $value =~ /[\r\n]/;
    die "Invalid header value: contains null" if $value =~ /\0/;
    return $value;
}

for my $header (@$headers) {
    my ($name, $value) = @$header;
    $name = _validate_header_name($name);
    $value = _validate_header_value($value);
    $response .= "$name: $value\r\n";
}
```

---

### 1.3 Header Injection in WebSocket Custom Headers

**Status:** FIXED (2024-12-14)
**File:** `lib/PAGI/Server/Connection.pm`
**Lines:** 1429-1437

**Problem:**
WebSocket handshake allows arbitrary headers without validation.

**Current Code:**
```perl
# Connection.pm around line 1375-1381
if (my $extra_headers = $event->{headers}) {
    for my $h (@$extra_headers) {
        my ($name, $value) = @$h;
        push @headers, "$name: $value\r\n";  # NO VALIDATION
    }
}
```

**Impact:**
Same as HTTP header injection - response splitting, cache poisoning.

**Recommended Fix:**
Apply same header validation as HTTP responses.

---

### 1.4 WebSocket Subprotocol Header Injection

**Status:** FIXED (2024-12-14)
**File:** `lib/PAGI/Server/Connection.pm`
**Lines:** 1423-1427

**Problem:**
Subprotocol value passed directly to header without validation.

**Current Code:**
```perl
# Connection.pm line 1372
if (my $subprotocol = $event->{subprotocol}) {
    push @headers, "Sec-WebSocket-Protocol: $subprotocol\r\n";
}
```

**Recommended Fix:**
```perl
if (my $subprotocol = $event->{subprotocol}) {
    die "Invalid subprotocol" unless $subprotocol =~ /^[\w\-\.]+$/;
    push @headers, "Sec-WebSocket-Protocol: $subprotocol\r\n";
}
```

---

### 1.5 Trailer Header Injection

**Status:** FIXED (2024-12-14)
**File:** `lib/PAGI/Server/Protocol/HTTP1.pm`
**Lines:** 294-304

**Problem:**
Chunked encoding trailer headers not validated.

**Current Code:**
```perl
# Protocol/HTTP1.pm lines 267-275
sub serialize_trailers ($self, $headers) {
    my $trailers = '';
    for my $header (@$headers) {
        my ($name, $value) = @$header;
        $trailers .= "$name: $value\r\n";  # NO VALIDATION
    }
    return $trailers . "\r\n";
}
```

**Recommended Fix:**
Apply same header validation function.

---

### 1.6 ~~Infinite Loop on Malformed Chunked Request~~

**Status:** NOT AN ISSUE (removed from audit 2024-12-14)

**Original Concern:**
Claimed that malformed chunked data would cause infinite loop.

**Why It's Not An Issue:**
Upon investigation, the server handles this correctly:

1. **Client closes connection:** EOF is detected immediately (Connection.pm line 173-175),
   triggering `_handle_disconnect` for immediate cleanup.

2. **Client keeps connection open:** The 60-second idle timeout (Connection.pm line 97, 147-160)
   ensures stale connections are eventually closed.

3. **Async awaits:** The `await $receive_pending` resolves when either new data arrives
   or the connection closes - it does not block indefinitely.

This is normal, correct server behavior for handling incomplete requests.

---

## 2. High Severity Issues

### 2.1 Chunk Size Parsing Not Validated

**Status:** FIXED (2024-12-14)
**File:** `lib/PAGI/Server/Protocol/HTTP1.pm`
**Lines:** 344-354

**Problem:**
Chunk size is parsed with `hex()` which silently accepts invalid input.

**Current Code:**
```perl
# Protocol/HTTP1.pm lines 316-318
my $size_line = substr($buffer, $total_consumed, $crlf - $total_consumed);
$size_line =~ s/;.*//;  # Remove chunk extensions
my $chunk_size = hex($size_line);  # hex("xyz") returns 0, no error!
```

**Impact:**
- `hex("")` returns 0 - empty size line treated as end of body
- `hex("garbage")` returns 0 - invalid data silently accepted
- Could be used to truncate request body or bypass validation

**Recommended Fix:**
```perl
my $size_line = substr($buffer, $total_consumed, $crlf - $total_consumed);
$size_line =~ s/;.*//;  # Remove chunk extensions
$size_line =~ s/^\s+|\s+$//g;  # Trim whitespace

unless ($size_line =~ /^[0-9a-fA-F]+$/) {
    return { error => 400, message => "Invalid chunk size" };
}

my $chunk_size = hex($size_line);
```

---

### 2.2 ~~Lifespan Exception Misclassification~~

**Status:** NOT AN ISSUE (removed from audit 2024-12-14)

**Original Concern:**
Claimed that lifespan exceptions could cause server to start with broken state.

**Why It's Not An Issue:**
Upon investigation, the server handles this correctly:

1. **Single-worker mode** (lines 240-245): Checks `!$startup_result->{success}` and dies
   with "Lifespan startup failed" message, preventing server from starting.

2. **Multi-worker mode** (lines 478-495): Checks `!$startup_result->{success}`, sets
   `$startup_error`, and calls `exit(1)` to terminate the worker.

The code at lines 632-635 correctly sets `success => 0` for non-lifespan exceptions,
and the callers properly check this and refuse to start.

---

### 2.3 Worker Startup Exception Not Properly Handled

**Status:** FIXED (2024-12-14)
**File:** `lib/PAGI/Server.pm`
**Lines:** 413-437, 492-495

**Problem:**
Worker process continues even if lifespan startup fails; parent can't distinguish startup failure from runtime crash.

**Current Code:**
```perl
# Server.pm lines 475-487
eval {
    my $startup_result = await $worker_server->_run_lifespan_startup;
    # ...
};
if ($@) {
    $startup_error = $@;
}
$startup_done = 1;
$loop->stop if $startup_error;  # Stops loop but exit code is 1
```

**Impact:**
- Worker respawn loop if startup always fails
- Parent spawns new workers that immediately die
- Resource exhaustion

**Recommended Fix:**
```perl
if ($@) {
    warn "[Worker $worker_num] Startup failed: $@\n";
    exit(2);  # Distinct exit code for startup failure
}
# In parent's watch_process callback:
if ($exitcode == 2) {
    warn "Worker $worker_num startup failed, not respawning\n";
    return;  # Don't respawn on startup failure
}
```

---

### 2.4 No Graceful Shutdown for Active Requests

**Status:** FIXED (2024-12-14)
**File:** `lib/PAGI/Server.pm`
**Lines:** 691-745

**Problem:**
During shutdown, workers were killed immediately with SIGTERM, aborting active requests.

**Fix Applied:**
1. Added `shutdown_timeout` configuration option (default 30 seconds)
2. Modified `shutdown()` method to wait for active connections to drain
3. Added `_drain_connections()` method that polls until connections array is empty
4. After timeout, remaining connections are force-closed

**Implementation:**
```perl
# New _drain_connections method waits for active requests
async sub _drain_connections ($self) {
    my $timeout = $self->{shutdown_timeout} // 30;
    my $start = time();
    my $loop = $self->loop;

    while (@{$self->{connections}} > 0) {
        my $elapsed = time() - $start;
        if ($elapsed >= $timeout) {
            # Force close remaining connections
            for my $conn (@{$self->{connections}}) {
                $conn->_close if $conn && $conn->can('_close');
            }
            last;
        }
        await $loop->delay_future(after => 0.1);
    }
}
```

**Test:** `t/18-graceful-shutdown.t`

---

### 2.5 Worker Respawn Race Condition

**Status:** FIXED (2024-12-14)
**File:** `lib/PAGI/Server.pm`
**Lines:** 478-501

**Original Problem:**
Child process exit callback uses weak reference that might be garbage collected during shutdown.

**Why It's Fixed:**
The current implementation correctly handles this:

1. **Weak ref protection:** `return unless $weak_self` prevents use-after-free crashes
2. **Shutdown flag:** `!$weak_self->{shutting_down}` check prevents respawning during shutdown
3. **Proper termination:** Loop stops when all workers exit and `shutting_down` is set
4. **Startup failure handling:** Exit code 2 prevents infinite respawn loops

The theoretical edge case (Server destroyed while loop running) doesn't occur in normal usage because Runner keeps Server alive until `$loop->run` returns.

---

## 3. Medium Severity Issues

### 3.1 WebSocket Frame Parser Memory Leak

**Status:** NOT FIXED
**File:** `lib/PAGI/Server/Connection.pm`
**Line:** 1390

**Problem:**
WebSocket frame parser accumulates state and is never explicitly freed.

**Current Code:**
```perl
# Connection.pm line 1390
$weak_self->{websocket_frame} = Protocol::WebSocket::Frame->new;
# Never cleared in _close()
```

**Recommended Fix:**
In `_close()` method, add:
```perl
delete $self->{websocket_frame};
```

---

### 3.2 Connection Not Removed from List on Exception

**Status:** NOT FIXED
**File:** `lib/PAGI/Server/Connection.pm`
**Lines:** 276-284

**Problem:**
If application throws exception, connection object stays in server's connection list.

**Current Code:**
```perl
# Connection.pm lines 276-284
eval {
    await $self->{app}->($scope, $receive, $send);
};
if (my $error = $@) {
    $self->_send_error_response(500, "Internal Server Error");
    warn "PAGI application error: $error\n";
}
# Connection might not be closed/removed
```

**Recommended Fix:**
```perl
eval {
    await $self->{app}->($scope, $receive, $send);
};
if (my $error = $@) {
    $self->_send_error_response(500, "Internal Server Error");
    warn "PAGI application error: $error\n";
    $self->_close();  # Ensure cleanup
    return;
}
```

---

### 3.3 Receive Queue Unbounded

**Status:** FIXED (2024-12-14)
**File:** `lib/PAGI/Server.pm`, `lib/PAGI/Server/Connection.pm`

**Original Problem:**
WebSocket receive queue had no size limit; malicious client could exhaust memory by sending messages faster than the app consumed them.

**Fix Applied:**

1. Added `max_receive_queue` configuration option (default: 1000 messages)
2. Queue limit checked before adding each WebSocket text/binary frame
3. When exceeded, server sends close frame with code 1008 (Policy Violation) and reason "Message queue overflow"

**Configuration:**
```perl
# Programmatic
my $server = PAGI::Server->new(
    app               => $app,
    max_receive_queue => 500,  # Limit queue to 500 messages
);

# CLI
pagi-server --max-receive-queue 500 ./app.pl
```

**Implementation:**
```perl
# Connection.pm - check before each push to receive_queue
if (@{$self->{receive_queue}} >= $self->{max_receive_queue}) {
    $self->_send_close_frame(1008, 'Message queue overflow');
    $self->_close;
    return;
}
push @{$self->{receive_queue}}, { type => 'websocket.receive', ... };
```

**Documentation:** Full tuning guidelines in `PAGI::Server` POD including memory impact calculations.

**Test:** `t/19-receive-queue-limit.t`

---

### 3.4 Negative Buffer Index in Chunked Parsing

**Status:** NOT AN ISSUE (Verified 2024-12-14)
**File:** `lib/PAGI/Server/Protocol/HTTP1.pm`
**Line:** 316

**Problem:**
If `$crlf < $total_consumed`, substr gets negative length.

**Verification:**
The existing code already has `last if $crlf < 0;` on line 309 before accessing the buffer.
This check handles all cases where `$crlf` would be negative or less than `$total_consumed`
because `index()` returns -1 when the pattern is not found. When the CRLF is found,
`$crlf` is always >= `$total_consumed` since we start searching from that position.

**Conclusion:** No fix required - already properly handled.

---

### 3.5 Uncaught Exception in Connection Callback

**Status:** FIXED (2024-12-14)
**File:** `lib/PAGI/Server/Connection.pm`
**Lines:** 179-202

**Problem:**
on_read callback didn't wrap `_try_handle_request()` and `_process_websocket_frames()` in eval.
Exceptions from Protocol::WebSocket::Frame (e.g., oversized payload) would propagate up through
IO::Async's event loop, potentially crashing the server.

**Fix Applied:**
```perl
on_read => sub ($s, $buffref, $eof) {
    return 0 unless $weak_self;
    # ... buffer handling ...

    # Wrap processing in eval to prevent exceptions from crashing the event loop
    eval {
        if ($weak_self->{websocket_mode}) {
            $weak_self->_process_websocket_frames;
            return;
        }
        # ... other processing ...
        $weak_self->_try_handle_request;
    };
    if (my $error = $@) {
        warn "PAGI connection error: $error";
        $weak_self->_close;
    }
    return 0;
},
```

**Additional Enhancement:**
Added configurable `max_ws_frame_size` option (default 65536 bytes) which allows limiting
WebSocket frame payload size. This works with Protocol::WebSocket::Frame's max_payload_size
parameter to reject oversized frames before they can cause issues.

**Configuration:**
- `PAGI::Server->new(max_ws_frame_size => 1048576)` - 1MB limit
- CLI: `pagi-server --max-ws-frame-size 1048576`

**Test:** `t/20-callback-exception.t`

---

### 3.6 TLS Info Extraction Silent Failures

**Status:** FIXED (2024-12-14)
**File:** `lib/PAGI/Server/Connection.pm`
**Lines:** 950-1024

**Problem:**
Multiple eval blocks swallow errors silently, making TLS debugging impossible.

**Fix Applied:**
Added error logging and storage for all three TLS extraction blocks:

```perl
# Cipher suite extraction
eval { ... };
if ($@) {
    warn "TLS cipher suite extraction error: $@\n";
    $tls_info->{cipher_extraction_error} = $@;
}

# Server certificate extraction
eval { ... };
if ($@) {
    warn "TLS server certificate extraction error: $@\n";
    $tls_info->{server_cert_error} = $@;
}

# Client certificate extraction
eval { ... };
if ($@) {
    warn "TLS client certificate extraction error: $@\n";
    $tls_info->{client_cert_extraction_error} = $@;
}
```

Errors are now:
1. Logged to STDERR with `warn` for visibility
2. Stored in `$tls_info` for programmatic access

---

### 3.7 No Minimum TLS Version

**Status:** FIXED (2024-12-14)
**File:** `lib/PAGI/Server.pm`
**Lines:** 320-321

**Original Problem:**
Server may accept SSLv3, TLS 1.0, or TLS 1.1 (all deprecated/insecure).

**Fix Applied:**
```perl
# TLS hardening: minimum version TLS 1.2 (configurable)
$listen_opts{SSL_version} = $ssl->{min_version} // 'TLSv1_2';
```

Users can override with `ssl => { min_version => 'TLSv1_3' }` if desired.

**Test:** `t/08-tls.t` - "TLS 1.2 minimum version is enforced by default"

---

### 3.8 No Cipher Suite Restrictions

**Status:** FIXED (2024-12-14)
**File:** `lib/PAGI/Server.pm`
**Lines:** 323-325

**Original Problem:**
No cipher restrictions; may use weak ciphers.

**Fix Applied:**
```perl
# TLS hardening: secure cipher suites (configurable)
$listen_opts{SSL_cipher_list} = $ssl->{cipher_list} //
    'ECDHE+AESGCM:DHE+AESGCM:ECDHE+CHACHA20:!aNULL:!eNULL:!EXPORT:!DES:!RC4:!MD5:!PSK:!aECDH:!EDH-DSS-DES-CBC3-SHA:!KRB5-DES-CBC3-SHA';
```

Users can override with `ssl => { cipher_list => 'CUSTOM:CIPHER:LIST' }` if desired.

**Test:** `t/08-tls.t` - "Custom TLS min_version and cipher_list are configurable"

---

### 3.9 Client Certificate Verification Not Enforced

**Status:** FIXED (2024-12-14)
**File:** `lib/PAGI/Server.pm`
**Lines:** 327-331

**Original Problem:**
`SSL_VERIFY_PEER` alone doesn't require client cert.

**Fix Applied:**
```perl
# Client certificate verification
if ($ssl->{verify_client}) {
    # SSL_VERIFY_PEER (0x01) | SSL_VERIFY_FAIL_IF_NO_PEER_CERT (0x02)
    $listen_opts{SSL_verify_mode} = 0x03;
    $listen_opts{SSL_ca_file} = $ssl->{ca_file} if $ssl->{ca_file};
}
```

**Test:** `t/08-tls.t` - "verify_client requires client certificate"

---

### 3.10 Inefficient Connection Cleanup O(N²)

**Status:** FIXED (2024-12-14)
**File:** `lib/PAGI/Server.pm`, `lib/PAGI/Server/Connection.pm`

**Problem:**
Closing connection used O(N) array filter; closing all was O(N²).

**Fix Applied:**
Changed `$self->{connections}` from array to hash keyed by `refaddr($conn)`:
```perl
# Server.pm - O(1) insert
$self->{connections}{refaddr($conn)} = $conn;

# Connection.pm - O(1) delete
delete $self->{server}{connections}{refaddr($self)};
```

At 500 concurrent connections, this eliminates significant overhead on every request completion.

---

### 3.11 Large WebSocket Frames Not Streamed

**Status:** NOT FIXED
**File:** `lib/PAGI/Server/Connection.pm`
**Lines:** 1464-1465

**Problem:**
Entire WebSocket message must fit in memory.

**Current Code:**
```perl
# Connection.pm lines 1464-1465
$frame->append($self->{buffer});
$self->{buffer} = '';
```

**Impact:**
Large WebSocket frames cause memory spikes; potential DoS.

**Recommended Fix:**
Add configurable max frame size and reject oversized frames:
```perl
my $MAX_WEBSOCKET_FRAME = 1024 * 1024;  # 1MB

if (length($self->{buffer}) > $MAX_WEBSOCKET_FRAME) {
    $self->_send_close_frame(1009, 'Message too large');
    $self->_close();
    return;
}
```

---

### 3.12 Content-Length Integer Overflow

**Status:** FIXED (2024-12-15)
**File:** `lib/PAGI/Server/Protocol/HTTP1.pm`
**Lines:** 229-245

**Problem:**
Content-Length converted without validation; negative, non-numeric, and overflow values silently accepted.

**Fix Applied:**
```perl
if (defined $env{CONTENT_LENGTH}) {
    my $cl_value = $env{CONTENT_LENGTH};

    # RFC 7230 Section 3.3.2: Content-Length = 1*DIGIT
    # Must be only digits, no whitespace, no negative sign
    if ($cl_value !~ /^\d+$/) {
        return ({ error => 400, message => 'Bad Request' }, $header_end + 4);
    }

    # Check for unreasonably large values (>2GB indicates potential DoS)
    if (length($cl_value) > 10 || $cl_value > 2_147_483_647) {
        return ({ error => 413, message => 'Payload Too Large' }, $header_end + 4);
    }

    push @headers, ['content-length', $cl_value];
    $content_length = $cl_value + 0;
}
```

**Test:** `t/22-content-length-keepalive.t`

---

### 3.13 Worker File Descriptor Leak

**Status:** NOT FIXED
**File:** `lib/PAGI/Server.pm`
**Lines:** 435-516

**Problem:**
Listen socket not closed before worker exits.

**Current Code:**
```perl
# Server.pm _run_as_worker
sub _run_as_worker ($self, $listen_socket, $worker_num) {
    # ...
    $loop->run;
    exit(0);  # Socket still open
}
```

**Recommended Fix:**
```perl
$loop->run;
close($listen_socket);
exit(0);
```

---

### 3.14 Parent Doesn't Wait for Workers (Zombies)

**Status:** NOT FIXED
**File:** `lib/PAGI/Server.pm`
**Lines:** 379-381

**Problem:**
Parent sends SIGTERM but doesn't wait, potentially leaving zombies.

**Recommended Fix:**
See graceful shutdown fix in 2.4 - includes waiting for workers.

---

### 3.15 HTTP/1.0 Keep-Alive Not Advertised

**Status:** FIXED (2024-12-15)
**File:** `lib/PAGI/Server/Connection.pm`
**Lines:** 631-640, 677-686

**Problem:**
Server accepts HTTP/1.0 keep-alive but doesn't send `Connection: keep-alive` header back.
Per HTTP/1.0 spec, keep-alive is not default; clients won't reuse the connection without
explicit acknowledgment.

**Fix Applied:**
```perl
# In _create_send(), check if HTTP/1.0 client requested keep-alive
my $client_wants_keepalive = 0;
if ($is_http10) {
    for my $h (@{$request->{headers}}) {
        if ($h->[0] eq 'connection' && lc($h->[1]) =~ /keep-alive/) {
            $client_wants_keepalive = 1;
            last;
        }
    }
}

# When building response headers:
if ($is_http10) {
    if (!$has_content_length) {
        # No Content-Length means we can't do keep-alive
        push @final_headers, ['connection', 'close'];
    } elsif ($client_wants_keepalive) {
        # HTTP/1.0 client requested keep-alive and we can honor it
        push @final_headers, ['connection', 'keep-alive'];
    }
}
```

**Test:** `t/22-content-length-keepalive.t`

---

### 3.16 No Request Line Length Limit

**Status:** FIXED (2024-12-14)
**File:** `lib/PAGI/Server/Protocol/HTTP1.pm`
**Lines:** 149-153

**Problem:**
Only header block size is limited, not individual request line.

**Fix Applied:**
```perl
# Check request line length (first line before \r\n)
my $first_line_end = index($buffer, "\r\n");
if ($first_line_end > $self->{max_request_line_size}) {
    return ({ error => 414, message => 'URI Too Long' }, $header_end + 4);
}
```

Default limit is 8KB per RFC 7230 recommendation. Configurable via constructor.

**Test:** `t/21-quick-wins.t`

---

### 3.17 Application Error After Response Started

**Status:** NOT FIXED
**File:** `lib/PAGI/Server/Connection.pm`
**Lines:** 276-284

**Problem:**
If app throws after `http.response.start`, error response can't be sent (already started).

**Current Code:**
```perl
if (my $error = $@) {
    $self->_send_error_response(500, "Internal Server Error");
    # _send_error_response returns early if response already started
}
```

**Recommended Fix:**
Track response state and handle appropriately:
```perl
if (my $error = $@) {
    if ($self->{response_started}) {
        # Can't send error page - just close connection
        warn "Application error after response started: $error\n";
        $self->_close();
    } else {
        $self->_send_error_response(500, "Internal Server Error");
    }
}
```

---

## 4. Low Severity Issues

### 4.1 TLS Certificate Data Stored for Connection Lifetime

**Status:** NOT FIXED
**File:** `lib/PAGI/Server/Connection.pm`
**Lines:** 887-934

**Problem:**
Full certificate PEM data stored in memory per connection.

**Recommended Fix:**
Store only fingerprint/hash:
```perl
$tls_info->{server_cert_fingerprint} = sha256_hex($cert_der);
# Instead of full PEM
```

---

### 4.2 Missing Server Header

**Status:** FIXED (2024-12-14)
**File:** `lib/PAGI/Server/Protocol/HTTP1.pm`
**Lines:** 259-271

**Problem:**
No Server header in responses.

**Fix Applied:**
```perl
# Check if app provided a Server header
my $has_server = 0;
for my $header (@$headers) {
    if (lc($header->[0]) eq 'server') {
        $has_server = 1;
        last;
    }
}

# Add default Server header if not provided
unless ($has_server) {
    $response .= "Server: PAGI/$VERSION\r\n";
}
```

Applications can override by providing their own Server header.

**Test:** `t/21-quick-wins.t`

---

### 4.3 ~~Inefficient Header Concatenation~~

**Status:** NOT AN ISSUE (Verified 2024-12-15)
**File:** `lib/PAGI/Server/Protocol/HTTP1.pm`
**Lines:** 274-279

**Original Concern:**
String concatenation in loop claimed to have minor performance impact.

**Why It's Not An Issue:**
Perl strings are mutable and Perl over-allocates memory to amortize the cost of
concatenation. Unlike languages with immutable strings (Java, Python), repeated
`.=` operations in Perl don't create new string objects each time.

For typical HTTP responses:
- Headers count: <20 items
- Total header size: <2KB
- This runs once per response, not in a hot loop

The alternative (push to array + join) would have similar or worse overhead due to:
1. Array push operations
2. Final join() traversing the array
3. Additional temporary string allocation for join result

**Conclusion:** This is premature optimization. The current code is clear and performs
fine for typical HTTP responses. No fix required.

---

### 4.4 Certificate Files Not Validated at Startup

**Status:** FIXED (2024-12-14)
**File:** `lib/PAGI/Server.pm`
**Lines:** 265-279

**Problem:**
Certificate/key files validated at listen time, not at startup.

**Fix Applied:**
```perl
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
```

Validates cert_file, key_file, and ca_file existence and readability in constructor.

**Test:** `t/21-quick-wins.t`

---

## 5. Summary and Priority Order

### Fix Order Recommendation

**Phase 1 - Critical Security (Do First):**
1. [1.1] Implement `_send_close_frame()` - prevents crashes
2. [1.2-1.5] Add header validation for CRLF injection - security critical
3. [1.6] Fix infinite loop on malformed chunked - DoS prevention

**Phase 2 - High Severity:**
4. [2.1] Validate chunk size hex parsing
5. [2.4] Implement graceful shutdown
6. [2.2-2.3] Fix lifespan/worker exception handling

**Phase 3 - Medium Security/Stability:**
7. [3.7-3.9] TLS hardening (version, ciphers, client cert)
8. [3.3] Bound receive queue size
9. [3.4-3.5] Fix parsing edge cases and exception handling

**Phase 4 - Medium Performance/Cleanup:**
10. [3.10] Connection cleanup performance
11. [3.11] WebSocket frame size limit
12. [3.1-3.2] Memory leak fixes

**Phase 5 - Low Priority:**
13. Remaining low severity items

### Quick Reference

| ID | Severity | Category | One-Line Description |
|----|----------|----------|---------------------|
| 1.1 | CRITICAL | Crash | ~~Missing _send_close_frame() method~~ FIXED |
| 1.2 | CRITICAL | Security | HTTP header CRLF injection |
| 1.3 | CRITICAL | Security | WebSocket header CRLF injection |
| 1.4 | CRITICAL | Security | Subprotocol header injection |
| 1.5 | CRITICAL | Security | Trailer header injection |
| 1.6 | CRITICAL | DoS | Infinite loop on malformed chunked |
| 2.1 | HIGH | Security | Chunk size hex validation |
| 2.2 | HIGH | Stability | Lifespan exception handling |
| 2.3 | HIGH | Stability | Worker startup exceptions |
| 2.4 | HIGH | Stability | No graceful shutdown |
| 2.5 | HIGH | Stability | Worker respawn race |
| 3.1 | MEDIUM | Memory | WebSocket parser leak |
| 3.2 | MEDIUM | Memory | Connection list cleanup |
| 3.3 | MEDIUM | DoS | Unbounded receive queue |
| 3.4 | MEDIUM | Crash | Negative buffer index |
| 3.5 | MEDIUM | Crash | Uncaught callback exception |
| 3.6 | MEDIUM | Debug | Silent TLS errors |
| 3.7 | MEDIUM | Security | No minimum TLS version |
| 3.8 | MEDIUM | Security | No cipher restrictions |
| 3.9 | MEDIUM | Security | Client cert not enforced |
| 3.10 | MEDIUM | Perf | O(N²) connection cleanup |
| 3.11 | MEDIUM | DoS | Large WebSocket frames |
| 3.12 | MEDIUM | Security | ~~Content-Length overflow~~ FIXED |
| 3.13 | MEDIUM | Resource | Worker FD leak |
| 3.14 | MEDIUM | Resource | Zombie workers |
| 3.15 | MEDIUM | Compat | ~~HTTP/1.0 keep-alive~~ FIXED |
| 3.16 | MEDIUM | DoS | ~~No request line limit~~ FIXED |
| 3.17 | MEDIUM | Stability | Error after response start |
| 4.1 | LOW | Memory | TLS cert data storage |
| 4.2 | LOW | Compat | ~~Missing Server header~~ FIXED |
| 4.3 | LOW | Perf | ~~String concatenation~~ NOT AN ISSUE |
| 4.4 | LOW | UX | ~~Deferred cert validation~~ FIXED |

---

## Notes for Future Sessions

When resuming work on these issues:

1. Start by reading this document and the specific section for the issue
2. The code locations are exact as of 2024-12-14; line numbers may shift if other changes made
3. Each fix should include a test case in `t/` directory
4. Run `prove -l t/` after each fix to ensure no regressions
5. Consider adding fuzz testing for HTTP parsing after security fixes
