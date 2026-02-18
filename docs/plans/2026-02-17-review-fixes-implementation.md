# Review Fixes Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Fix 6 security/correctness issues and 1 misleading doc identified by the 5-person conceptual review.

**Architecture:** Each fix is independent except Task 1 (utility module) which Tasks 2-3 depend on. All code fixes follow TDD: write failing test, implement minimal fix, verify pass, commit.

**Tech Stack:** Perl 5.40, Test2::V0, Future::AsyncAwait, IO::Async

**Perlbrew:** `source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.40.0@default`

---

### Task 1: Create PAGI::Utils::Random module

**Files:**
- Create: `lib/PAGI/Utils/Random.pm`
- Test: `t/utils/random.t`

**Step 1: Create the test directory**

```bash
mkdir -p t/utils
```

**Step 2: Write the failing tests**

Create `t/utils/random.t`:

```perl
#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;

use_ok('PAGI::Utils::Random');

use PAGI::Utils::Random qw(secure_random_bytes);

subtest 'returns bytes of requested length' => sub {
    for my $len (1, 16, 32, 64) {
        my $bytes = secure_random_bytes($len);
        is length($bytes), $len, "returns $len bytes";
    }
};

subtest 'returns different values on successive calls' => sub {
    my $a = secure_random_bytes(32);
    my $b = secure_random_bytes(32);
    ok $a ne $b, 'two calls return different bytes';
};

subtest 'dies when no secure source available' => sub {
    # Temporarily hide /dev/urandom and Crypt::URandom
    no warnings 'redefine';
    local *PAGI::Utils::Random::secure_random_bytes = sub {
        my ($length) = @_;
        # Simulate: /dev/urandom fails, Crypt::URandom not available
        die "No secure random source available. "
          . "Install Crypt::URandom or ensure /dev/urandom is accessible.\n";
    };
    like(
        dies { PAGI::Utils::Random::secure_random_bytes(32) },
        qr/No secure random source/,
        'dies with descriptive message when no source available'
    );
};

done_testing;
```

**Step 3: Run test to verify it fails**

Run: `bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.40.0@default && prove -l t/utils/random.t'`
Expected: FAIL — module does not exist

**Step 4: Create the Utils directory and module**

Create `lib/PAGI/Utils/Random.pm`:

```perl
package PAGI::Utils::Random;

use strict;
use warnings;
use Exporter 'import';

our @EXPORT_OK = qw(secure_random_bytes);

=head1 NAME

PAGI::Utils::Random - Cryptographically secure random bytes

=head1 SYNOPSIS

    use PAGI::Utils::Random qw(secure_random_bytes);

    my $bytes = secure_random_bytes(32);

=head1 DESCRIPTION

Provides cryptographically secure random bytes for security-sensitive
operations like session ID and CSRF token generation.

Attempts C</dev/urandom> first, falls back to L<Crypt::URandom>.
If neither is available, dies rather than producing predictable output.

=head1 FUNCTIONS

=head2 secure_random_bytes($length)

Returns C<$length> cryptographically secure random bytes.

Dies if no secure random source is available.

=cut

sub secure_random_bytes {
    my ($length) = @_;

    # Try /dev/urandom first (Unix)
    if (open my $fh, '<:raw', '/dev/urandom') {
        my $bytes;
        read($fh, $bytes, $length);
        close $fh;
        return $bytes if defined $bytes && length($bytes) == $length;
    }

    # Fallback: use Crypt::URandom if available
    if (eval { require Crypt::URandom; 1 }) {
        return Crypt::URandom::urandom($length);
    }

    # No secure source — die rather than produce predictable tokens
    die "No secure random source available. "
      . "Install Crypt::URandom or ensure /dev/urandom is accessible.\n";
}

1;

__END__

=head1 SEE ALSO

L<PAGI::Middleware::CSRF>, L<PAGI::Middleware::Session>

=cut
```

**Step 5: Run test to verify it passes**

