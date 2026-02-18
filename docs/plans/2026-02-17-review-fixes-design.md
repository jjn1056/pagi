# Review Fixes Design

**Date:** 2026-02-17
**Branch:** router-features (or new branch TBD)
**Scope:** Must-fix and should-fix items from the 5-person conceptual review

## Overview

Address 6 code fixes and 1 documentation fix identified by the review team.
All fixes are independent of each other except T1 (utility module must exist
before CSRF/Session refactoring).

## Fix 1: T1 — Eliminate `rand()` fallback + deduplicate `_secure_random_bytes`

### Problem
`PAGI::Middleware::CSRF` and `PAGI::Middleware::Session` both contain identical
`_secure_random_bytes()` functions that fall back to Perl's non-cryptographic
`rand()` when `/dev/urandom` is unavailable and `Crypt::URandom` is not
installed. Predictable session IDs and CSRF tokens are worse than a startup
failure.

### Design

Create `PAGI::Utils::Random` with:

```perl
package PAGI::Utils::Random;
use strict;
use warnings;
use Exporter 'import';
our @EXPORT_OK = qw(secure_random_bytes);

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
```

Then replace the duplicated `_secure_random_bytes` in both CSRF.pm and
Session.pm with `use PAGI::Utils::Random qw(secure_random_bytes)`.

### TDD Steps

1. **Test: `secure_random_bytes` returns correct length** — call with various
   lengths, verify output length matches
2. **Test: `secure_random_bytes` returns different values** — call twice,
   verify results differ (probabilistic but safe for 32 bytes)
3. **Test: `secure_random_bytes` dies when no source available** — mock away
   `/dev/urandom` and `Crypt::URandom`, verify `die` (not `warn` + `rand()`)
4. **Test: CSRF still generates tokens** — existing CSRF tests pass with the
   new import
5. **Test: Session still generates IDs** — existing Session tests pass with
   the new import

### Files Changed
- **New:** `lib/PAGI/Utils/Random.pm`
- **New:** `t/utils/random.t`
- **Modified:** `lib/PAGI/Middleware/CSRF.pm` (remove `_secure_random_bytes`, add import)
- **Modified:** `lib/PAGI/Middleware/Session.pm` (remove `_secure_random_bytes`, add import)

---

## Fix 2: T3 — Remove double URL-decoding in Static middleware

### Problem
`PAGI::Middleware::Static::_resolve_path()` percent-decodes the URL path, but
`$scope->{path}` is already decoded by the server (HTTP1.pm:196-197). A request
for `/%252e%252e/etc/passwd` gets decoded twice: once by the server to `%2e%2e`,
then again by Static to `../etc/passwd`. Current path validation catches this,
but it's a latent bypass risk.

### Design

Remove the `s/%([0-9A-Fa-f]{2})/chr(hex($1))/eg` line from `_resolve_path()`.
The path is already decoded when it arrives.

### TDD Steps

1. **Test: double-encoded path traversal is rejected** — request
   `/%252e%252e/etc/passwd`, verify 403/404 (this should already pass but
   documents the protection)
2. **Test: normal percent-encoded paths work** — request `/my%20file.txt`,
   verify it resolves correctly (the server decodes this before Static sees it)
3. **Test: paths with literal `%25` in filename work** — if a file is literally
   named `file%25.txt`, verify it's accessible (this is the edge case double-decode
   breaks)
4. Remove the percent-decode line from `_resolve_path()`
5. Verify all existing Static tests pass

### Files Changed
- **Modified:** `lib/PAGI/Middleware/Static.pm` (remove 1 line in `_resolve_path`)
- **New/Modified:** `t/middleware/04-static.t` (add double-decode test cases)

---

## Fix 3: T4 — Fix HTTP/2 path decoding inconsistency

### Problem
HTTP/1.1 (HTTP1.pm:196-197) decodes paths with `URI::Escape::uri_unescape` +
`Encode::decode('UTF-8', ..., FB_CROAK)` with fallback. HTTP/2
(Connection.pm:633) uses a manual regex `s/%([0-9A-Fa-f]{2})/chr(hex($1))/ge`
without UTF-8 decode. The same URL produces different `$scope->{path}` values
depending on protocol.

