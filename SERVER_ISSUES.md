# PAGI::Server Production Readiness Audit

This document contains a comprehensive audit of PAGI::Server identifying issues that should be addressed before production deployment. Each issue includes the exact file location, code snippets, risk assessment, and recommended fix.

**Audit Date:** 2024-12-14
**Files Audited:** `lib/PAGI/Server.pm`, `lib/PAGI/Server/*.pm`
**Total Issues Found:** 31 (6 Critical, 4 High, 17 Medium, 4 Low)
**Issues Fixed:** 5 (1.1-1.5)

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

### 1.6 Infinite Loop on Malformed Chunked Request

**Status:** NOT FIXED
**File:** `lib/PAGI/Server/Connection.pm`
**Lines:** 500-540 (approximate)

**Problem:**
If `parse_chunked_body()` repeatedly returns `(undef, 0, 0)` for malformed data, the receive handler loops forever waiting for more data that won't help.

**Current Code:**
```perl
# Simplified flow in Connection.pm chunked body handling
while (1) {
    my ($data, $consumed, $complete) = $protocol->parse_chunked_body($buffer);

    if ($consumed > 0) {
        # Process data...
    }

    # Need more data - wait for it
    await $receive_pending;  # LOOPS FOREVER if parse always fails
}
```

**Impact:**
- DoS: Send malformed chunked body, connection hangs forever
- Resource exhaustion as connections accumulate

**Recommended Fix:**
```perl
my $parse_attempts = 0;
my $max_parse_attempts = 100;

while (1) {
    my ($data, $consumed, $complete) = $protocol->parse_chunked_body($buffer);

    if ($consumed > 0) {
        $parse_attempts = 0;  # Reset on progress
        # Process data...
    } else {
        $parse_attempts++;
        if ($parse_attempts > $max_parse_attempts) {
            $self->_send_error_response(400, "Malformed chunked encoding");
            $self->_close();
            return;
        }
    }
    # ...
}
```

---

## 2. High Severity Issues

### 2.1 Chunk Size Parsing Not Validated

**Status:** NOT FIXED
**File:** `lib/PAGI/Server/Protocol/HTTP1.pm`
**Lines:** 316-318

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

### 2.2 Lifespan Exception Misclassification

**Status:** NOT FIXED
**File:** `lib/PAGI/Server.pm`
**Lines:** 618-639

**Problem:**
If lifespan app throws an exception not matching a specific pattern, server may start with broken state.

**Current Code:**
```perl
# Server.pm lines 618-639
if (my $error = $@) {
    $lifespan_supported = 0;
    if (!$startup_complete->is_ready) {
        if ($error =~ /unsupported.*scope.*type|unsupported.*lifespan/i) {
            # Treat as "lifespan not supported" - OK
            $startup_complete->done({ success => 1, lifespan_supported => 0 });
        }
        else {
            warn "PAGI lifespan handler error: $error\n";
            $startup_complete->done({ success => 0, message => "Exception: $error" });
        }
    }
}
```

**Impact:**
- Database connection failure in startup hook could be mishandled
- Server starts despite initialization failure
- Requests fail with confusing errors

**Recommended Fix:**
```perl
if (my $error = $@) {
    $lifespan_supported = 0;
    if (!$startup_complete->is_ready) {
        if ($error =~ /unsupported.*scope.*type|unsupported.*lifespan/i) {
            $startup_complete->done({ success => 1, lifespan_supported => 0 });
        }
        else {
            require Carp;
            Carp::cluck("PAGI lifespan handler fatal error: $error");
            $startup_complete->done({
                success => 0,
                message => "Exception: $error",
                fatal => 1  # Mark as fatal
            });
        }
    }
}
```

---

### 2.3 Worker Startup Exception Not Properly Handled

**Status:** NOT FIXED
**File:** `lib/PAGI/Server.pm`
**Lines:** 475-487

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

**Status:** NOT FIXED
**File:** `lib/PAGI/Server.pm`
**Lines:** 367-388

**Problem:**
During shutdown, workers are killed immediately with SIGTERM, aborting active requests.

