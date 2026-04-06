# PAGI::Context Design Spec

## Problem

PAGI handlers currently receive raw `($scope, $receive, $send)` and must
construct multiple helper objects manually:

```perl
async sub handler ($scope, $receive, $send) {
    my $req     = PAGI::Request->new($scope, $receive);
    my $res     = PAGI::Response->new($scope, $send);
    my $stash   = PAGI::Stash->new($scope);
    my $session = PAGI::Session->new($scope);
    # ...
}
```

The `Endpoint::Router` reduces this by injecting `($req, $res)` or `($ws)`
or `($sse)`, but handler signatures differ by protocol type and there is no
single object that provides access to both protocol I/O and shared state
(stash, session).

## Goals

- **One object per request** that provides lazy access to protocol helpers
  and shared state.
- **Protocol-appropriate methods** — HTTP contexts have `request`/`response`,
  WebSocket contexts have `websocket`, SSE contexts have `sse`. Methods that
  don't apply to a protocol simply don't exist.
- **Unified handler signature** — `$endpoint->$method($ctx)` for all protocol
  types.
- **Extensible** — application frameworks can subclass to add custom protocol
  types or app-specific convenience methods.
- **No new dependencies** — plain Perl OOP using inheritance.
- **Testable** — constructable from a plain scope hashref without a running
  server.
- **Non-breaking** — existing code using raw `($scope, $receive, $send)` or
  protocol helpers directly continues to work unchanged.

## Non-Goals

- Response-sending methods on Context (no `$ctx->json()`). Response building
  stays on `PAGI::Response`.
- Replacing or modifying `PAGI::Stash`, `PAGI::Session`, `PAGI::Request`,
  `PAGI::Response`, `PAGI::SSE`, or `PAGI::WebSocket`. Context wraps them;
  it does not replace them.
- Dependency injection. Context is a coordinator, not a DI container.

## Architecture

### Class Hierarchy

```
PAGI::Context                  — factory + shared methods (base class)
  PAGI::Context::HTTP          — adds request, response, method
  PAGI::Context::WebSocket     — adds websocket
  PAGI::Context::SSE           — adds sse
```

All subclasses inherit from `PAGI::Context`. `$ctx->isa('PAGI::Context')`
returns true for every context type.

### Factory Pattern

`PAGI::Context->new(...)` inspects `$scope->{type}` and blesses into the
appropriate subclass. The mapping and resolution are split into two
overridable methods for extensibility:

```perl
package PAGI::Context;

sub _type_map {
    return {
        http      => 'PAGI::Context::HTTP',
        websocket => 'PAGI::Context::WebSocket',
        sse       => 'PAGI::Context::SSE',
    };
}

sub _resolve_class {
    my ($class, $scope) = @_;
    my $type = $scope->{type} // 'http';
    return $class->_type_map->{$type} // $class->_type_map->{http};
}

sub new {
    my ($class, $scope, $receive, $send) = @_;
    my $subclass = $class->_resolve_class($scope);
    return bless {
        scope   => $scope,
        receive => $receive,
        send    => $send,
    }, $subclass;
}
```

### Extension Points

**Adding a protocol type** — override `_type_map`:

```perl
package MyApp::Context;
our @ISA = ('PAGI::Context');

sub _type_map {
    my ($class) = @_;
    return {
        %{ $class->SUPER::_type_map },
        grpc => 'MyApp::Context::GRPC',
    };
}
```

**Replacing a built-in type** — same mechanism:

```perl
sub _type_map {
    my ($class) = @_;
    return {
        %{ $class->SUPER::_type_map },
        http => 'MyApp::Context::HTTP',
    };
}
```

**Custom resolution logic** — override `_resolve_class`:

```perl
sub _resolve_class {
    my ($class, $scope) = @_;
    # Upgrade WebSocket contexts that have a specific subprotocol
    if (($scope->{type} // '') eq 'websocket') {
        my $proto = _extract_subprotocol($scope);
        return 'MyApp::Context::JsonRPC' if $proto eq 'jsonrpc';
    }
    return $class->SUPER::_resolve_class($scope);
}
```

## PAGI::Context (Base Class)

### Constructor

```perl
my $ctx = PAGI::Context->new($scope, $receive, $send);
```

