# PAGI::Server Security Hardening Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Fix 6 security vulnerabilities and 4 correctness/compliance issues in PAGI::Server identified by code review on 2026-03-14.

**Architecture:** Fixes are independent — each task can be committed separately. All security fixes follow TDD. Tasks are ordered by severity: security-critical first (S1-S6), then compliance (C1-C2), then correctness (X1-X2). Each task is self-contained.

**Tech Stack:** Perl 5.40, Test2::V0, Future::AsyncAwait, IO::Async

**Perlbrew:** `source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.40.0@default`

---

### Task 1: S1 — Reject requests with both Transfer-Encoding and Content-Length (request smuggling)

RFC 9112 §6.3.3: requests with both `Transfer-Encoding` and `Content-Length` MUST be rejected with 400. This is the canonical CL/TE desync attack vector, especially dangerous behind reverse proxies.

**Files:**
- Modify: `lib/PAGI/Server/Protocol/HTTP1.pm` (in `parse_request`, after header extraction loop ~line 240)
- Test: `t/10-http-compliance.t` (add subtest)

**Step 1: Write the failing test**

Add to `t/10-http-compliance.t` before `done_testing`:

```perl
subtest 'rejects request with both Transfer-Encoding and Content-Length' => sub {
    my $proto = PAGI::Server::Protocol::HTTP1->new;

    my $raw = "POST /test HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\nContent-Length: 10\r\n\r\n";
    my $buf = $raw;
    my ($req, $consumed) = $proto->parse_request(\$buf);

    ok defined $req, 'got a response';
    is $req->{error}, 400, 'returns 400 for CL/TE conflict';
    like $req->{message}, qr/Transfer-Encoding.*Content-Length|Content-Length.*Transfer-Encoding/i,
        'error message mentions both headers';
};
```

**Step 2: Run test to verify it fails**

```bash
bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.40.0@default && prove -l t/10-http-compliance.t :: rejects'
```

Expected: FAIL — currently both headers are accepted

**Step 3: Implement the fix**

In `lib/PAGI/Server/Protocol/HTTP1.pm`, in `parse_request`, after the header extraction loop finishes (after the Content-Length validation block, before constructing the return hash), add:

```perl
    # RFC 9112 Section 6.3.3: reject requests with both Transfer-Encoding
    # and Content-Length to prevent request smuggling (CL/TE desync)
    if ($chunked && defined $content_length) {
        return ({ error => 400, message => 'Transfer-Encoding and Content-Length are mutually exclusive' }, $header_end + 4);
    }
```

This must go AFTER both `$chunked` and `$content_length` have been extracted, but BEFORE the return hash is built.

**Step 4: Run test to verify it passes**

```bash
bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.40.0@default && prove -l t/10-http-compliance.t'
```

Expected: ALL PASS

**Step 5: Commit**

```bash
git add lib/PAGI/Server/Protocol/HTTP1.pm t/10-http-compliance.t
git commit -m "$(cat <<'EOF'
security: reject requests with both Transfer-Encoding and Content-Length

RFC 9112 Section 6.3.3 mandates rejecting requests containing both
headers to prevent CL/TE request smuggling attacks. Returns 400.
EOF
)"
```

---

### Task 2: S2 — Fix arbitrary code execution via string eval in loop_type

`eval "require $loop_class"` allows code injection via `loop_type`. Replace with input validation + block eval.

**Files:**
- Modify: `lib/PAGI/Server.pm` (in `_create_loop`, ~line 1794-1798)
- Test: `t/10-http-compliance.t` (add subtest)

**Step 1: Write the failing test**

Add to `t/10-http-compliance.t`:

```perl
subtest 'rejects invalid loop_type values' => sub {
    like(
        dies {
            PAGI::Server->new(
                app       => async sub { },
                loop_type => 'EPoll; system("echo pwned")',
            )
        },
        qr/Invalid loop_type/,
        'loop_type with semicolon is rejected'
    );

    like(
        dies {
            PAGI::Server->new(
                app       => async sub { },
                loop_type => 'Foo"bar',
            )
        },
        qr/Invalid loop_type/,
        'loop_type with quote is rejected'
    );
};
```

**Step 2: Run test to verify it fails**

```bash
bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.40.0@default && prove -l t/10-http-compliance.t :: invalid.loop_type'
```

Expected: FAIL — currently passes through to string eval