**Current Code:**
```perl
# Server.pm lines 367-388 (_initiate_multiworker_shutdown)
if ($self->{listen_socket}) {
    close($self->{listen_socket});
    delete $self->{listen_socket};
}

for my $pid (keys %{$self->{worker_pids}}) {
    kill 'TERM', $pid;  # Immediate kill
}
```

**Impact:**
- Active HTTP requests get connection reset
- WebSocket connections dropped mid-message
- Clients see 500 errors during deployment

**Recommended Fix:**
```perl
sub _initiate_multiworker_shutdown ($self) {
    return if $self->{shutting_down};
    $self->{shutting_down} = 1;

    # 1. Stop accepting new connections
    if ($self->{listen_socket}) {
        close($self->{listen_socket});
        delete $self->{listen_socket};
    }

    # 2. Send SIGTERM for graceful shutdown
    for my $pid (keys %{$self->{worker_pids}}) {
        kill 'TERM', $pid;
    }

    # 3. Wait up to 30 seconds for graceful exit
    my $grace_period = 30;
    my $waited = 0;

    $self->loop->watch_time(
        after => 1,
        interval => 1,
        code => sub {
            $waited++;
            if (!keys %{$self->{worker_pids}}) {
                $self->loop->stop;
                return;
            }
            if ($waited >= $grace_period) {
                # Force kill remaining workers
                for my $pid (keys %{$self->{worker_pids}}) {
                    kill 'KILL', $pid;
                }
                $self->loop->stop;
            }
        },
    );
}
```

---

### 2.5 Worker Respawn Race Condition

**Status:** NOT FIXED
**File:** `lib/PAGI/Server.pm`
**Lines:** 414-430

**Problem:**
Child process exit callback uses weak reference that might be garbage collected during shutdown.

**Current Code:**
```perl
# Server.pm lines 414-430
$loop->watch_process($pid => sub {
    my ($exit_pid, $exitcode) = @_;
    return unless $weak_self;  # Weak ref check

    delete $weak_self->{worker_pids}{$exit_pid};

    if ($weak_self->{running} && !$weak_self->{shutting_down}) {
        $weak_self->_spawn_worker($listen_socket, $worker_num);
    }
});
```

**Impact:**
- Potential use-after-free if callback fires during destruction
- Currently mitigated by weak ref check, but shutdown sequence unclear

**Recommended Fix:**
Add explicit cleanup of watch_process callbacks during shutdown.

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

**Status:** NOT FIXED
**File:** `lib/PAGI/Server/Connection.pm`
**Lines:** 74, 407-408

**Problem:**
Receive queue has no size limit; malicious client can exhaust memory.

**Current Code:**
```perl
# Connection.pm line 74
receive_queue => [],  # No limit

# Lines 407-408
push @{$weak_self->{receive_queue}}, $event;
```

**Recommended Fix:**
```perl
my $MAX_RECEIVE_QUEUE = 100;

# When adding to queue:
if (@{$weak_self->{receive_queue}} >= $MAX_RECEIVE_QUEUE) {
    warn "Receive queue overflow, closing connection\n";
    $weak_self->_close();
    return;
}
push @{$weak_self->{receive_queue}}, $event;
```

---

### 3.4 Negative Buffer Index in Chunked Parsing

**Status:** NOT FIXED
**File:** `lib/PAGI/Server/Protocol/HTTP1.pm`
**Line:** 316

**Problem:**
If `$crlf < $total_consumed`, substr gets negative length.

**Current Code:**
```perl
# Protocol/HTTP1.pm line 316
my $size_line = substr($buffer, $total_consumed, $crlf - $total_consumed);
# If $crlf < $total_consumed, this is negative length - undefined behavior
```

**Recommended Fix:**
```perl
my $crlf = index($buffer, "\r\n", $total_consumed);
last if $crlf < 0;
last if $crlf < $total_consumed;  # Add this check
my $size_line = substr($buffer, $total_consumed, $crlf - $total_consumed);
```

---

### 3.5 Uncaught Exception in Connection Callback

**Status:** NOT FIXED
**File:** `lib/PAGI/Server/Connection.pm`
**Lines:** 130-164