Returns a `PAGI::Context::HTTP`, `PAGI::Context::WebSocket`, or
`PAGI::Context::SSE` instance based on `$scope->{type}`.

### Test Constructor

```perl
my $ctx = PAGI::Context->new(
    { type => 'http', method => 'GET', path => '/test', headers => [] },
    sub { Future->done({}) },    # mock receive
    sub { Future->done },        # mock send
);
```

### Shared Methods (All Protocol Types)

#### Scope Access

| Method         | Returns                              |
|----------------|--------------------------------------|
| `scope`        | Raw `$scope` hashref                 |
| `type`         | `$scope->{type}` (`http`, `websocket`, `sse`) |
| `path`         | `$scope->{path}`                     |
| `raw_path`     | `$scope->{raw_path}` // `$scope->{path}` |
| `query_string` | `$scope->{query_string}` // `''`     |
| `scheme`       | `$scope->{scheme}` // `'http'`       |
| `client`       | `$scope->{client}` (`[host, port]`)  |
| `server`       | `$scope->{server}` (`[host, port]`)  |
| `headers`      | Raw `$scope->{headers}` arrayref of `[name, value]` pairs |

#### State Accessors (Lazy, Cached)

| Method    | Returns                     | Notes                                |
|-----------|-----------------------------|--------------------------------------|
| `stash`   | `PAGI::Stash` instance      | Wraps `$scope->{'pagi.stash'}`       |
| `session` | `PAGI::Session` instance    | Dies if session middleware not loaded |
| `state`   | `$scope->{state}` hashref   | App/endpoint-level shared state      |

These are constructed on first access and cached on the context object for
the lifetime of the request.

#### Protocol Introspection

| Method         | Returns                              |
|----------------|--------------------------------------|
| `is_http`      | `$self->type eq 'http'`              |
| `is_websocket` | `$self->type eq 'websocket'`         |
| `is_sse`       | `$self->type eq 'sse'`               |

#### Connection State

| Method              | Returns / Behavior                            |
|---------------------|-----------------------------------------------|
| `connection`        | `PAGI::Server::ConnectionState` object        |
| `is_connected`      | Boolean — client still connected?             |
| `is_disconnected`   | Boolean — inverse of `is_connected`           |
| `disconnect_reason` | String reason or `undef`                      |
| `on_disconnect($cb)`| Register disconnect callback                  |

These delegate to `$scope->{'pagi.connection'}`, mirroring the existing
pattern in `PAGI::Request`.

#### Header Lookup

| Method              | Returns                                      |
|---------------------|----------------------------------------------|
| `header($name)`     | Last value for header (case-insensitive)      |

Single header lookup is useful across all protocols (WebSocket and SSE scopes
carry the upgrade request headers). The full `Hash::MultiValue` headers
object stays on `PAGI::Request` since it's primarily an HTTP convenience.

#### Raw Protocol Access

| Method    | Returns              |
|-----------|----------------------|
| `receive` | The `$receive` coderef |
| `send`    | The `$send` coderef    |

Escape hatch for raw PAGI protocol access.

## PAGI::Context::HTTP

Inherits all shared methods from `PAGI::Context`.

### Additional Methods

| Method     | Returns                    | Notes                           |
|------------|----------------------------|---------------------------------|
| `request`  | `PAGI::Request` instance   | Lazy, cached                    |
| `response` | `PAGI::Response` instance  | Lazy, cached                    |
| `method`   | `$scope->{method}`         | HTTP method string              |

```perl
sub request {
    my ($self) = @_;
    return $self->{_request} //= do {
        require PAGI::Request;
        PAGI::Request->new($self->{scope}, $self->{receive});
    };
}

sub response {
    my ($self) = @_;
    return $self->{_response} //= do {
        require PAGI::Response;
        PAGI::Response->new($self->{scope}, $self->{send});
    };
}

sub method { shift->{scope}{method} }
```

## PAGI::Context::WebSocket

Inherits all shared methods from `PAGI::Context`.

### Additional Methods

| Method      | Returns                     | Notes        |
|-------------|-----------------------------|--------------|
| `websocket` | `PAGI::WebSocket` instance  | Lazy, cached |