**Step 3: Implement the fix**

In `lib/PAGI/Server.pm`, replace the `_create_loop` method body. Find:

```perl
        my $loop_class = "IO::Async::Loop::$loop_type";
        eval "require $loop_class"
            or die "Cannot load loop backend '$loop_type': $@\n" .
                   "Install it with: cpanm $loop_class\n";
```

Replace with:

```perl
        die "Invalid loop_type '$loop_type': must contain only letters, digits, and ::\n"
            unless $loop_type =~ /\A[A-Za-z][A-Za-z0-9_]*(?:::[A-Za-z][A-Za-z0-9_]*)*\z/;
        my $loop_class = "IO::Async::Loop::$loop_type";
        (my $loop_file = "$loop_class.pm") =~ s{::}{/}g;
        eval { require $loop_file }
            or die "Cannot load loop backend '$loop_type': $@\n" .
                   "Install it with: cpanm $loop_class\n";
```

**Step 4: Run test to verify it passes**

```bash
bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.40.0@default && prove -l t/10-http-compliance.t'
```

Expected: ALL PASS

**Step 5: Commit**

```bash
git add lib/PAGI/Server.pm t/10-http-compliance.t
git commit -m "$(cat <<'EOF'
security: prevent code injection via loop_type parameter

Replace string eval with input validation + require-by-filename.
loop_type must contain only valid Perl module name characters.
EOF
)"
```

---

### Task 3: S3 — Validate trailer headers for CRLF injection

Trailer header names/values bypass the `_validate_header_name`/`_validate_header_value` checks that are applied to normal response headers.

**Files:**
- Modify: `lib/PAGI/Server/Connection.pm` (~line 2448-2458, the `http.response.trailers` branch in `_create_send`)
- Test: `t/15-crlf-injection.t` (add subtest — this file already tests header injection)

**Step 1: Write the failing test**

Add to `t/15-crlf-injection.t`:

```perl
subtest 'trailer header injection is blocked' => sub {
    my $proto = PAGI::Server::Protocol::HTTP1->new;

    # serialize_trailers should reject CRLF in trailer values
    like(
        dies { $proto->serialize_trailers([['x-checksum', "abc\r\nInjected: header"]]) },
        qr/Invalid header value/,
        'CRLF in trailer value is rejected'
    );

    like(
        dies { $proto->serialize_trailers([["bad\r\nname", 'value']]) },
        qr/Invalid header name/,
        'CRLF in trailer name is rejected'
    );

    like(
        dies { $proto->serialize_trailers([["good-name", "has\0null"]]) },
        qr/Invalid header value/,
        'null byte in trailer value is rejected'
    );
};
```

**Step 2: Run test to verify it fails**

```bash
bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.40.0@default && prove -l t/15-crlf-injection.t :: trailer'
```

Expected: FAIL — `serialize_trailers` currently does no validation

**Step 3: Implement the fix**

In `lib/PAGI/Server/Protocol/HTTP1.pm`, find the `serialize_trailers` method. Add validation calls to each trailer header:

Find the loop that builds trailer output (should look like):

```perl
    for my $header (@$headers) {
        my ($name, $value) = @$header;
        $output .= "$name: $value\r\n";
    }
```

Replace with:

```perl
    for my $header (@$headers) {
        my ($name, $value) = @$header;
        $name  = _validate_header_name($name);
        $value = _validate_header_value($value);
        $output .= "$name: $value\r\n";
    }
```

Also update the Connection.pm trailer path (~line 2448-2458) if it builds trailers directly rather than delegating to the protocol module. Find:

```perl
                for my $header (@$trailer_headers) {
                    my ($name, $value) = @$header;
                    $trailers .= "$name: $value\r\n";
                }
```

Replace with:

```perl
                for my $header (@$trailer_headers) {
                    my ($name, $value) = @$header;
                    $name  = _validate_header_name($name);
                    $value = _validate_header_value($value);
                    $trailers .= "$name: $value\r\n";
                }
```

**Step 4: Run test to verify it passes**

```bash
bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.40.0@default && prove -l t/15-crlf-injection.t'
```

Expected: ALL PASS

**Step 5: Commit**