### Design

Replace the manual regex in Connection.pm's HTTP/2 path creation with the same
pipeline used by HTTP1.pm:

```perl
use URI::Escape qw(uri_unescape);
use Encode qw(decode);

my $unescaped = uri_unescape($path);
my $decoded_path = eval { decode('UTF-8', $unescaped, Encode::FB_CROAK) }
                   // $unescaped;
```

Connection.pm already `use`s Encode (line 11). Need to add `use URI::Escape`.

### TDD Steps

1. **Test: UTF-8 encoded path via HTTP/2** — send request with UTF-8 path
   (e.g., `/caf%C3%A9`), verify `$scope->{path}` is `'/cafe\x{e9}'` (decoded)
2. **Test: invalid UTF-8 falls back gracefully** — send path with invalid
   UTF-8 bytes, verify path is raw bytes (not crash)
3. **Test: HTTP/1.1 and HTTP/2 produce same path** — send identical URL via
   both protocols, verify `$scope->{path}` matches
4. Apply the fix
5. Run existing HTTP/2 tests

### Files Changed
- **Modified:** `lib/PAGI/Server/Connection.pm` (replace regex with uri_unescape + UTF-8 decode)
- **New/Modified:** test file for HTTP/2 path handling

### Note
HTTP/2 tests require `Net::HTTP2::nghttp2` 0.007+ which may not be available
in all environments. Tests should be gated on availability.

---

## Fix 4: T5 — Session cookie secure defaults

### Problem
`PAGI::Middleware::Session` defaults `cookie_options` to only `httponly => 1`
and `path => '/'`. No `samesite` flag, no `secure` flag. Session cookies sent
over plain HTTP are vulnerable to network sniffing; missing SameSite allows
cross-site cookie attachment.

### Design

Change default `cookie_options` to include `samesite => 'Lax'`:

```perl
$self->{cookie_options} = $config->{cookie_options} // {
    httponly => 1,
    path     => '/',
    samesite => 'Lax',
};
```

Do NOT default `secure => 1` because that would break development over HTTP.
Instead, add POD documentation recommending `secure => 1` for production.

### TDD Steps

1. **Test: default cookie includes SameSite=Lax** — create Session middleware
   with no cookie_options, verify Set-Cookie header contains `SameSite=Lax`
2. **Test: custom cookie_options override defaults** — pass explicit
   `samesite => 'Strict'`, verify it's used instead
3. **Test: can disable samesite** — pass `samesite => undef` or omit it in
   custom options, verify behavior
4. Apply the default change
5. Verify existing Session tests pass

### Files Changed
- **Modified:** `lib/PAGI/Middleware/Session.pm` (add `samesite` default, update POD)
- **New/Modified:** `t/middleware/10-session-auth.t` (add cookie attribute tests)

---

## Fix 5: T6 — CORS wildcard + credentials warning

### Problem
When `origins => ['*']` and `credentials => 1`, the CORS middleware reflects
the request's Origin header as `Access-Control-Allow-Origin` with
`Access-Control-Allow-Credentials: true`. This means any website can make
credentialed cross-origin requests.

### Design

In `_init()`, detect the wildcard + credentials combination and `warn`:

```perl
if ($self->{credentials} && grep { $_ eq '*' } @{$self->{origins}}) {
    warn "PAGI::Middleware::CORS: WARNING - wildcard origins ('*') with "
       . "credentials enabled reflects any Origin. This allows any website "
       . "to make credentialed requests. Consider specifying explicit origins.\n";
}
```

We warn rather than die because this may be intentional in development. The
warning is emitted once at middleware construction time, not per-request.

### TDD Steps

1. **Test: wildcard + credentials emits warning** — construct CORS with
   `origins => ['*'], credentials => 1`, capture warnings, verify message
2. **Test: wildcard without credentials emits no warning** — construct with
   `origins => ['*'], credentials => 0`, verify no warning
3. **Test: explicit origins + credentials emits no warning** — construct with
   `origins => ['https://example.com'], credentials => 1`, verify no warning