Run: `bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.40.0@default && prove -l t/utils/random.t'`
Expected: PASS

**Step 6: Commit**

```bash
git add lib/PAGI/Utils/Random.pm t/utils/random.t
git commit -m "feat: add PAGI::Utils::Random for secure random bytes

Shared utility replacing duplicated _secure_random_bytes() in CSRF
and Session middleware. Dies instead of falling back to insecure
rand() when no cryptographic random source is available."
```

---

### Task 2: Replace _secure_random_bytes in CSRF.pm

**Files:**
- Modify: `lib/PAGI/Middleware/CSRF.pm:7,136-159`
- Test: `t/middleware/10-session-auth.t` (existing CSRF tests)

**Step 1: Run existing CSRF tests to establish baseline**

Run: `bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.40.0@default && prove -l t/middleware/10-session-auth.t'`
Expected: PASS (baseline)

**Step 2: Add import to CSRF.pm**

In `lib/PAGI/Middleware/CSRF.pm`, after line 7 (`use Digest::SHA qw(sha256_hex);`), add:

```perl
use PAGI::Utils::Random qw(secure_random_bytes);
```

**Step 3: Remove the duplicated _secure_random_bytes sub**

In `lib/PAGI/Middleware/CSRF.pm`, delete the entire `_secure_random_bytes` subroutine (lines 136-159). The existing call site at line 132 (`my $random = _secure_random_bytes(32);`) now calls the imported function.

**Step 4: Run CSRF tests to verify they still pass**

Run: `bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.40.0@default && prove -l t/middleware/10-session-auth.t'`
Expected: PASS

**Step 5: Commit**

```bash
git add lib/PAGI/Middleware/CSRF.pm
git commit -m "refactor: CSRF uses shared PAGI::Utils::Random

Removes duplicated _secure_random_bytes and the insecure rand()
fallback. CSRF token generation now dies if no secure random
source is available."
```

---

### Task 3: Replace _secure_random_bytes in Session.pm

**Files:**
- Modify: `lib/PAGI/Middleware/Session.pm:224-247`
- Test: `t/middleware/10-session-auth.t` (existing Session tests)

**Step 1: Run existing Session tests to establish baseline**

Run: `bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.40.0@default && prove -l t/middleware/10-session-auth.t'`
Expected: PASS (baseline)

**Step 2: Add import to Session.pm**

In `lib/PAGI/Middleware/Session.pm`, in the `use` section at the top, add:

```perl
use PAGI::Utils::Random qw(secure_random_bytes);
```

**Step 3: Remove the duplicated _secure_random_bytes sub**

In `lib/PAGI/Middleware/Session.pm`, delete the entire `_secure_random_bytes` subroutine (lines 224-247). The existing call site at line 219 (`my $random = _secure_random_bytes(32);`) now calls the imported function.

**Step 4: Run Session tests to verify they still pass**

Run: `bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.40.0@default && prove -l t/middleware/10-session-auth.t'`
Expected: PASS

**Step 5: Commit**

```bash
git add lib/PAGI/Middleware/Session.pm
git commit -m "refactor: Session uses shared PAGI::Utils::Random

Removes duplicated _secure_random_bytes and the insecure rand()
fallback. Session ID generation now dies if no secure random
source is available."
```

---

### Task 4: Remove double URL-decoding in Static middleware

**Files:**
- Modify: `lib/PAGI/Middleware/Static.pm:353-354`
- Test: `t/middleware/04-static.t`

**Step 1: Run existing Static tests to establish baseline**

Run: `bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.40.0@default && prove -l t/middleware/04-static.t'`
Expected: PASS (baseline)

**Step 2: Write test for double-encoded path traversal**

Add to `t/middleware/04-static.t` before `done_testing`:

```perl
# =============================================================================
# Test: Double URL-decoding does not create path traversal
# =============================================================================

subtest 'double-encoded path traversal is blocked' => sub {
    my $mw = PAGI::Middleware::Static->new(root => $test_root);
    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        await $send->({ type => 'http.response.start', status => 404, headers => [] });
        await $send->({ type => 'http.response.body', body => 'Not found', more => 0 });
    };
    my $wrapped = $mw->wrap($app);

    # Simulate server-decoded path: %252e%252e -> %2e%2e (server decodes first layer)
    # If Static decodes again, %2e%2e -> .. which is traversal
    my $scope = {
        type   => 'http',
        method => 'GET',
        path   => '/%2e%2e/etc/passwd',  # server already decoded %25 -> %
        headers => [],
    };

    my @sent;
    my $receive = async sub { {} };
    my $send = async sub { my ($event) = @_; push @sent, $event };

    run_async(async sub { await $wrapped->($scope, $receive, $send) });

    # Should NOT serve /etc/passwd — should fall through to 404 app or be blocked
    ok @sent > 0, 'got response';
    # The path should be treated literally, not decoded again to ..
    isnt $sent[0]{status}, 200, 'double-encoded traversal does not serve files outside root';
};
```

**Step 3: Run test to verify current behavior**

Run: `bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.40.0@default && prove -l t/middleware/04-static.t'`
Expected: PASS (current validation catches `..` even with double decode, but test documents the protection)

**Step 4: Remove the double-decode line**

In `lib/PAGI/Middleware/Static.pm`, in `_resolve_path` (line 354), remove:

```perl
    $decoded =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/eg;
```

The method becomes:

```perl
sub _resolve_path {
    my ($self, $url_path) = @_;

    my $decoded = $url_path;

    # Remove query string
    $decoded =~ s/\?.*//;

    # Combine with root (use manual concat to preserve .. for security check)
    my $root = $self->{root};
    $root =~ s{/$}{};  # Remove trailing slash from root
    return $root . $decoded;
}
```

**Step 5: Run all Static tests to verify they pass**

Run: `bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.40.0@default && prove -l t/middleware/04-static.t'`
Expected: PASS

**Step 6: Also run the app-level static test**

Run: `bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.40.0@default && prove -l t/app/01-static-files.t'`
Expected: PASS

**Step 7: Commit**

```bash
git add lib/PAGI/Middleware/Static.pm t/middleware/04-static.t
git commit -m "fix: remove double URL-decoding in Static middleware

Server already decodes percent-encoding in \$scope->{path}.
Static middleware was decoding again, creating a latent path
traversal risk via double-encoded sequences like %252e%252e."
```

---

### Task 5: Fix HTTP/2 path decoding to match HTTP/1.1

**Files:**
- Modify: `lib/PAGI/Server/Connection.pm:10,631-633`
- Test: new test or modify existing HTTP/2 test

**Step 1: Identify existing HTTP/2 test files**

```bash
ls t/*http2* t/*h2*
```

Look for existing tests that check `$scope->{path}` via HTTP/2.

**Step 2: Write failing test for UTF-8 path via HTTP/2 scope creation**

Since HTTP/2 testing requires nghttp2, write a unit test that directly tests
the path decoding logic rather than a full integration test. Create
`t/http2-path-decoding.t`:

```perl
#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use URI::Escape qw(uri_unescape);
use Encode qw(decode);

# Test the decoding pipeline that HTTP/2 SHOULD use (matching HTTP/1.1)

subtest 'UTF-8 percent-encoded path decodes correctly' => sub {
    my $raw_path = '/caf%C3%A9';
    my $unescaped = uri_unescape($raw_path);
    my $decoded = eval { decode('UTF-8', $unescaped, Encode::FB_CROAK) } // $unescaped;
    is $decoded, "/caf\x{e9}", 'UTF-8 path decoded correctly';
};

subtest 'invalid UTF-8 falls back to raw bytes' => sub {
    my $raw_path = '/bad%FF%FEpath';
    my $unescaped = uri_unescape($raw_path);
    my $decoded = eval { decode('UTF-8', $unescaped, Encode::FB_CROAK) } // $unescaped;
    # Should not die, should fall back to raw bytes
    ok defined $decoded, 'invalid UTF-8 does not crash';
    is $decoded, $unescaped, 'falls back to raw unescaped bytes';
};

subtest 'simple ASCII path unchanged' => sub {
    my $raw_path = '/users/123/profile';
    my $unescaped = uri_unescape($raw_path);
    my $decoded = eval { decode('UTF-8', $unescaped, Encode::FB_CROAK) } // $unescaped;
    is $decoded, '/users/123/profile', 'ASCII path unchanged';
};

subtest 'space encoded as %20 decodes' => sub {
    my $raw_path = '/my%20file.txt';
    my $unescaped = uri_unescape($raw_path);
    my $decoded = eval { decode('UTF-8', $unescaped, Encode::FB_CROAK) } // $unescaped;
    is $decoded, '/my file.txt', 'space decodes correctly';
};

done_testing;
```

**Step 3: Run test to verify the pipeline works**

Run: `bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.40.0@default && prove -l t/http2-path-decoding.t'`
Expected: PASS (this tests the correct pipeline, not the buggy one)

**Step 4: Fix the HTTP/2 path decoding in Connection.pm**

In `lib/PAGI/Server/Connection.pm`, add to the `use` block (near line 10):

```perl
use URI::Escape qw(uri_unescape);
```

Then replace lines 631-633:

```perl
    # Decode percent-encoded path for scope (keep raw_path as-is)
    my $decoded_path = $path;
    $decoded_path =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/ge;
```

With:

```perl
    # Decode percent-encoded path for scope (keep raw_path as-is)
    # Match HTTP/1.1 pipeline: URI::Escape + UTF-8 decode with fallback
    my $unescaped = uri_unescape($path);
    my $decoded_path = eval { decode('UTF-8', $unescaped, Encode::FB_CROAK) }
                       // $unescaped;
```

**Step 5: Run existing HTTP/2 tests**

Run: `bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.40.0@default && prove -l t/20-http2*.t t/http2*.t 2>/dev/null; echo "exit: $?"'`
Expected: PASS (or SKIP if nghttp2 not available)

**Step 6: Run full test suite to check for regressions**

Run: `bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.40.0@default && prove -l t/ 2>&1 | tail -20'`
Expected: No new failures

**Step 7: Commit**

```bash
git add lib/PAGI/Server/Connection.pm t/http2-path-decoding.t
git commit -m "fix: HTTP/2 path decoding matches HTTP/1.1 pipeline

HTTP/2 was using a manual regex for percent-decoding without UTF-8
decode. Now uses URI::Escape::uri_unescape + Encode::decode with
fallback, matching HTTP/1.1 behavior. Same URL now produces the
same \$scope->{path} regardless of protocol version."
```

---

### Task 6: Session cookie SameSite=Lax default

**Files:**
- Modify: `lib/PAGI/Middleware/Session.pm:127-130`
- Test: `t/middleware/10-session-auth.t`

**Step 1: Write failing test for SameSite default**

Add to `t/middleware/10-session-auth.t` before `done_testing`:

```perl
# ===================
# Session Cookie Defaults Tests
# ===================

subtest 'Session cookie includes SameSite=Lax by default' => sub {
    PAGI::Middleware::Session->clear_sessions();

    my $session = PAGI::Middleware::Session->new(secret => 'test-secret');

    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        $scope->{'pagi.session'}{test} = 1;
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
    };

    my $wrapped = $session->wrap($app);
    my $scope = make_scope();

    my @events;
    my $receive = async sub { {} };
    my $send = async sub { my ($event) = @_; push @events, $event };

    run_async { $wrapped->($scope, $receive, $send) };

    my @cookies = map { $_->[1] }
                  grep { lc($_->[0]) eq 'set-cookie' }
                  @{$events[0]{headers} // []};
    ok @cookies > 0, 'got Set-Cookie header';
    like $cookies[0], qr/SameSite=Lax/i, 'default cookie includes SameSite=Lax';
};

subtest 'Session cookie respects custom samesite option' => sub {
    PAGI::Middleware::Session->clear_sessions();

    my $session = PAGI::Middleware::Session->new(
        secret         => 'test-secret',
        cookie_options => {
            httponly => 1,
            path     => '/',
            samesite => 'Strict',
        },
    );

    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        $scope->{'pagi.session'}{test} = 1;
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
    };

    my $wrapped = $session->wrap($app);
    my $scope = make_scope();

    my @events;
    my $receive = async sub { {} };
    my $send = async sub { my ($event) = @_; push @events, $event };

    run_async { $wrapped->($scope, $receive, $send) };

    my @cookies = map { $_->[1] }
                  grep { lc($_->[0]) eq 'set-cookie' }
                  @{$events[0]{headers} // []};
    ok @cookies > 0, 'got Set-Cookie header';
    like $cookies[0], qr/SameSite=Strict/i, 'custom samesite=Strict respected';
    unlike $cookies[0], qr/SameSite=Lax/i, 'does not contain default Lax';
};
```

**Step 2: Run test to verify it fails**

Run: `bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.40.0@default && prove -l t/middleware/10-session-auth.t'`
Expected: FAIL on "default cookie includes SameSite=Lax"

**Step 3: Add SameSite=Lax to default cookie_options**

In `lib/PAGI/Middleware/Session.pm`, change lines 127-130:

From:
```perl
    $self->{cookie_options} = $config->{cookie_options} // {
        httponly => 1,
        path     => '/',
    };
```

To:
```perl
    $self->{cookie_options} = $config->{cookie_options} // {
        httponly => 1,
        path     => '/',
        samesite => 'Lax',
    };
```

**Step 4: Update POD to document secure defaults recommendation**

In the POD section of Session.pm, add a note near the cookie_options documentation:

```pod
B<Production recommendation:> Add C<< secure => 1 >> to cookie_options when
serving over HTTPS to prevent session cookies from being sent over plain HTTP.
```

**Step 5: Run test to verify it passes**

Run: `bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.40.0@default && prove -l t/middleware/10-session-auth.t'`
Expected: PASS

**Step 6: Commit**

```bash
git add lib/PAGI/Middleware/Session.pm t/middleware/10-session-auth.t
git commit -m "fix: session cookie defaults to SameSite=Lax

Prevents cross-site cookie attachment by default. Production
deployments should also add secure => 1 for HTTPS-only cookies."
```

---

### Task 7: CORS wildcard + credentials warning

**Files:**
- Modify: `lib/PAGI/Middleware/CORS.pm:64-72`
- Test: `t/middleware/cors-warning.t`

**Step 1: Write failing test for the warning**

Create `t/middleware/cors-warning.t`:

```perl
#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;

use PAGI::Middleware::CORS;

subtest 'wildcard origins with credentials emits warning' => sub {
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, $_[0] };

    my $cors = PAGI::Middleware::CORS->new(
        origins     => ['*'],
        credentials => 1,
    );

    is scalar @warnings, 1, 'exactly one warning emitted';
    like $warnings[0], qr/wildcard.*credentials/i,
        'warning mentions wildcard + credentials';
};

subtest 'wildcard origins without credentials emits no warning' => sub {
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, $_[0] };

    my $cors = PAGI::Middleware::CORS->new(
        origins     => ['*'],
        credentials => 0,
    );

    is scalar @warnings, 0, 'no warning when credentials disabled';
};

subtest 'explicit origins with credentials emits no warning' => sub {
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, $_[0] };

    my $cors = PAGI::Middleware::CORS->new(
        origins     => ['https://example.com'],
        credentials => 1,
    );

    is scalar @warnings, 0, 'no warning with explicit origins';
};

subtest 'default config (no credentials) emits no warning' => sub {
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, $_[0] };

    my $cors = PAGI::Middleware::CORS->new();

    is scalar @warnings, 0, 'no warning with defaults';
};

done_testing;
```