```bash
git add lib/PAGI/Server/Protocol/HTTP1.pm lib/PAGI/Server/Connection.pm t/15-crlf-injection.t
git commit -m "$(cat <<'EOF'
security: validate trailer headers for CRLF injection

Trailer names and values now pass through _validate_header_name and
_validate_header_value, matching the validation applied to normal
response headers. Prevents response splitting via trailer injection.
EOF
)"
```

---

### Task 4: S4 — Validate SSE event/id/retry fields against newline injection

The `event`, `id`, and `retry` fields in `_format_sse_event` are written verbatim without checking for newlines. A newline in `event` injects additional SSE fields.

**Files:**
- Modify: `lib/PAGI/Server/Connection.pm` (~line 3063-3081, `_format_sse_event`)
- Test: `t/sse/11-wire-format.t` (add subtests — this file already tests SSE formatting)

**Step 1: Write the failing test**

Add to `t/sse/11-wire-format.t`:

```perl
subtest 'SSE event name with newline is rejected' => sub {
    like(
        dies {
            PAGI::Server::Connection::_format_sse_event({
                event => "click\ndata: injected",
                data  => 'payload',
            })
        },
        qr/Invalid SSE event.*newline/i,
        'newline in event name dies'
    );
};

subtest 'SSE id with newline is rejected' => sub {
    like(
        dies {
            PAGI::Server::Connection::_format_sse_event({
                data => 'payload',
                id   => "123\ndata: injected",
            })
        },
        qr/Invalid SSE id.*newline/i,
        'newline in id dies'
    );
};

subtest 'SSE retry must be non-negative integer' => sub {
    like(
        dies {
            PAGI::Server::Connection::_format_sse_event({
                data  => 'payload',
                retry => "5000\ndata: injected",
            })
        },
        qr/Invalid SSE retry/i,
        'newline in retry dies'
    );

    like(
        dies {
            PAGI::Server::Connection::_format_sse_event({
                data  => 'payload',
                retry => 'abc',
            })
        },
        qr/Invalid SSE retry/i,
        'non-numeric retry dies'
    );
};

subtest 'SSE valid event/id/retry fields pass through' => sub {
    my $formatted = PAGI::Server::Connection::_format_sse_event({
        event => 'click',
        data  => 'payload',
        id    => '42',
        retry => 3000,
    });
    like $formatted, qr/^event: click\n/, 'event field present';
    like $formatted, qr/^id: 42\n/m, 'id field present';
    like $formatted, qr/^retry: 3000\n/m, 'retry field present';
    like $formatted, qr/^data: payload\n/m, 'data field present';
};
```

**Step 2: Run test to verify it fails**

```bash
bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.40.0@default && prove -l t/sse/11-wire-format.t :: rejected'
```

Expected: FAIL — currently no validation on these fields

**Step 3: Implement the fix**

In `lib/PAGI/Server/Connection.pm`, in `_format_sse_event` (~line 3063), add validation before writing each field:

```perl
sub _format_sse_event {
    my ($event) = @_;
    my $sse_data = '';

    if (defined $event->{event} && length $event->{event}) {
        die "Invalid SSE event name: contains newline\n"
            if $event->{event} =~ /[\r\n]/;
        $sse_data .= "event: $event->{event}\n";
    }

    my $data = $event->{data} // '';
    for my $line (split /\r?\n|\r/, $data, -1) {
        $sse_data .= "data: $line\n";
    }

    if (defined $event->{id} && length $event->{id}) {
        die "Invalid SSE id: contains newline\n"
            if $event->{id} =~ /[\r\n]/;
        $sse_data .= "id: $event->{id}\n";
    }

    if (defined $event->{retry}) {
        die "Invalid SSE retry: must be a non-negative integer\n"
            unless $event->{retry} =~ /\A[0-9]+\z/;
        $sse_data .= "retry: $event->{retry}\n";
    }

    $sse_data .= "\n";
    return $sse_data;
}
```

**Step 4: Run test to verify it passes**

```bash
bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.40.0@default && prove -l t/sse/11-wire-format.t'
```

Expected: ALL PASS

**Step 5: Run full SSE test suite for regressions**

```bash
bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.40.0@default && prove -l t/sse/ t/05-sse.t'
```

Expected: ALL PASS

**Step 6: Commit**

```bash
git add lib/PAGI/Server/Connection.pm t/sse/11-wire-format.t
git commit -m "$(cat <<'EOF'
security: validate SSE event/id/retry fields against newline injection

event and id fields now reject values containing CR or LF to prevent
SSE field injection. retry field validated as non-negative integer.
data field was already safe (split on newlines and prefixed).
EOF
)"
```

