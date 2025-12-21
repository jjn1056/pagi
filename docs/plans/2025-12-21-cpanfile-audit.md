# cpanfile Dependency Audit Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Audit cpanfile to ensure all dependencies are used, none are missing, and version numbers are appropriate.

**Architecture:** Grep codebase for module usage, cross-reference with cpanfile, fix discrepancies. Also fix remaining Perl version declarations in test files.

**Tech Stack:** Perl, cpanfile, grep

---

## Audit Summary

### Current cpanfile Dependencies

**Runtime:**
- perl 5.016 ✓
- IO::Async 0.802 ✓ (used)
- Future 0.50 ✓ (used)
- Future::AsyncAwait 0.66 ✓ (used)
- HTTP::Parser::XS 0.17 ✓ (used)
- Protocol::WebSocket 0.26 ✓ (used)
- IO::Async::SSL 0.25 ✓ (used)
- IO::Socket::SSL 2.074 ✓ (used via IO::Async::SSL)
- Sys::Sendfile 0.11 ✓ (optional, used)
- URI::Escape 5.09 ✓ (used in HTTP1.pm)
- JSON::MaybeXS 1.004003 ✗ NOT USED (code uses JSON::PP)
- Cookie::Baker 0.11 ✓ (used)

**Test:**
- Test2::V0 0.000159 ✓
- Test::Future::IO::Impl 0.14 ✓
- Net::Async::HTTP 0.49 ✓
- Net::Async::WebSocket::Client 0.14 ✓
- URI (MISSING - used in t/01-hello-http.t, t/08-tls.t)

### Issues Found

1. **JSON::MaybeXS** - Listed but not used (code uses core JSON::PP)
2. **URI** - Missing from test dependencies (used in tests)
3. **use v5.32** - 2 test files still declare Perl 5.32 requirement

---

### Task 1: Remove Unused JSON::MaybeXS

**Files:**
- Modify: `cpanfile`

**Step 1: Remove JSON::MaybeXS from cpanfile**

Remove line 26:
```perl
requires 'JSON::MaybeXS', '1.004003';
```

The codebase uses core `JSON::PP` instead.

**Step 2: Verify no code uses JSON::MaybeXS**

Run:
```bash
grep -r "JSON::MaybeXS" lib/ t/ examples/
```

Expected: No matches

**Step 3: Commit**

```bash
git add cpanfile
git commit -m "chore: remove unused JSON::MaybeXS dependency"
```

---

### Task 2: Add Missing URI Test Dependency

**Files:**
- Modify: `cpanfile`

**Step 1: Add URI to test dependencies**

In the `on 'test'` block, add:
```perl
requires 'URI', '1.60';
```

**Step 2: Verify URI is used in tests**

Run:
```bash
grep -r "^use URI" t/
```

Expected: Shows t/01-hello-http.t and t/08-tls.t

**Step 3: Commit**

```bash
git add cpanfile
git commit -m "chore: add missing URI test dependency"
```

---

### Task 3: Fix Perl Version Declarations in Tests

**Files:**
- Modify: `t/41-connection-limiting-stress.t`
- Modify: `t/26-max-requests.t`

**Step 1: Check what the files declare**

Run:
```bash
grep "use v5" t/41-connection-limiting-stress.t t/26-max-requests.t
```

**Step 2: Remove or update the version declarations**

Change `use v5.32;` to `use 5.016;` or remove entirely (cpanfile already declares minimum).

**Step 3: Verify tests still pass**

Run:
```bash
prove -l t/41-connection-limiting-stress.t t/26-max-requests.t
```

Expected: Tests pass

**Step 4: Commit**

```bash
git add t/
git commit -m "fix: update Perl version declarations in tests to 5.16"
```

---

### Task 4: Verify Version Numbers

**Step 1: Check current CPAN versions vs cpanfile**

Run:
```bash
cpan -D IO::Async Future Future::AsyncAwait HTTP::Parser::XS Protocol::WebSocket
```

Review output to ensure versions in cpanfile are reasonable minimums (not too old, not bleeding edge).

**Step 2: Document any version updates needed**

If any versions are outdated (causing install issues) or too new (excluding users), update cpanfile.

**Step 3: Commit if changes needed**

```bash
git add cpanfile
git commit -m "chore: update dependency version requirements"
```

---

### Task 5: Final Verification

**Step 1: Install dependencies fresh**

Run:
```bash
cpanm --installdeps .
```

Expected: All dependencies install successfully

**Step 2: Run full test suite**

Run:
```bash
prove -l t/
```

Expected: All 32 tests pass

**Step 3: Verify no missing modules at runtime**

Run:
```bash
perl -Ilib -c lib/PAGI/Server.pm
perl -Ilib -c lib/PAGI/Middleware/GZip.pm
perl -Ilib -c lib/PAGI/Middleware/Cookie.pm
```

Expected: All report "syntax OK"