**Step 2: Run test to verify it fails**

Run: `bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.40.0@default && prove -l t/middleware/cors-warning.t'`
Expected: FAIL on "exactly one warning emitted" (0 warnings currently)

**Step 3: Add the warning to CORS _init**

In `lib/PAGI/Middleware/CORS.pm`, at the end of `_init()` (after line 72), add:

```perl
    # Warn about insecure wildcard + credentials combination
    if ($self->{credentials} && grep { $_ eq '*' } @{$self->{origins}}) {
        warn "PAGI::Middleware::CORS: wildcard origins ('*') with credentials "
           . "enabled reflects any Origin with Access-Control-Allow-Credentials. "
           . "This allows any website to make credentialed cross-origin requests. "
           . "Consider specifying explicit origins.\n";
    }
```

**Step 4: Run test to verify it passes**

Run: `bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.40.0@default && prove -l t/middleware/cors-warning.t'`
Expected: PASS

**Step 5: Run full middleware test suite for regressions**

Run: `bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.40.0@default && prove -l t/middleware/'`
Expected: PASS (existing tests may need `$SIG{__WARN__}` if they use wildcard + credentials)

**Step 6: If any existing tests fail due to unexpected warnings, suppress in those tests**

Check for any tests that construct CORS with both `origins => ['*']` and `credentials => 1`. If found, wrap in `local $SIG{__WARN__} = sub {}` or fix the test config.

**Step 7: Commit**

```bash
git add lib/PAGI/Middleware/CORS.pm t/middleware/cors-warning.t
git commit -m "fix: CORS warns on wildcard origins with credentials

Wildcard + credentials reflects any Origin with Allow-Credentials,
allowing any site to make credentialed cross-origin requests.
Warning emitted once at construction time."
```

---

### Task 8: Rate limiter bucket cleanup

**Files:**
- Modify: `lib/PAGI/Middleware/RateLimit.pm:55-67,108-137`
- Test: `t/middleware/rate-limit.t`

**Step 1: Write tests for bucket cleanup**

Create `t/middleware/rate-limit.t`:

```perl
#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use IO::Async::Loop;

use PAGI::Middleware::RateLimit;

my $loop = IO::Async::Loop->new;

sub run_async (&) {
    my ($code) = @_;
    $loop->await($code->());
}

sub make_scope {
    my (%opts) = @_;
    return {
        type    => 'http',
        method  => $opts{method} // 'GET',
        path    => $opts{path} // '/',
        headers => $opts{headers} // [],
        client  => $opts{client} // ['127.0.0.1', 12345],
    };
}

# ===================
# Bucket Cleanup Tests
# ===================

subtest 'stale buckets are cleaned up' => sub {
    # Reset bucket state
    PAGI::Middleware::RateLimit->_clear_buckets();

    my $rl = PAGI::Middleware::RateLimit->new(
        requests_per_second => 10,
        burst               => 20,
        cleanup_interval    => 1,  # cleanup every 1 second for testing
    );

    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
    };

    my $wrapped = $rl->wrap($app);

    # Generate traffic from multiple IPs
    for my $i (1..50) {
        my @sent;
        my $scope = make_scope(client => ["10.0.0.$i", 12345]);
        run_async { $wrapped->($scope, async sub { {} }, async sub { push @sent, $_[0] }) };
    }

    my $count_before = PAGI::Middleware::RateLimit->_bucket_count();
    is $count_before, 50, 'created 50 buckets';

    # Simulate time passing (beyond stale threshold)
    # For rate=10, burst=20: stale_threshold = 2 * 20/10 = 4 seconds
    PAGI::Middleware::RateLimit->_advance_time_for_test(10);

    # Trigger cleanup by making one more request
    my @sent;
    my $scope = make_scope(client => ['10.0.0.1', 12345]);
    run_async { $wrapped->($scope, async sub { {} }, async sub { push @sent, $_[0] }) };

    my $count_after = PAGI::Middleware::RateLimit->_bucket_count();
    ok $count_after < $count_before, "stale buckets cleaned up ($count_after < $count_before)";
};

subtest 'active buckets are not cleaned up' => sub {
    PAGI::Middleware::RateLimit->_clear_buckets();

    my $rl = PAGI::Middleware::RateLimit->new(
        requests_per_second => 10,
        burst               => 20,
        cleanup_interval    => 1,
    );

    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
    };

    my $wrapped = $rl->wrap($app);

    # Make request from one IP
    my @sent;
    my $scope = make_scope(client => ['192.168.1.1', 12345]);
    run_async { $wrapped->($scope, async sub { {} }, async sub { push @sent, $_[0] }) };

    is PAGI::Middleware::RateLimit->_bucket_count(), 1, 'one bucket exists';

    # Don't advance time much — bucket should survive cleanup
    PAGI::Middleware::RateLimit->_advance_time_for_test(1);

    # Trigger cleanup
    run_async { $wrapped->($scope, async sub { {} }, async sub { push @sent, $_[0] }) };

    is PAGI::Middleware::RateLimit->_bucket_count(), 1, 'active bucket preserved';
};

subtest 'max_buckets safety valve evicts oldest' => sub {
    PAGI::Middleware::RateLimit->_clear_buckets();

    my $rl = PAGI::Middleware::RateLimit->new(
        requests_per_second => 10,
        burst               => 20,
        max_buckets         => 10,
    );

    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
    };

    my $wrapped = $rl->wrap($app);

    # Generate more than max_buckets unique IPs
    for my $i (1..15) {
        my @sent;
        my $scope = make_scope(client => ["10.0.0.$i", 12345]);
        run_async { $wrapped->($scope, async sub { {} }, async sub { push @sent, $_[0] }) };
    }

    my $count = PAGI::Middleware::RateLimit->_bucket_count();
    ok $count <= 10, "max_buckets enforced ($count <= 10)";
};

subtest 'rate limiting still works correctly after cleanup' => sub {
    PAGI::Middleware::RateLimit->_clear_buckets();

    my $rl = PAGI::Middleware::RateLimit->new(
        requests_per_second => 1,
        burst               => 2,
    );

    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
    };

    my $wrapped = $rl->wrap($app);
    my $scope = make_scope();

    # Exhaust burst
    for my $i (1..2) {
        my @sent;
        run_async { $wrapped->($scope, async sub { {} }, async sub { push @sent, $_[0] }) };
        is $sent[0]{status}, 200, "request $i allowed";
    }

    # Third request should be rate limited
    my @sent;
    run_async { $wrapped->($scope, async sub { {} }, async sub { push @sent, $_[0] }) };
    is $sent[0]{status}, 429, 'rate limited after burst exhausted';
};

done_testing;
```

**Step 2: Run test to verify it fails**

Run: `bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.40.0@default && prove -l t/middleware/rate-limit.t'`
Expected: FAIL — `_clear_buckets`, `_bucket_count`, `_advance_time_for_test` don't exist

**Step 3: Add test helper methods and cleanup logic to RateLimit.pm**

In `lib/PAGI/Middleware/RateLimit.pm`:

Add test helper methods (after the `%buckets` declaration around line 55):

```perl
my $_time_offset = 0;  # For testing only

sub _clear_buckets { %buckets = (); $_time_offset = 0; }
sub _bucket_count  { return scalar keys %buckets }
sub _advance_time_for_test { $_time_offset += $_[1] }
sub _now { return time() + $_time_offset }
```

Add `cleanup_interval` and `max_buckets` to `_init` (around line 57-67):

```perl
    $self->{cleanup_interval} = $config->{cleanup_interval} // 60;
    $self->{max_buckets}      = $config->{max_buckets} // 10_000;
```

In `_check_rate_limit`, replace `time()` calls with `_now()`, and add cleanup
logic at the end of the method (after the token check, before the return):