---

### Task 5: S5 — Tighten Transfer-Encoding: chunked detection

`/chunked/i` is too loose — it matches `chunked` anywhere in the value. RFC 9112 §6.1 requires `chunked` to be the final encoding. Also, `Transfer-Encoding` without `chunked` as final should be rejected.

**Files:**
- Modify: `lib/PAGI/Server/Protocol/HTTP1.pm` (~line 221)
- Test: `t/10-http-compliance.t` (add subtests)

**Step 1: Write the failing tests**

Add to `t/10-http-compliance.t`:

```perl
subtest 'Transfer-Encoding validation' => sub {
    my $proto = PAGI::Server::Protocol::HTTP1->new;

    subtest 'chunked as final encoding is accepted' => sub {
        my $raw = "POST /test HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: gzip, chunked\r\n\r\n";
        my $buf = $raw;
        my ($req, $consumed) = $proto->parse_request(\$buf);
        ok $req && !$req->{error}, 'request accepted';
        ok $req->{chunked}, 'chunked flag set';
    };

    subtest 'chunked not final is rejected' => sub {
        my $raw = "POST /test HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked, gzip\r\n\r\n";
        my $buf = $raw;
        my ($req, $consumed) = $proto->parse_request(\$buf);
        ok $req, 'got response';
        is $req->{error}, 400, 'returns 400 when chunked is not final encoding';
    };

    subtest 'unknown transfer encoding without chunked is rejected' => sub {
        my $raw = "POST /test HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: gzip\r\n\r\n";
        my $buf = $raw;
        my ($req, $consumed) = $proto->parse_request(\$buf);
        ok $req, 'got response';
        is $req->{error}, 501, 'returns 501 for unsupported transfer encoding';
    };

    subtest 'chunked alone is accepted' => sub {
        my $raw = "POST /test HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n\r\n";
        my $buf = $raw;
        my ($req, $consumed) = $proto->parse_request(\$buf);
        ok $req && !$req->{error}, 'request accepted';
        ok $req->{chunked}, 'chunked flag set';
    };
};
```

**Step 2: Run test to verify it fails**

```bash
bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.40.0@default && prove -l t/10-http-compliance.t :: Transfer-Encoding.validation'
```

Expected: FAIL — "chunked, gzip" and "gzip" alone currently accepted

**Step 3: Implement the fix**

In `lib/PAGI/Server/Protocol/HTTP1.pm`, replace the Transfer-Encoding detection (~line 220-223):

Find:

```perl
            if ($header_name eq 'transfer-encoding' && $value =~ /chunked/i) {
                $chunked = 1;
            }
```

Replace with:

```perl
            if ($header_name eq 'transfer-encoding') {
                # RFC 9112 Section 6.1: chunked must be the final encoding
                my @codings = map { s/^\s+|\s+$//gr } split /,/, lc($value);
                if (@codings && $codings[-1] eq 'chunked') {
                    $chunked = 1;
                } else {
                    $te_unsupported = 1;
                }
            }
```

Also declare `my $te_unsupported = 0;` alongside the other flag variables at the top of `parse_request`, and add a check after the header loop:

```perl
    # Reject unsupported Transfer-Encoding (chunked not final or not present)
    if ($te_unsupported) {
        return ({ error => 501, message => 'Unsupported Transfer-Encoding' }, $header_end + 4);
    }
```

**Step 4: Run test to verify it passes**

```bash
bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.40.0@default && prove -l t/10-http-compliance.t'
```

Expected: ALL PASS

**Step 5: Run full test suite for regressions**

```bash
bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.40.0@default && prove -l t/'
```

Expected: No new failures

**Step 6: Commit**

```bash
git add lib/PAGI/Server/Protocol/HTTP1.pm t/10-http-compliance.t
git commit -m "$(cat <<'EOF'
security: validate Transfer-Encoding per RFC 9112 Section 6.1

chunked must be the final transfer coding. Reject requests where
chunked appears before other codings or where Transfer-Encoding
is present without chunked (returns 501). Prevents smuggling via
ambiguous TE interpretation.
EOF
)"
```

---

### Task 6: S6 — Fix TLS configuration to allow TLS 1.3