**Problem:**
on_read callback doesn't wrap `_try_handle_request()` in eval.

**Current Code:**
```perl
# Connection.pm lines 130-164
on_read => sub ($s, $buffref, $eof) {
    # ...
    $weak_self->_try_handle_request;  # No try/catch
    return 0;
},
```

**Recommended Fix:**
```perl
on_read => sub ($s, $buffref, $eof) {
    return 0 unless $weak_self;
    eval {
        # ... existing code ...
        $weak_self->_try_handle_request;
    };
    if ($@) {
        warn "Connection callback error: $@\n";
        $weak_self->_close() if $weak_self;
    }
    return 0;
},
```

---

### 3.6 TLS Info Extraction Silent Failures

**Status:** NOT FIXED
**File:** `lib/PAGI/Server/Connection.pm`
**Lines:** 888-934

**Problem:**
Multiple eval blocks swallow errors silently.

**Current Code:**
```perl
# Connection.pm lines 888-934
eval {
    my $cert = $handle->get_servercert;
    # ... code that might fail ...
};
# No error handling - errors silently ignored
```

**Recommended Fix:**
```perl
eval {
    # ... TLS extraction code ...
};
if ($@) {
    warn "TLS info extraction error: $@\n";
    $tls_info->{extraction_error} = $@;
}
```

---

### 3.7 No Minimum TLS Version

**Status:** NOT FIXED
**File:** `lib/PAGI/Server.pm`
**Lines:** 272-281

**Problem:**
Server may accept SSLv3, TLS 1.0, or TLS 1.1 (all deprecated/insecure).

**Current Code:**
```perl
# Server.pm - no SSL_version specified
$listen_opts{SSL_cert_file} = $ssl->{cert_file};
$listen_opts{SSL_key_file} = $ssl->{key_file};
# Missing: SSL_version
```

**Recommended Fix:**
```perl
$listen_opts{SSL_version} = 'TLSv1_2';  # Minimum TLS 1.2
# Or for TLS 1.3 only:
# $listen_opts{SSL_version} = 'TLSv1_3';
```

---

### 3.8 No Cipher Suite Restrictions

**Status:** NOT FIXED
**File:** `lib/PAGI/Server.pm`
**Lines:** 268-288

**Problem:**
No cipher restrictions; may use weak ciphers.

**Recommended Fix:**
```perl
$listen_opts{SSL_cipher_list} = join(':',
    'ECDHE-RSA-AES256-GCM-SHA384',
    'ECDHE-RSA-AES128-GCM-SHA256',
    'ECDHE-RSA-AES256-SHA384',
    '!aNULL', '!eNULL', '!EXPORT', '!DES', '!RC4', '!MD5'
);
```

---

### 3.9 Client Certificate Verification Not Enforced

**Status:** NOT FIXED
**File:** `lib/PAGI/Server.pm`
**Lines:** 276-281

**Problem:**
`SSL_VERIFY_PEER` alone doesn't require client cert.

**Current Code:**
```perl
if ($ssl->{verify_client}) {
    $listen_opts{SSL_verify_mode} = 0x01;  # SSL_VERIFY_PEER only
}
```

**Recommended Fix:**
```perl
if ($ssl->{verify_client}) {
    # VERIFY_PEER | VERIFY_FAIL_IF_NO_PEER_CERT
    $listen_opts{SSL_verify_mode} = 0x03;
}
```

---

### 3.10 Inefficient Connection Cleanup O(N²)

**Status:** NOT FIXED
**File:** `lib/PAGI/Server/Connection.pm`
**Lines:** 791-792

**Problem:**
Closing connection uses O(N) array filter; closing all is O(N²).

**Current Code:**
```perl
# Connection.pm lines 791-792
@{$self->{server}{connections}} =
    grep { $_ != $self } @{$self->{server}{connections}};
```

**Recommended Fix:**
Use hash instead of array for connections:
```perl
# In Server.pm, change connections from array to hash:
$self->{connections} = {};  # keyed by "$connection" stringification

# In Connection.pm _close():
delete $self->{server}{connections}{"$self"};
```

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

