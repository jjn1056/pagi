# Route Grouping (`group()`) Design

**Date**: 2026-02-17
**Status**: Approved
**Scope**: PAGI::App::Router (lib/PAGI/App/Router.pm)

## Overview

Add `group()` to `PAGI::App::Router` for organizing routes under a shared prefix with shared middleware, while keeping them flattened in the parent router's dispatch table. This differs from `mount()` which creates a separate dispatch context.

## API: Three Forms

### Callback Form

```perl
$router->group('/api' => [$auth] => sub {
    my ($r) = @_;
    $r->get('/users' => $handler);      # GET /api/users
    $r->post('/users' => $handler);     # POST /api/users
});
```

### Router-Object Form

```perl
my $api = PAGI::App::Router->new;
$api->get('/users' => $handler);

$router->group('/api' => [$auth] => $api);
```

### String Form

```perl
$router->group('/api/users' => [$auth] => 'MyApp::Routes::Users');
# internally: require MyApp::Routes::Users; MyApp::Routes::Users->router
```

All three accept optional middleware array between prefix and target. All flatten routes into the parent.

## Flattening Semantics

When `group()` is called, routes are registered on the parent with prefix prepended to paths and group middleware prepended to each route's middleware chain:

```perl
# What the user writes:
$router->group('/api' => [$auth] => sub {
    my ($r) = @_;
    $r->get('/users' => [$rate_limit] => $handler);
});

# What the parent stores (flattened):
# Route: GET /api/users => middleware: [$auth, $rate_limit] => $handler
```

- **Path prefix prepended** to each route's path
- **Middleware prepended** — group middleware before route-level middleware
- **Regex compiled once** from the full prefixed path (no recompilation)
- **All route types** — HTTP, WebSocket, and SSE routes all flatten
- **Snapshot semantics** (router-object and string forms) — routes copied at call time
- **Callback form** — routes register immediately through the real router

### Nested Groups

Prefix and middleware accumulate naturally:

```perl
$router->group('/orgs/:org_id' => [$load_org] => sub {
    my ($r) = @_;
    $r->group('/teams/:team_id' => [$load_team] => sub {
        my ($r) = @_;
        $r->get('/members' => $handler);
        # Stored as: GET /orgs/:org_id/teams/:team_id/members
        # Middleware: [$load_org, $load_team]
    });
});
```

## Implementation: Prefix Stack

The router maintains a `_group_stack` array. `group()` pushes context, executes/copies, then pops. Route registration methods (`route()`, `websocket()`, `sse()`) check the stack and prepend accumulated prefix/middleware before compiling.

```perl
sub group {
    my ($self, $prefix, @rest) = @_;
    my ($mw, $target) = $self->_parse_route_args(@rest);

    push @{$self->{_group_stack}}, { prefix => $prefix, middleware => $mw };

    if (ref($target) eq 'CODE') {
        $target->($self);  # callback gets real router
    }
    elsif (blessed($target) && $target->isa('PAGI::App::Router')) {
        # Re-register source routes through route()/websocket()/sse()
        # Stack applies prefix and middleware automatically
    }
    elsif (!ref($target)) {
        # String: require, call ->router, treat as router-object
    }

    pop @{$self->{_group_stack}};
}
```

In `route()`, `websocket()`, `sse()`:

```perl
# Apply accumulated group context
for my $ctx (@{$self->{_group_stack} // []}) {
    $path = $ctx->{prefix} . $path;
    unshift @$middleware, @{$ctx->{middleware}};
}
```

Routes are registered correctly from the start. No fixup. No double compilation. No constraint loss.

## Constraint Storage Refactor

Split internal constraint storage into two fields:

- `$route->{constraints}` — inline constraints from `_compile_path()` (from `{name:pattern}` syntax)
- `$route->{_user_constraints}` — chained constraints from `->constraints()` method

`_check_constraints()` checks both arrays. External behavior is identical. This makes route copying for the router-object form clean — inline constraints come from recompiling the full prefixed path, chained constraints are copied from the source route.

## Type Detection in `group()`

```perl
if (ref($target) eq 'CODE') {
    # Callback form
}
elsif (blessed($target) && $target->isa('PAGI::App::Router')) {
    # Router-object form
}
elsif (!ref($target)) {
    # String form: require $target, call $target->router
    # Dies if require fails or ->router doesn't exist
    # Validates return is PAGI::App::Router
}
else {
    croak "group() target must be a coderef, PAGI::App::Router, "
        . "or package name, got " . ref($target);
}
```

## Named Routes

- Named routes inside groups register with the full prefixed path automatically (stack is applied before `name()`)
- **Conflict**: croak immediately if a named route already exists on the parent
- **`as()` chaining**: `$router->group(...)->as('ns')` prefixes all named routes added during that group with the namespace
- Requires tracking which named routes were added during the group call (snapshot keys before, diff after)

## Difference from `mount()`

| Aspect | `group()` | `mount()` |
|--------|-----------|-----------|
| Route storage | Flattened into parent | Separate app |
| 405 handling | Unified with parent | Independent per mount |
| Named routes | Directly on parent | Requires `as()` to import |
| Path stripping | No — full path preserved | Yes — prefix stripped |
| Route introspection | Visible in parent | Opaque (separate app) |
| Use case | Organizing routes within one app | Composing independent apps |

## What `group()` Does NOT Support

- **`mount` inside callback groups** — not prefixed; registers on parent as-is
- **`PAGI::Endpoint::Router` detection** — deferred; string form only calls `->router` and expects `PAGI::App::Router`

## Backward Compatibility

Fully backward compatible. Existing code doesn't use groups — the stack is empty and route registration has zero overhead (empty array iteration skipped).
