# Router Features Design: Regex Escaping, Constraints, and any()

**Date**: 2026-02-17
**Status**: Approved
**Scope**: PAGI::App::Router (lib/PAGI/App/Router.pm)

## Overview

Three improvements to the PAGI router, addressing a correctness bug and adding two frequently-requested features.

## Feature #1: Regex Escaping of Literal Path Segments

### Problem

`_compile_path()` interpolates the raw path string into a regex without escaping. Paths containing regex metacharacters (e.g., `/api/v1.0/users`) produce incorrect patterns — `.` matches any character instead of a literal dot.

### Solution

Replace the current regex-substitution approach with a tokenizer that:

1. Splits the path into tokens: literal segments, `:name` params, `{name}` params, `{name:pattern}` constrained params, and `*name` wildcards
2. Applies `quotemeta()` to literal segments
3. Joins tokens into the final regex

No API change. Existing routes work identically; paths with metacharacters now match correctly.

### Affected Code

- `_compile_path()` — full rewrite (currently lines 163-180)

## Feature #2: Regex Constraints on Path Parameters

### Problem

All path parameters currently match `[^/]+`. There is no way to restrict a parameter to, say, digits only. Routes must do their own validation in the handler.

### Solution

Two complementary syntaxes:

**Inline syntax**: `{id:\d+}` — constraint embedded in the path pattern.

```perl
$router->get('/users/{id:\d+}', $handler);
```

**Chained syntax**: `->constraints(name => qr/pattern/)` — applied after route registration.

```perl
$router->get('/users/:id', $handler)->constraints(id => qr/^\d+$/);
```

Both store constraints on the route entry. During dispatch, after the path regex matches, each captured parameter is checked against its constraint. If any constraint fails, the route does not match (falls through to subsequent routes).

Constraints are regex-only for now. Coderef constraints are deferred to a future release (requires pass/fall-through semantics from TODO #8).

### Affected Code

- `_compile_path()` — extended to parse `{name}` and `{name:pattern}` tokens
- `route()` — store constraints on the route entry
- New `constraints()` method — chainable, merges regex constraints onto the route
- `to_app()` dispatch — add constraint checking after path match
- `uri_for()` — understand `{name}` and `{name:pattern}` in path templates

## Feature #3: `any()` Multi-Method Matcher

### Problem

Registering the same handler for multiple HTTP methods requires duplicate route entries. There is no wildcard method matcher.

### Solution

New `any()` method with two modes:

**Wildcard** (no method restriction):
```perl
$router->any('/health', $handler);
```

**Explicit list**:
```perl
$router->any('/resource', $handler, method => ['GET', 'POST']);
```

Internal storage: `method => '*'` for wildcard, `method => ['GET', 'POST']` for explicit lists.

Dispatch logic:
- `method => '*'` matches any HTTP method
- `method => [list]` matches if the request method is in the list
- 405 responses include `Allow` header computed from all matching paths (including `any()` routes)

### Affected Code

- New `any()` method (alongside get/post/put/etc.)
- `route()` — accept arrayref or `'*'` for method
- `to_app()` dispatch — updated method matching logic
- 405 handler — updated Allow header computation

## Backward Compatibility

- Existing `:name` syntax continues to work unchanged
- Existing `*name` wildcard syntax continues to work unchanged
- `_compile_path()` rewrite produces identical regex output for all existing path patterns
- No changes to WebSocket or SSE routing behavior

## Future Direction

Coderef constraints (e.g., `constraints(id => sub { ... })`) are deferred. They require pass/fall-through semantics (TODO #8) so that a failed coderef constraint can skip to the next matching route rather than returning a hard error. See TODO_router.md #9b for design notes.
