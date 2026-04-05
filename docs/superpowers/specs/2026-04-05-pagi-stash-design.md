# PAGI::Stash Design Spec

**Date:** 2026-04-05
**Status:** Draft

## Motivation

The `stash` accessor currently lives on PAGI::Request, PAGI::Response,
PAGI::WebSocket, and PAGI::SSE as a one-liner returning
`$self->{scope}{'pagi.stash'} //= {}`. This couples application-level
shared state to protocol-level helpers.

PAGI is a layered spec. The helpers (Request, Response, WebSocket, SSE)
are meant to be building blocks that framework authors can inherit from
or compose without inheriting opinions about application state. Framework
authors who want a typed stash, an object-based stash, or no stash at
all are currently fighting the built-in one.

Extracting stash into a standalone helper class solves this:

- Protocol helpers become purely protocol-focused
- Framework authors pick the layer they want
- The stash API gains structure (strict get, chaining, multi-key ops)
  aligned with the existing PAGI::Session helper
- PAGI::Context (future work) will compose Stash and Session

## Scope Key

Stash data lives at `$scope->{'pagi.stash'}`. This key is in the
reserved `pagi.*` namespace. It is lazily created on first access via
the helper. If no code uses PAGI::Stash, the key never appears in scope.

Middleware that shallow-copies scope (`{ %$scope, key => val }`)
preserves the stash hashref by reference. This is unchanged from
current behavior.

## Shared Constructor Convention

Both PAGI::Stash and PAGI::Session follow the same two-constructor
pattern. This eliminates the ambiguity of trying to distinguish a scope
hashref from a raw data hashref (both are `ref eq 'HASH'`).

### `new` — scope-based (normal usage)

```perl
my $obj = PAGI::Stash->new($scope);          # scope hashref
my $obj = PAGI::Stash->new($req);            # object with ->scope
my $obj = PAGI::Stash->new(@_);              # in a handler ($scope, $receive, $send)

my $obj = PAGI::Session->new($scope);        # scope hashref
my $obj = PAGI::Session->new($req);          # object with ->scope
my $obj = PAGI::Session->new(@_);            # in a handler
```

Resolution rules (same for both classes):

1. If the first arg is blessed and has a `scope` method, use
   `$arg->scope` to get the scope hashref.
2. If the first arg is an unblessed hashref, treat it as the scope.
3. Extra positional args (`$receive`, `$send`, etc.) are silently
   ignored.
4. Dies if no valid scope hashref can be resolved.

Stash accesses `$scope->{'pagi.stash'}` (lazily created).
Session accesses `$scope->{'pagi.session'}` (must exist, set by
middleware).

### `from_data` — raw data (testing convenience)

```perl
my $stash   = PAGI::Stash->from_data({ user => 'alice' });
my $session = PAGI::Session->from_data({ user_id => 42 });
```

Wraps a raw hashref directly as the backing data, bypassing scope
resolution. Intended for unit tests where constructing a full scope is
unnecessary overhead. The returned object behaves identically — all
methods work the same.

## PAGI::Stash

### Instance Lifecycle

Each call to `new` or `from_data` creates a fresh wrapper object. No
singleton caching. All instances sharing the same scope point at the
same underlying `$scope->{'pagi.stash'}` hashref.

### Methods

#### get

```perl
my $val  = $stash->get('user');                # strict: dies if missing
my $val  = $stash->get('theme', 'dark');       # permissive: returns default
my @vals = $stash->get('user', 'role');        # multi-key strict: dies on first missing
```

**Single key, no default:** Dies if key does not exist. Error message
lists available keys if 10 or fewer, otherwise reports the count.

**Single key with default:** Returns the default if the key is missing.
The two-argument form is distinguished from multi-key by context: if
exactly two args are passed, it is **always** treated as
`($key, $default)`. There is no way to do a strict multi-key get of
exactly two keys in a single call. Use two separate `get` calls or
`slice` instead. This is a deliberate trade-off: the `($key, $default)`
form is far more common than two-key batch gets, and Session already
established this convention.

**Three or more args:** Multi-key strict get. Returns a list of values
in the order of keys passed. Dies on the first missing key.

This matches PAGI::Session's `get` conventions.