`SSL_version => 'TLSv1_2'` (without trailing colon) restricts to exactly TLS 1.2, preventing TLS 1.3 negotiation.

**Files:**
- Modify: `lib/PAGI/Server.pm` (~line 1696)
- Test: `t/08-tls.t` (add subtest if feasible, otherwise manual verification)

**Step 1: Read the current TLS test to understand the test pattern**

```bash
bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.40.0@default && head -50 t/08-tls.t'
```

**Step 2: Implement the fix**

In `lib/PAGI/Server.pm`, find (~line 1696):

```perl
$ssl_params{SSL_version} = $ssl->{min_version} // 'TLSv1_2';
```

Replace with:

```perl
# Trailing colon means "this version or higher" — allows TLS 1.3 negotiation
$ssl_params{SSL_version} = ($ssl->{min_version} // 'TLSv1_2') . ':';
```

**Step 3: Run TLS tests**

```bash
bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.40.0@default && prove -l t/08-tls.t'
```

Expected: PASS (or SKIP if TLS deps not installed)

**Step 4: Run full test suite for regressions**

```bash
bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.40.0@default && prove -l t/'
```

Expected: No new failures

**Step 5: Commit**

```bash
git add lib/PAGI/Server.pm
git commit -m "$(cat <<'EOF'
security: fix TLS config to allow TLS 1.3 negotiation

SSL_version without trailing colon restricts to exactly that version.
Adding ':' suffix means "minimum version", allowing OpenSSL to
negotiate TLS 1.3 when both sides support it.
EOF
)"
```

---

### Task 7: C1 — Fix disable_tls + ssl behavioral contract

Documentation says `disable_tls` allows "testing TLS configuration parsing without enabling TLS." Code dies immediately. Fix the code to match the documented behavior.

**Files:**
- Modify: `lib/PAGI/Server.pm` (~line 1420-1423 and ~line 1690)
- Test: `t/10-http-compliance.t` (add subtest)

**Step 1: Write the failing test**

Add to `t/10-http-compliance.t`:

```perl
subtest 'disable_tls with ssl config starts server without TLS' => sub {
    # Should NOT die — should validate cert paths but skip TLS setup
    my $server = eval {
        PAGI::Server->new(
            app         => async sub { },
            ssl         => { cert_file => '/nonexistent.pem', key_file => '/nonexistent.key' },
            disable_tls => 1,
        );
    };

    # With disable_tls, cert validation should be skipped entirely
    ok !$@, 'does not die with disable_tls + ssl' or diag $@;
};
```

**Step 2: Run test to verify it fails**

```bash
bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.40.0@default && prove -l t/10-http-compliance.t :: disable_tls'
```

Expected: FAIL — currently dies

**Step 3: Implement the fix**

In `lib/PAGI/Server.pm`, find (~line 1420-1423):

```perl
    if ($self->{disable_tls}) {
        die "TLS is disabled via disable_tls option\n";
    }
```

Replace with:

```perl
    if ($self->{disable_tls}) {
        $self->_log(info => "TLS disabled via disable_tls option, ssl config ignored");
    }
```

Then ensure the TLS setup code later (~line 1690) also checks `disable_tls`:

Find the section that builds `%ssl_params` and add a guard:

```perl
    if (my $ssl = $self->{ssl}) {
        next if $self->{disable_tls};  # or 'return' depending on flow
```

The exact guard depends on the surrounding control flow — check the `_init` method structure.

**Step 4: Run test to verify it passes**

```bash
bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.40.0@default && prove -l t/10-http-compliance.t'
```

Expected: ALL PASS

**Step 5: Update POD if needed**

Verify the existing `disable_tls` documentation matches the new behavior. It should say something like: "Skips TLS setup even when ssl config is provided. The ssl configuration is parsed and stored but not applied to connections."

**Step 6: Commit**

```bash
git add lib/PAGI/Server.pm t/10-http-compliance.t
git commit -m "$(cat <<'EOF'
fix: disable_tls skips TLS setup instead of dying

Match documented behavior: disable_tls allows ssl config to be
present without enabling TLS. Useful for testing configuration
parsing and for environments where TLS is terminated upstream.
EOF
)"
```

---

### Task 8: C2 — Fix configure() to recompile access log formatter

When `access_log_format` is changed via `configure()`, the compiled `_access_log_formatter` closure is not rebuilt.