```perl
sub websocket {
    my ($self) = @_;
    return $self->{_websocket} //= do {
        require PAGI::WebSocket;
        PAGI::WebSocket->new($self->{scope}, $self->{receive}, $self->{send});
    };
}
```

Note: `PAGI::WebSocket->new` already caches in `$scope->{'pagi.websocket'}`,
so the lazy cache here is belt-and-suspenders. Both caching layers are cheap
and correct.

## PAGI::Context::SSE

Inherits all shared methods from `PAGI::Context`.

### Additional Methods

| Method | Returns                | Notes        |
|--------|------------------------|--------------|
| `sse`  | `PAGI::SSE` instance   | Lazy, cached |

```perl
sub sse {
    my ($self) = @_;
    return $self->{_sse} //= do {
        require PAGI::SSE;
        PAGI::SSE->new($self->{scope}, $self->{receive}, $self->{send});
    };
}
```

Same caching note as WebSocket — `PAGI::SSE->new` caches in scope.

## Router Integration

`PAGI::Endpoint::Router` currently wraps handlers to inject protocol-specific
objects. With Context, all handler types receive `($ctx)`:

### Current (Before)

```perl
# HTTP:      $endpoint->$method($req, $res)
# WebSocket: $endpoint->$method($ws)
# SSE:       $endpoint->$method($sse)
```

### New (After)

```perl
# All types:  $endpoint->$method($ctx)
```

The `_wrap_http_handler`, `_wrap_websocket_handler`, and `_wrap_sse_handler`
methods in `PAGI::Endpoint::Router::RouteBuilder` change from constructing
protocol objects to constructing a `PAGI::Context`:

```perl
sub _wrap_http_handler {
    my ($self, $handler) = @_;
    my $endpoint = $self->{endpoint};

    if (!ref($handler)) {
        my $method_name = $handler;
        my $method = $endpoint->can($method_name)
            or die "No such method: $method_name in " . ref($endpoint);

        return async sub {
            my ($scope, $receive, $send) = @_;
            my $ctx = PAGI::Context->new($scope, $receive, $send);
            await $endpoint->$method($ctx);
        };
    }

    return async sub {
        my ($scope, $receive, $send) = @_;
        my $ctx = PAGI::Context->new($scope, $receive, $send);
        await $handler->($ctx);
    };
}
```

WebSocket and SSE wrappers follow the same pattern — they all construct
`PAGI::Context->new($scope, $receive, $send)`. The factory handles
returning the right subclass.

### Endpoint Middleware

Endpoint middleware currently receives `($req, $res, $next)`. With Context
it receives `($ctx, $next)`:

```perl
# Before
sub auth_check ($self, $req, $res, $next) { ... }

# After
sub auth_check ($self, $ctx, $next) { ... }
```

## App Framework Extension Example

An application framework building on PAGI can subclass Context to provide
app-specific conveniences:

```perl
package MyApp::Context;
our @ISA = ('PAGI::Context');

sub _type_map {
    my ($class) = @_;
    return {
        %{ $class->SUPER::_type_map },
        http      => 'MyApp::Context::HTTP',
        websocket => 'MyApp::Context::WebSocket',
        sse       => 'MyApp::Context::SSE',
    };
}

package MyApp::Context::HTTP;
our @ISA = ('PAGI::Context::HTTP');

sub current_user {
    my ($self) = @_;
    return $self->stash->get('current_user');
}

sub db {
    my ($self) = @_;
    return $self->stash->get('db_pool');
}

sub authorize {
    my ($self, $permission) = @_;
    my $user = $self->current_user;
    die "Forbidden\n" unless $user->has_permission($permission);
}
```

The endpoint uses `MyApp::Context` as its context class:

```perl
package MyApp::Endpoint::Users;
our @ISA = ('PAGI::Endpoint::Router');

# Hypothetical: endpoint declares its context class
sub context_class { 'MyApp::Context' }

sub routes {
    my ($self, $r) = @_;
    $r->get('/users', 'list_users');
}

sub list_users {
    my ($self, $ctx) = @_;
    $ctx->authorize('users.read');
    my $users = $ctx->db->select('users');
    await $ctx->response->json({ users => $users });
}
```

How the router uses `context_class` is an implementation detail — the
simplest approach is for `Endpoint::Router` to call
`$self->context_class->new(...)` in the wrapper methods, defaulting to
`'PAGI::Context'`.