**Status:** NOT FIXED
**File:** `lib/PAGI/Server/Protocol/HTTP1.pm`
**Line:** 198

**Problem:**
Content-Length converted without overflow check.

**Current Code:**
```perl
$content_length = $env{CONTENT_LENGTH} + 0;
```

**Recommended Fix:**
```perl
if ($env{CONTENT_LENGTH} !~ /^\d+$/ || $env{CONTENT_LENGTH} > 2**31) {
    return { error => 400, message => "Invalid Content-Length" };
}
$content_length = $env{CONTENT_LENGTH} + 0;
```

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

**Status:** NOT FIXED
**File:** `lib/PAGI/Server/Connection.pm`
**Lines:** 328-332

**Problem:**
Server accepts HTTP/1.0 keep-alive but doesn't send header back.

**Recommended Fix:**
```perl
# When preparing response for HTTP/1.0 with keep-alive:
if ($http_version eq '1.0' && $keep_alive) {
    push @final_headers, ['connection', 'keep-alive'];
}
```

---

### 3.16 No Request Line Length Limit

**Status:** NOT FIXED
**File:** `lib/PAGI/Server/Protocol/HTTP1.pm`
**Lines:** 114-125

**Problem:**
Only header block size is limited, not individual request line.

**Recommended Fix:**
```perl
my $MAX_REQUEST_LINE = 8192;  # 8KB per RFC 7230 recommendation

my $first_line_end = index($buffer, "\r\n");
if ($first_line_end > $MAX_REQUEST_LINE) {
    return ({ error => 414, message => "URI Too Long" }, 0);
}
```

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

**Status:** NOT FIXED
**File:** `lib/PAGI/Server/Protocol/HTTP1.pm`
**Lines:** 227-230

**Problem:**
No Server header in responses.

**Recommended Fix:**
Add if not present:
```perl
my $has_server = grep { lc($_->[0]) eq 'server' } @$headers;
unless ($has_server) {
    $response .= "Server: PAGI/$VERSION\r\n";
}
```

---

### 4.3 Inefficient Header Concatenation

**Status:** NOT FIXED
**File:** `lib/PAGI/Server/Protocol/HTTP1.pm`
**Lines:** 224-238

**Problem:**
String concatenation in loop; minor performance impact.

**Recommended Fix:**
```perl
my @header_lines;
for my $header (@$headers) {
    push @header_lines, "$header->[0]: $header->[1]";
}
my $response = $status_line . join("\r\n", @header_lines) . "\r\n\r\n";
```

---

### 4.4 Certificate Files Not Validated at Startup

**Status:** NOT FIXED
**File:** `lib/PAGI/Server.pm`
**Lines:** 272-273

**Problem:**
Certificate/key files validated at listen time, not at startup.

**Recommended Fix:**
```perl
if ($ssl->{cert_file}) {
    die "Certificate file not found: $ssl->{cert_file}"
        unless -f $ssl->{cert_file};
    die "Certificate file not readable: $ssl->{cert_file}"
        unless -r $ssl->{cert_file};
}
```

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
| 3.12 | MEDIUM | Security | Content-Length overflow |
| 3.13 | MEDIUM | Resource | Worker FD leak |
| 3.14 | MEDIUM | Resource | Zombie workers |
| 3.15 | MEDIUM | Compat | HTTP/1.0 keep-alive |
| 3.16 | MEDIUM | DoS | No request line limit |
| 3.17 | MEDIUM | Stability | Error after response start |
| 4.1 | LOW | Memory | TLS cert data storage |
| 4.2 | LOW | Compat | Missing Server header |
| 4.3 | LOW | Perf | String concatenation |
| 4.4 | LOW | UX | Deferred cert validation |

---

## Notes for Future Sessions

When resuming work on these issues:

1. Start by reading this document and the specific section for the issue
2. The code locations are exact as of 2024-12-14; line numbers may shift if other changes made
3. Each fix should include a test case in `t/` directory
4. Run `prove -l t/` after each fix to ensure no regressions
5. Consider adding fuzz testing for HTTP parsing after security fixes