**Files:**
- Modify: `lib/PAGI/Server.pm` (in `configure()`, where `access_log_format` is handled)
- Test: `t/10-http-compliance.t` (add subtest)

**Step 1: Write the failing test**

Add to `t/10-http-compliance.t`:

```perl
subtest 'configure() recompiles access log formatter' => sub {
    my $server = PAGI::Server->new(
        app               => async sub { },
        access_log_format => 'common',
    );

    my $formatter1 = $server->{_access_log_formatter};
    ok defined $formatter1, 'initial formatter compiled';

    # Reconfigure with different format
    $server->configure(access_log_format => 'combined');

    my $formatter2 = $server->{_access_log_formatter};
    ok defined $formatter2, 'formatter still defined after reconfigure';
    isnt $formatter2, $formatter1, 'formatter was recompiled (different reference)';
};
```

**Step 2: Run test to verify it fails**

```bash
bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.40.0@default && prove -l t/10-http-compliance.t :: recompiles'
```

Expected: FAIL — formatter reference unchanged after configure()

**Step 3: Implement the fix**

In `lib/PAGI/Server.pm`, in `configure()`, find where `access_log_format` is handled. After setting the new format value, add the recompile:

```perl
    if (exists $params{access_log_format}) {
        $self->{access_log_format} = delete $params{access_log_format};
        $self->{_access_log_formatter} = $self->_compile_access_log_format(
            $self->{access_log_format}
        );
    }
```

**Step 4: Run test to verify it passes**

```bash
bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.40.0@default && prove -l t/10-http-compliance.t'
```

Expected: ALL PASS

**Step 5: Commit**

```bash
git add lib/PAGI/Server.pm t/10-http-compliance.t
git commit -m "$(cat <<'EOF'
fix: recompile access log formatter on configure()

configure(access_log_format => ...) updated the format string but
not the compiled closure. Subsequent log entries used the old format.
EOF
)"
```

---

### Task 9: X1 — Weaken $self in _pause_accepting timer closure

The accept-pause timer closure captures a strong `$self` reference, unlike every other closure in Server.pm. Creates a reference cycle that prevents GC during shutdown.

**Files:**
- Modify: `lib/PAGI/Server.pm` (~line 2593-2601, `_pause_accepting`)

**Step 1: Implement the fix**

In `lib/PAGI/Server.pm`, in `_pause_accepting`, add `Scalar::Util::weaken` before the timer closure. Find:

```perl
    my $timer_id = $self->loop->watch_time(after => $duration, code => sub {
        return unless $self->{running};
```

Replace with:

```perl
    weaken(my $weak_self = $self);
    my $timer_id = $self->loop->watch_time(after => $duration, code => sub {
        return unless $weak_self && $weak_self->{running};
```

And update all `$self->` references inside the closure to `$weak_self->`.

**Step 2: Run full test suite**

```bash
bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.40.0@default && prove -l t/'
```

Expected: No new failures

**Step 3: Commit**

```bash
git add lib/PAGI/Server.pm
git commit -m "$(cat <<'EOF'
fix: weaken $self in _pause_accepting timer closure

Matches the weakening pattern used by all other closures in Server.pm.
Prevents reference cycle that could delay GC during shutdown.
EOF
)"
```

---

### Task 10: X2 — Remove dead code _log_connection_stats

`_log_connection_stats` is defined but never called.

**Files:**
- Modify: `lib/PAGI/Server.pm` (~line 2607-2615)

**Step 1: Verify it's truly unused**

```bash
bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.40.0@default && grep -rn "_log_connection_stats" lib/ t/'
```

Expected: Only the definition, no call sites

**Step 2: Remove the method**

Delete the entire `_log_connection_stats` method from Server.pm.

**Step 3: Run full test suite**

```bash
bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.40.0@default && prove -l t/'
```

Expected: No new failures

**Step 4: Commit**

```bash
git add lib/PAGI/Server.pm
git commit -m "$(cat <<'EOF'
cleanup: remove unused _log_connection_stats method
EOF
)"
```

---

### Task 11: Final verification

**Step 1: Run the full test suite**

```bash
bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.40.0@default && prove -l t/'
```

Expected: PASS (known pre-existing failures in t/42-file-response.t and t/app-file.t are acceptable)

**Step 2: Review all changes**

```bash
git log --oneline -12
git diff main --stat
```

Verify all 10 commits landed and the change summary looks reasonable.