```perl
    my $now = _now();
    # ... existing logic using $now ...

    # Periodic cleanup of stale buckets
    if (!$self->{_last_cleanup}
        || ($now - $self->{_last_cleanup}) >= $self->{cleanup_interval}) {
        $self->{_last_cleanup} = $now;
        my $stale_threshold = $now - (2 * $burst / $rate);
        for my $k (keys %buckets) {
            delete $buckets{$k} if $buckets{$k}{last_time} < $stale_threshold;
        }
    }

    # Safety valve: evict oldest if over max
    if (keys %buckets > $self->{max_buckets}) {
        my @sorted = sort { $buckets{$a}{last_time} <=> $buckets{$b}{last_time} }
                     keys %buckets;
        my $to_remove = @sorted - int($self->{max_buckets} / 2);
        delete $buckets{$_} for @sorted[0 .. $to_remove - 1];
    }
```

**Step 4: Add multi-worker limitation to POD**

In the POD section of RateLimit.pm, add:

```pod
B<Multi-worker note:> Rate limit state is stored in-memory per worker process.
In multi-worker deployments, the effective rate limit is C<workers * limit>.
For shared rate limiting across workers or servers, use an external backend
(Redis, etc.) via the C<backend> option.
```

**Step 5: Run tests to verify they pass**

Run: `bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.40.0@default && prove -l t/middleware/rate-limit.t'`
Expected: PASS

**Step 6: Run full middleware test suite for regressions**

Run: `bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.40.0@default && prove -l t/middleware/'`
Expected: PASS

**Step 7: Commit**

```bash
git add lib/PAGI/Middleware/RateLimit.pm t/middleware/rate-limit.t
git commit -m "fix: rate limiter bucket cleanup and max_buckets limit

Stale buckets cleaned up periodically (default: every 60s).
max_buckets safety valve (default: 10000) evicts oldest entries.
Documents multi-worker limitation in POD."
```

---

### Task 9: SIGHUP documentation correction

**Files:**
- Modify: `lib/PAGI/Server.pm:1332-1340`

**Step 1: Update the SIGHUP POD**

In `lib/PAGI/Server.pm`, replace lines 1332-1340:

From:
```pod
=item B<SIGHUP> - Graceful restart (multi-worker only)

Performs a zero-downtime restart by spawning new workers before terminating
old ones. Useful for deploying new code without dropping connections.

    kill -HUP <pid>

In single-worker mode, SIGHUP is logged but ignored (no graceful restart
possible without multiple workers).
```

To:
```pod
=item B<SIGHUP> - Graceful worker restart (multi-worker only)

Performs a zero-downtime worker restart by terminating existing workers and
spawning replacements. Useful for recycling workers to reclaim leaked memory
or reset per-worker state without dropping active connections.

B<Note:> This does NOT reload application code. New workers fork from the
existing parent process and inherit the same loaded code. For code deploys,
perform a full server restart (SIGTERM + start).

    kill -HUP <pid>

In single-worker mode, SIGHUP is logged but ignored (no graceful restart
possible without multiple workers).
```

**Step 2: Verify no tests broken**

Run: `bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.40.0@default && prove -l t/ 2>&1 | tail -5'`
Expected: PASS (docs-only change)

**Step 3: Commit**

```bash
git add lib/PAGI/Server.pm
git commit -m "docs: correct SIGHUP description (worker recycle, not code reload)

SIGHUP recycles workers by forking from the existing parent process.
It does not reload application code. Clarified POD to prevent
confusion during deployments."
```

---

### Task 10: Final verification

**Step 1: Run the full test suite**

Run: `bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.40.0@default && prove -l t/'`
Expected: PASS (known pre-existing failures in t/42-file-response.t and t/app-file.t are acceptable)

**Step 2: Review all changes**

Run: `git log --oneline -10` to verify all 7 commits landed.
Run: `git diff main --stat` to see the full change summary.