## File Layout

```
lib/PAGI/Context.pm              — base class + factory + shared methods
lib/PAGI/Context/HTTP.pm         — HTTP subclass
lib/PAGI/Context/WebSocket.pm    — WebSocket subclass
lib/PAGI/Context/SSE.pm          — SSE subclass
t/context/                       — test directory
t/context/01-factory.t           — factory resolution, _type_map, _resolve_class
t/context/02-shared.t            — shared methods (scope, stash, session, etc.)
t/context/03-http.t              — HTTP-specific methods
t/context/04-websocket.t         — WebSocket-specific methods
t/context/05-sse.t               — SSE-specific methods
t/context/06-extension.t         — subclassing and custom type maps
t/context/07-router.t            — Endpoint::Router integration
```

## Testing Strategy

Context must be constructable without a running server:

```perl
use Test2::V0;
use PAGI::Context;

# HTTP context from plain scope hash
my $ctx = PAGI::Context->new(
    { type => 'http', method => 'GET', path => '/test', headers => [] },
    sub { Future->done({}) },
    sub { Future->done },
);

isa_ok $ctx, 'PAGI::Context';
isa_ok $ctx, 'PAGI::Context::HTTP';
is $ctx->type, 'http';
is $ctx->method, 'GET';
is $ctx->path, '/test';
ok $ctx->can('request');
ok $ctx->can('response');
ok !$ctx->can('websocket');
ok !$ctx->can('sse');

# Stash works
$ctx->stash->set(user => 'alice');
is $ctx->stash->get('user'), 'alice';

# WebSocket context
my $ws_ctx = PAGI::Context->new(
    { type => 'websocket', path => '/ws', headers => [] },
    sub { Future->done({}) },
    sub { Future->done },
);

isa_ok $ws_ctx, 'PAGI::Context::WebSocket';
ok $ws_ctx->can('websocket');
ok !$ws_ctx->can('request');
ok !$ws_ctx->can('response');
```

## Design Decisions

### Why not a god object?

The Perl ecosystem's own history shows the progression away from god objects
(Catalyst's `$c` → Mojolicious's leaner `$c` → PSGI's minimal `$env`).
Context provides access to protocol helpers but does not absorb their
methods. `$ctx->response->json(...)`, not `$ctx->json(...)`.

### Why subclasses instead of runtime guards?

Protocol-inappropriate methods don't exist rather than existing-but-guarded.
This is standard OOP — a WebSocket context IS-NOT an HTTP context. The
standard Perl "Can't locate object method" error is the same pattern used
by Phoenix, Go, and other frameworks with protocol-specific context types.

### Why subclasses instead of roles?

PAGI uses plain `bless` OOP throughout. Adding a Role::Tiny dependency for
three small subclasses is unnecessary machinery. Plain inheritance is
simpler, sufficient, and matches the codebase style.

### Why `_type_map` and `_resolve_class` as separate methods?

Two extension points, each with one responsibility. Most extensions only
need to override `_type_map` (adding or replacing a mapping). Custom
resolution logic (inspecting scope beyond the type field) overrides
`_resolve_class`. Separating them means the common case is a one-method
override.

### Why lazy protocol helpers?

Not all handlers need all helpers. A handler that only reads the stash
shouldn't pay for constructing a `PAGI::Request` with its header parsing
infrastructure. Lazy construction is free until used.

### What about `Endpoint::Router` context_class?

The `context_class` method on endpoints allows app frameworks to specify
their Context subclass without modifying the router. This is the hook
that makes the App Framework Extension Example work. Defaults to
`'PAGI::Context'`.

## Migration

Context is additive. No existing code breaks.

1. Add `PAGI::Context` and subclasses (new files only).
2. Update `PAGI::Endpoint::Router` to inject `$ctx` instead of `($req, $res)` / `($ws)` / `($sse)`.
3. Update existing `PAGI::Endpoint::Router` subclasses to use the new `($ctx)` handler signature.
4. Raw PAGI apps using `($scope, $receive, $send)` directly are unaffected.
5. Direct use of `PAGI::Request`, `PAGI::Response`, `PAGI::Stash`, etc. continues to work.