#### set

```perl
$stash->set(user => $u);
$stash->set(user => $u, role => 'admin', debug => 1);
$stash->set(user => $u)->set(role => 'admin');
```

Accepts key-value pairs. Dies on odd number of args. Returns `$self`
for chaining.

#### exists

```perl
if ($stash->exists('user')) { ... }
```

Returns true (1) if the key exists, false (0) otherwise.

#### delete

```perl
$stash->delete('user');
$stash->delete('user', 'role', 'debug');
```

Removes one or more keys. Returns `$self` for chaining.

#### keys

```perl
my @keys = $stash->keys;
```

Returns all keys in the stash. Unlike Session, there are no reserved
internal keys to filter, so this returns everything.

#### slice

```perl
my %subset = $stash->slice('user', 'role', 'theme');
```

Returns a hash of key-value pairs for the requested keys. Keys that
do not exist are silently skipped. Matches Session's `slice` behavior.

#### data

```perl
my $href = $stash->data;
$href->{user} = $val;         # direct mutation
```

Returns the raw `$scope->{'pagi.stash'}` hashref (lazily created).
This is the escape hatch for code that wants unguarded hashref access.
Mutations to this hashref are visible through `get`/`set`/etc. since
they operate on the same reference.

### Error Messages

Strict `get` on a missing key:

```
# Few keys (10 or fewer)
Stash key 'user' does not exist. Available keys: auth_token, role, session_id

# Many keys (more than 10)
Stash key 'user' does not exist (stash has 47 keys)
```

### What PAGI::Stash Does NOT Have

- **`clear`** - YAGNI. Stash is request-scoped; it dies with the request.
- **`require`** - Session's strict `get` / permissive `get($key, $default)`
  pattern replaces it.
- **Events / hooks** - No `on_set`, `on_change`, etc. The method-based
  API (`set`/`get`) makes adding hook points later non-breaking if a
  real use case surfaces.
- **Middleware component** - No PAGI::Middleware::Stash. The helper is
  sufficient. Middleware that wants to pre-populate stash can set
  `$scope->{'pagi.stash'}` directly.

## Changes to Existing Code

### Add `scope` accessor to Request and Response

Request and Response currently lack a `scope` accessor. WebSocket and
SSE already have one. Add to both:

```perl
sub scope { shift->{scope} }
```

This fixes a latent bug in PAGI::Session's smart constructor, which
duck-types on `->scope` but silently fails for Request and Response
objects.

### Remove `stash` from helpers

Remove the `stash` method and its design-note comments from:

- `PAGI::Request` (lib/PAGI/Request.pm)
- `PAGI::Response` (lib/PAGI/Response.pm)
- `PAGI::WebSocket` (lib/PAGI/WebSocket.pm)
- `PAGI::SSE` (lib/PAGI/SSE.pm)

### Align PAGI::Session with PAGI::Stash conventions

Three changes to PAGI::Session:

**1. Constructor rewritten to shared convention.** Remove the current
three-way detection (raw hashref / scope hashref / object). Replace
with the shared `new` (scope-based) + `from_data` (raw hashref)
pattern described in "Shared Constructor Convention" above.

The current raw-data path (`PAGI::Session->new({})`) is replaced by
`PAGI::Session->from_data({})`. The `new` constructor now always
resolves to scope and accesses `$scope->{'pagi.session'}`.

**2. `set` returns `$self`** for chaining consistency:

```perl
# Before
sub set { ... }  # returns nothing

# After
sub set { ... return $self; }
```

**3. `delete` returns `$self`** for chaining consistency with Stash.

### Update tests

**PAGI::Stash (new):**

- Add comprehensive test suite (`t/stash/` or `t/stash.t`) covering:
  constructor via scope hashref, constructor via object with `->scope`,
  constructor via `@_` with extras ignored, `from_data`, get
  strict/permissive/multi-key, set single/multi/chaining, exists,
  delete, keys, slice, data, error messages (few keys vs many keys),
  scope sharing across multiple Stash instances, independence across
  different scopes.

**Stash removal from helpers:**

- `t/request-stash.t` — rewrite to test PAGI::Stash constructed from
  Request (via `->scope`), or remove if fully superseded by new Stash
  tests.