4. **Test: behavior unchanged** — wildcard + credentials still reflects Origin
   (we warn, we don't change behavior)
5. Apply the warning
6. Verify existing CORS-related tests pass

### Files Changed
- **Modified:** `lib/PAGI/Middleware/CORS.pm` (add warning in `_init`, update POD)
- **New:** test for CORS warning behavior

---

## Fix 6: T10 — Rate limiter bucket cleanup

### Problem
`PAGI::Middleware::RateLimit` stores rate limit state in a package-level
`%buckets` hash that grows without bound. Every unique client IP creates an
entry that is never cleaned up. An attacker spoofing source IPs (or many
unique legitimate clients) causes unbounded memory growth.

Also: multi-worker limitation is not documented.

### Design

Add periodic cleanup of stale buckets. A bucket is "stale" if its tokens are
fully refilled (at burst capacity) and enough time has passed that any partial
tokens would have refilled. Add a `max_buckets` limit as a safety valve.

In `_check_rate_limit`, after the normal logic:

```perl
# Periodic cleanup: every 60 seconds, remove stale buckets
if (!$self->{_last_cleanup} || ($now - $self->{_last_cleanup}) >= 60) {
    $self->{_last_cleanup} = $now;
    my $stale_threshold = $now - (2 * $burst / $rate);  # 2x the time to fully refill
    for my $k (keys %buckets) {
        delete $buckets{$k}
            if $buckets{$k}{last_time} < $stale_threshold;
    }
}

# Safety valve: if somehow still too many, remove oldest
if (keys %buckets > ($self->{max_buckets} // 10_000)) {
    my @sorted = sort { $buckets{$a}{last_time} <=> $buckets{$b}{last_time} }
                 keys %buckets;
    delete $buckets{$_} for @sorted[0 .. int(@sorted / 2)];
}
```

Add `max_buckets` config option. Add multi-worker limitation to POD.

### TDD Steps

1. **Test: stale buckets are cleaned up** — create rate limiter, add many
   keys, advance time past stale threshold, verify cleanup occurs
2. **Test: active buckets are NOT cleaned up** — create entries, keep them
   active, verify they survive cleanup
3. **Test: max_buckets safety valve** — create more than max_buckets entries,
   verify oldest are evicted
4. **Test: cleanup doesn't affect rate limiting correctness** — verify that
   a client hitting the limit still gets 429 after cleanup runs
5. Apply the cleanup logic
6. Verify existing rate limit tests pass (if any)

### Files Changed
- **Modified:** `lib/PAGI/Middleware/RateLimit.pm` (add cleanup, max_buckets, update POD)
- **New:** `t/middleware/rate-limit.t` (or add to existing test file)

---

## Fix 7: T2 — SIGHUP documentation correction

### Problem
Server.pm POD says SIGHUP is "Useful for deploying new code without dropping
connections" but workers fork from the same parent — code is not reloaded.

### Design

Update the POD to accurately describe behavior:

```
=item B<SIGHUP> - Graceful worker restart (multi-worker only)

Performs a zero-downtime worker restart by terminating existing workers and
spawning replacements. Useful for recycling workers to reclaim leaked memory
or reset per-worker state.

B<Note:> This does NOT reload application code. New workers fork from the
existing parent process and inherit the same loaded code. For code deploys,
perform a full server restart.

    kill -HUP <pid>
```

### Files Changed
- **Modified:** `lib/PAGI/Server.pm` (update SIGHUP POD section)

---

## Test Infrastructure Notes

- All fixes use `Test2::V0`
- HTTP/2 tests must be gated on `Net::HTTP2::nghttp2` availability
- Rate limiter tests may need to mock `time()` for deterministic cleanup testing
- Utils::Random death test needs to mock `/dev/urandom` unavailability

## Commit Strategy

One commit per fix, in order:
1. `feat: add PAGI::Utils::Random, eliminate insecure rand() fallback`
2. `fix: remove double URL-decoding in Static middleware`
3. `fix: HTTP/2 path decoding to match HTTP/1.1 (UTF-8 + uri_unescape)`
4. `fix: session cookie defaults to SameSite=Lax`
5. `fix: CORS warns on wildcard origins with credentials`
6. `fix: rate limiter bucket cleanup and max_buckets safety valve`
7. `docs: correct SIGHUP documentation (worker recycle, not code reload)`