- `t/request/06-stash.t` — same treatment.
- `t/websocket/11-stash-and-callbacks.t` — rewrite stash subtests to
  use PAGI::Stash; callback subtests are unaffected.
- `t/websocket-state.t`, `t/sse-router-support.t`,
  `t/response-convenience.t`, `t/request-state.t` — audit for any
  `->stash` calls and update.

**Request/Response `scope` accessor:**

- Add tests for `$req->scope` and `$res->scope` returning the scope
  hashref.

**PAGI::Session changes:**

- `t/middleware/session/helper.t` — ~25 calls to
  `PAGI::Session->new({...})` must change to
  `PAGI::Session->from_data({...})`. The scope-based and object-based
  constructor tests remain on `new`.
- Add tests for Session `set` chaining.
- Add tests for Session `delete` chaining.
- Verify `PAGI::Session->new(@_)` works with extra args ignored.

**Integration tests:**

- `t/endpoint-router.t`, `t/sse/10-integration.t` — audit for
  `->stash` usage and update to use PAGI::Stash.

### Update documentation

**Remove `stash` accessor references from POD in:**

- `PAGI::Request` — remove `stash` method docs and stash examples
- `PAGI::Response` — remove `stash` method docs
- `PAGI::WebSocket` — remove `stash` method docs, update feature list
- `PAGI::SSE` — remove `stash` method docs, update feature list
- `PAGI::Endpoint::Router` — rewrite "stash" section to reference
  PAGI::Stash, update middleware/handler examples
- `PAGI::Endpoint::WebSocket` — update stash examples
- `PAGI::Endpoint::SSE` — update stash examples
- `PAGI::Cookbook` — update all `->stash` usage examples
- `PAGI::Tutorial` — update `$scope->{'pagi.stash'}` examples to show
  PAGI::Stash helper usage
- `PAGI` (main module) — update "state/stash accessors" references

**Add cross-references** to PAGI::Stash where stash was previously
documented. Each removed `stash` section should note:
"See L<PAGI::Stash> for per-request shared state."

**Update PAGI::Session POD:**

- Rewrite SYNOPSIS to show `new($scope)` and `from_data({})` forms
- Update CONSTRUCTOR section to document both `new` and `from_data`
- Remove the raw-hashref constructor form from examples
- Document `set` and `delete` chaining in method docs

**Update PAGI::Middleware::Session POD:**

- Update PAGI::Session helper section to show `new($scope)` form
- Update inline example (`$s = PAGI::Session->new($scope->{'pagi.session'})`)
  to `$s = PAGI::Session->new($scope)`

## API Comparison: Stash vs Session

Both helpers follow the same constructor and accessor conventions:

| Feature | Stash | Session |
|---------|-------|---------|
| `new($scope)` | scope-based | scope-based (changed) |
| `new($obj_with_scope)` | duck-typed | duck-typed (changed) |
| `new(@_)` extras ignored | yes | yes (changed) |
| `from_data($href)` | test convenience | test convenience (changed) |
| `get($key)` | strict, dies | strict, dies |
| `get($key, $default)` | permissive | permissive |
| `get(@keys)` (3+) | multi-key strict | not yet (could add) |
| `set(k => v, ...)` | multi-pair, chains | multi-pair, chains (changed) |
| `exists($key)` | boolean | boolean |
| `delete(@keys)` | multi-key, chains | multi-key, chains (changed) |
| `keys` | all keys | user keys (filters `_` prefix) |
| `slice(@keys)` | skip missing | skip missing |
| `data` | raw hashref | n/a (internal `_data`) |
| `id` | n/a | session ID |
| `regenerate` | n/a | session lifecycle |
| `destroy` | n/a | session lifecycle |
| `clear` | n/a | wipe user keys |

## Future: PAGI::Context

PAGI::Context will compose Stash, Session, and other helpers into a
single framework-level object. This is out of scope for this spec but
informs the design: Stash must work standalone and compose cleanly.

```perl
# Future (not part of this work)
my $ctx = PAGI::Context->new(@_);
$ctx->stash->get('user');
$ctx->session->get('user_id');
$ctx->request->method;
```
