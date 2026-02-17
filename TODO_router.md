# PAGI::App::Router — Feature Gap Analysis & Roadmap

## Context

This document catalogs missing features in `PAGI::App::Router` based on a comprehensive
survey of routers across Perl, Python, Ruby, JavaScript, Go, and Rust ecosystems.

**Long-term goal**: PAGI::App::Router must be flexible enough to serve as the foundation
for a "CatalystNextGeneration" framework, where Catalyst-style chained dispatch compiles
down to router primitives (groups, mounts, middleware) without requiring a custom router.

**Date**: 2026-02-16

---

## What PAGI::App::Router Already Does Well

- Named params (`:id`) and wildcards (`*path`)
- All 7 HTTP methods (GET, POST, PUT, PATCH, DELETE, HEAD, OPTIONS)
- Automatic HEAD → GET fallback
- Separate WebSocket and SSE route tables (rare — only Mojolicious and Starlette do this)
- Per-route middleware with onion model (coderefs or objects with `call()`)
- Mount system with prefix stripping, `root_path` accumulation, longest-prefix-first
- Named routes via `name()`, URL generation via `uri_for()`, namespaced mounts via `as()`
- Proper 404 (custom or default) and 405 Method Not Allowed with `Allow` header
- Pre-built middleware chains at `to_app()` time for efficiency
- Method chaining on all registration methods
- Lifespan scope silently ignored (correct PAGI protocol behavior)
- Scope additions: `path_params`, `pagi.router.route`

---

## Feature Gap Table (Priority Order)

| # | Feature | Importance | CatalystNextGen Need |
|---|---------|------------|---------------------|
| 1 | Regex escaping of literal path segments (bug fix) | **Critical** | Correctness — everything breaks without it |
| 2 | Regex constraints on path parameters | **Critical** | CaptureArgs type validation |
| 3 | `any()` multi-method matcher | **Critical** | Catalyst `any` HTTP method matching |
| 4 | Route grouping with path params + per-group middleware | **Critical** | THE key primitive for Catalyst-style chaining |
| 4b | `group()` Router-object overload (include) | **Critical** | Multi-file route composition without callbacks |
| 5 | Path params in mount prefixes | **Critical** | Mounting independent apps at parameterized paths |
| 6 | Optional path segments | **High** | Optional CaptureArgs, optional trailing PathParts |
| 7 | Route introspection | **High** | Debug dispatch chains, `./myapp routes` equivalent |
| 7b | Per-route metadata (`->meta()`) | **Medium** | OpenAPI generation, framework tooling, CatalystNextGen |
| 8 | `pass` / fall-through to next matching route | **High** | Catalyst `forward` to next matching action |
| 9 | Custom path types / converters | **Medium** | Reusable CaptureArgs types across chains |
| 9b | `find_type_via()` external type registry hook | **Medium** | Shared types across routers, Type::Tiny integration |
| 10 | Trailing slash policy | **Medium** | Consistent URL normalization for framework users |
| 11 | Redirect routes | **Medium** | Convenience for common pattern |
| 12 | Host-based routing | **Medium-Low** | Multi-tenant / subdomain apps |
| 13 | Param middleware | **Medium-Low** | Auto-load resource when param appears |
| 14 | Content negotiation / format detection | **Low** | Format-based dispatch (.json, .html) |
| 15 | Custom conditions / guards | **Low** | Arbitrary request predicates |
| 16 | RESTful resource generation | **Low** | Auto-generate CRUD routes |
| 17 | Route caching | **Low** | Performance optimization for repeated paths |
| 18 | Versioned routing | **Low** | API versioning via Accept-Version header |
| 19 | `on_event()` custom scope type routing | **For Consideration** | Extensible dispatch beyond http/websocket/sse |

---

## Detailed Feature Descriptions

---

### 1. Regex Escaping of Literal Path Segments

**Importance**: Critical (bug fix)

**Problem**: The current `_compile_path()` method converts path strings directly to regex
without escaping regex metacharacters in the literal (non-parameter) portions of the path.

```perl
# Current code (lib/PAGI/App/Router.pm lines 163-180):
sub _compile_path {
    my ($self, $path) = @_;
    my @names;
    my $regex = $path;

    if ($regex =~ s{\*(\w+)}{(.+)}g) {
        push @names, $1;
    }
    while ($regex =~ s{:(\w+)}{([^/]+)}) {
        push @names, $1;
    }
    return (qr{^$regex$}, @names);
}
```

The characters `.`, `+`, `?`, `(`, `)`, `[`, `]`, `{`, `}`, `^`, `$`, `|`, `\` in literal
path segments are NOT escaped. This means:

- `/api/v1.0/users` — the `.` matches ANY character, so `/api/v1X0/users` also matches
- `/path/file+name` — the `+` means "one or more of previous char"
- `/path/(section)` — the `()` creates a capture group

**Found in**: Every router handles this correctly (implicitly or explicitly). Mojolicious,
Express, Starlette, Rails, etc. all treat literal path text as literal.

**Fix**: Escape literal segments before inserting parameter capture groups. The path should
be split into literal parts and parameter parts, with `quotemeta()` applied to the literal
parts.

**Proposed implementation sketch**:

```perl
sub _compile_path {
    my ($self, $path) = @_;
    my @names;
    my $regex = '';

    # Split path into tokens: literal text, :params, *wildcards
    my @tokens = split m{(\*\w+|:\w+)}, $path;

    for my $token (@tokens) {
        if ($token =~ /^\*(\w+)$/) {
            push @names, $1;
            $regex .= '(.+)';
        }
        elsif ($token =~ /^:(\w+)$/) {
            push @names, $1;
            $regex .= '([^/]+)';
        }
        else {
            $regex .= quotemeta($token);  # Escape metacharacters
        }
    }

    return (qr{^$regex$}, @names);
}
```

**No API change** — this is purely an internal correctness fix.

---

### 2. Regex Constraints on Path Parameters

**Importance**: Critical

**Problem**: Currently `:id` matches ANY non-slash string. There is no way to constrain
parameters to specific patterns (e.g., numeric only). This means:

- `/users/:id` matches `/users/new`, `/users/42`, `/users/anything`
- Route ordering becomes the only way to avoid conflicts
- No validation at the routing layer — handlers must validate themselves

**Found in**:

| Framework | Syntax | Notes |
|-----------|--------|-------|
| Mojolicious | `[id => qr/\d+/]` or `/:id<num>` | Regex or named types |
| Router::Simple | `{id:\d+}` | Inline regex in braces |
| Dancer2 | `/:id[Int]` | Type::Tiny constraints |
| Path::Router | `validations => { id => qr/\d+/ }` | Hashref of regex |
| Express.js | `/:id(\\d+)` | Inline regex in parens |
| Fastify | `/:id(^\\d+)` | Inline regex in parens |
| Chi (Go) | `{id:^[0-9]+}` | Inline regex in braces |
| Gorilla/mux (Go) | `{id:[0-9]+}` | Inline regex in braces |
| Actix-web (Rust) | `{id:\\d+}` | Inline regex in braces |
| Rails | `constraints: { id: /\d+/ }` | Hashref, regex, or lambda |
| Starlette | `{id:int}` | Named converters (int, float, uuid, path) |
| Django | `<int:id>` | Named converters |
| Flask | `<int:id>` | Named converters |

**Proposed API**: Two complementary syntaxes.

**Syntax A — Inline regex in braces** (like Router::Simple, Gorilla, Actix):

```perl
$router->get('/users/{id:\d+}' => $handler);
$router->get('/posts/{slug:[a-z0-9-]+}' => $handler);
$router->get('/files/{path:.+}' => $handler);  # like wildcard but explicit

# With middleware
$router->get('/users/{id:\d+}' => [$auth] => $handler);

# In mounts and groups
$router->group('/users/{id:\d+}' => sub { ... });
$router->mount('/orgs/{org_id:[a-z]+}' => $org_app);
```

**Syntax B — Chained constraints method** (like Mojolicious, Rails):

```perl
$router->get('/users/:id' => $handler)->constraints(id => qr/\d+/);

# Multiple constraints
$router->get('/archive/:year/:month' => $handler)
    ->constraints(year => qr/\d{4}/, month => qr/\d{2}/);
```

**Both syntaxes should work**. Inline is more concise for simple cases; chained is
better when constraints are complex or when you want to keep the path readable.

**Implementation notes**:

- `_compile_path()` must be updated to parse `{name:regex}` syntax
- Constraints from `->constraints()` override the default `[^/]+` capture group
- `:name` without constraint continues to use `[^/]+` (backward compatible)
- `*name` without constraint continues to use `.+`
- Constraint regex should NOT include anchors (`^`, `$`) — the router adds those
- Invalid regex in constraints should `croak` at registration time

**Interaction with `uri_for()`**: Constraints are for matching only; `uri_for()` does
not validate generated URLs against constraints. This matches how Mojolicious and Rails
handle it.

**Future extension — coderef constraints**: See #9b "FUTURE DIRECTION — Coderef
constraints on `->constraints()`" for a planned extension that would allow
`->constraints(id => sub { ... })` with access to the request scope. This requires
#8 (pass/fall-through) to be implemented first for proper failure semantics.

---

### 3. `any()` Multi-Method Matcher

**Importance**: Critical

**Problem**: No way to register a single handler for multiple HTTP methods without
duplicating the registration. Common need for login pages (GET + POST), health checks
(all methods), CORS preflight patterns.

**Found in**:

| Framework | All Methods | Specific Methods |
|-----------|-------------|-----------------|
| Mojolicious | `$r->any('/path')` | `$r->any(['GET','POST'] => '/path')` |
| Dancer2 | `any '/path'` | `any ['get','post'] => '/path'` |
| Express.js | `app.all('/path')` | N/A (use `app.route().get().post()`) |
| Hono | `app.all('/path')` | `app.on(['GET','POST'], '/path')` |
| Gin (Go) | `router.Any('/path')` | N/A |
| Axum (Rust) | `any(handler)` | `on(MethodFilter, handler)` |
| Koa | `router.all('/path')` | N/A |

**Proposed API**:

```perl
# Match ALL HTTP methods
$router->any('/health' => $health_check);

# Match specific methods
$router->any(['GET', 'POST'], '/login' => $login_handler);

# With middleware
$router->any(['PUT', 'PATCH'], '/users/:id' => [$auth] => $update_handler);

# With constraints
$router->any('/items/{id:\d+}' => $handler);
```

**Implementation notes**:

- `any()` without a method list should register the route with a special marker
  (e.g., `method => '*'`) that matches any HTTP method
- `any(['GET', 'POST'])` should register a single route that matches either method
- For 405 handling: a route registered with `any('*')` means that path can never
  produce a 405 (all methods are allowed)
- `any()` routes participate in the `Allow` header for 405 responses (contribute
  all their methods)

---

### 4. Route Grouping with Path Params and Per-Group Middleware

**Importance**: Critical

**Problem**: Currently, organizing routes under a shared prefix with shared middleware
requires creating a sub-router and mounting it. This is verbose and creates a separate
dispatch context (separate 405 handling, separate route namespace). There is no way to
group routes while keeping them as part of the parent router's dispatch table.

More critically, this is THE key primitive for CatalystNextGeneration. Catalyst-style
chain links map directly to nested groups: each group provides a path segment, captures
parameters, and wraps downstream routes in middleware (the chain link's setup/teardown).

**Found in**:

| Framework | Syntax | Notes |
|-----------|--------|-------|
| Express.js | `express.Router()` + `app.use('/prefix', router)` | Separate router object |
| Dancer2 | `prefix '/api' => sub { ... }` | Block-scoped prefix |
| Chi (Go) | `r.Route('/api', func(r chi.Router) { ... })` | Inline sub-router |
| Gin (Go) | `r.Group('/api')` | Group with middleware |
| Fastify | `fastify.register(plugin, { prefix: '/api' })` | Plugin with prefix |
| Hono | `app.route('/api', subApp)` or `app.basePath('/api')` | Sub-app or base path |
| Rails | `namespace`, `scope`, nested `resources` | Multiple grouping mechanisms |
| Actix-web (Rust) | `web::scope('/api')` | Scoped group with middleware |
| Axum (Rust) | `Router::nest('/api', sub_router)` | Nested router |

**Proposed API**:

```perl
# Basic prefix grouping
$router->group('/api' => sub {
    my ($r) = @_;
    $r->get('/users' => $list_users);       # GET /api/users
    $r->post('/users' => $create_user);     # POST /api/users
    $r->get('/users/:id' => $get_user);     # GET /api/users/:id
});

# With per-group middleware (applied to ALL routes in the group)
$router->group('/admin' => [$auth_mw, $log_mw] => sub {
    my ($r) = @_;
    $r->get('/dashboard' => $dashboard);    # GET /admin/dashboard (with auth+log)
    $r->get('/settings' => $settings);      # GET /admin/settings (with auth+log)
});

# With path params (the Catalyst chaining use case)
$router->group('/users/{user_id:\d+}' => [$load_user] => sub {
    my ($r) = @_;
    $r->get('/profile' => $show_profile);   # GET /users/42/profile
    $r->get('/settings' => $user_settings); # GET /users/42/settings

    # Nested groups (deep chains)
    $r->group('/posts/{post_id:\d+}' => [$load_post] => sub {
        my ($r) = @_;
        $r->get('/edit' => $edit_post);     # GET /users/42/posts/7/edit
        $r->get('/comments' => $comments);  # GET /users/42/posts/7/comments
    });
});

# Named routes work naturally
$router->group('/api/v1' => sub {
    my ($r) = @_;
    $r->get('/users/:id' => $get_user)->name('api.users.get');
});
$router->uri_for('api.users.get', { id => 42 });  # => /api/v1/users/42

# WebSocket and SSE routes in groups
$router->group('/realtime' => [$auth_mw] => sub {
    my ($r) = @_;
    $r->websocket('/chat/:room' => $chat_handler);
    $r->sse('/events/:channel' => $events_handler);
});
```

**How this maps to Catalyst chaining**:

```perl
# Catalyst:
sub user_base : Chained('/') PathPart('users') CaptureArgs(1) {
    my ($self, $c, $user_id) = @_;
    $c->stash->{user} = load_user($user_id);
}
sub edit : Chained('user_base') PathPart('edit') Args(0) {
    my ($self, $c) = @_;
    # $c->stash->{user} is available
}

# CatalystNextGen compiles to:
$router->group('/users/:user_id' => [$load_user_mw] => sub {
    my ($r) = @_;
    $r->get('/edit' => $edit_handler);
});

# The middleware IS the chain link:
my $load_user_mw = async sub ($scope, $receive, $send, $next) {
    # BEFORE (chain link setup)
    my $user_id = $scope->{path_params}{user_id};
    $scope->{'pagi.stash'}{user} = await load_user($user_id);

    await $next->();  # This IS Catalyst's ->next()

    # AFTER (chain link teardown / post-processing)
    cleanup_if_needed();
};
```

**Key design decision — flattening**:

`group()` MUST flatten routes into the parent router, NOT create a hidden sub-router.
This means:

- Routes are registered on the parent with the full prefixed path
- Group middleware is prepended to each route's middleware chain
- 405 works correctly across ALL routes (grouped and ungrouped)
- Named routes are directly accessible from the parent
- Route introspection shows the complete flat route list with full paths
- No separate dispatch context — one unified route table

Internally, group is syntactic sugar that prepends the prefix to each route's path
and prepends the group middleware to each route's middleware array:

```perl
# What the user writes:
$router->group('/api' => [$auth] => sub {
    my ($r) = @_;
    $r->get('/users' => [$rate_limit] => $list_users);
});

# What the router stores (flattened):
# Route: GET /api/users => middleware: [$auth, $rate_limit] => $list_users
```

**Nested group path params accumulate**: When groups are nested, the path params
from outer groups are available to inner groups' middleware and routes:

```perl
$router->group('/orgs/:org_id' => [$load_org] => sub {
    my ($r) = @_;
    $r->group('/teams/:team_id' => [$load_team] => sub {
        my ($r) = @_;
        $r->get('/members' => $list_members);
        # Handler sees path_params: { org_id => 'acme', team_id => 'eng' }
        # Middleware chain: $load_org -> $load_team -> $list_members
    });
});
```

**Difference from `mount()`**:

| Aspect | `group()` | `mount()` |
|--------|-----------|-----------|
| Route storage | Flattened into parent | Separate app |
| 405 handling | Unified with parent | Independent per mount |
| Named routes | Directly on parent | Requires `as()` to import |
| Path stripping | No — full path preserved | Yes — prefix stripped |
| `root_path` | Not modified | Set to mount prefix |
| Route introspection | Visible in parent | Opaque (separate app) |
| Use case | Organizing routes within one app | Composing independent apps |

---

### 4b. `group()` Router-Object Overload (Include Pattern)

**Importance**: Critical (bundled with #4)

**Problem**: The callback form of `group()` requires routes to be defined inline or via
a `register($r)` function that receives the router. This works, but it means the route
module is passive — it waits to be called with an `$r`. An alternative pattern is for
route modules to create and own their OWN Router object, which the parent then pulls in.
This is the "include" pattern used by FastAPI, Django, and Path::Router.

**Found in**:

| Framework | Syntax | Notes |
|-----------|--------|-------|
| FastAPI | `app.include_router(router, prefix='/api')` | Distinct method |
| Django | `include('app.urls')` | Function in URL patterns |
| Path::Router | `$router->include_router($prefix, $other)` | Distinct method |

**Decision: Overload `group()` rather than adding `include()`.**

Rationale: Perl's tradition of polymorphic functions (DWIM based on argument type) makes
this natural for Perl developers. `group` already means "flatten routes into me with a
prefix" — whether the routes come from a callback or an existing Router object is an
implementation detail, not a conceptual distinction. Adding a separate `include` method
would be the Java instinct, not the Perl instinct.

**Proposed API**:

```perl
# Form 1: Callback (existing — define routes inline)
$router->group('/api' => [$auth] => sub {
    my ($r) = @_;
    $r->get('/users' => $handler);
});

# Form 2: Router object (new — pull in routes from elsewhere)
my $api_routes = TodoApp::Routes::API->router;
$router->group('/api' => [$auth] => $api_routes);

# The route module creates its own router:
package TodoApp::Routes::API;
sub router {
    my $r = PAGI::App::Router->new;
    $r->get('/users' => \&list_users)->name('users.list');
    $r->get('/users/{id:int}' => \&show_user)->name('users.show');
    return $r;
}

# Both forms can use all the same options:
$router->group('/api' => $api_routes);                      # no middleware
$router->group('/api' => [$auth] => $api_routes);           # with middleware
$router->group('/api' => $api_routes)->name('api.root');     # chaining works
```

**Advantages over `register($r)` pattern**:

- Route modules are self-contained — they create and own their own router
- Testable in isolation: `my $app = TodoApp::Routes::API->router->to_app;`
- Introspectable independently: `TodoApp::Routes::API->router->routes_info`
- No coupling to caller — module doesn't depend on being passed an `$r`
- Same router can be included multiple times with different prefixes (API versioning)

**OPEN CONCERNS — Must resolve during implementation**:

These concerns are flagged for careful consideration when implementing #4 and #4b
together. Do not punt on these — each needs an explicit design decision.

**Concern 1: Named route conflicts.**
When two included routers both define a route named `users.list`, what happens?

Options:
- (a) `croak` on conflict (strictest, safest)
- (b) Last included wins (Perlish, but silent data loss)
- (c) Require `as()` namespace when including (explicit but verbose)
- (d) Auto-namespace by prefix if no `as()` given

Recommendation: (a) croak on conflict. Explicit is better than silent. The developer
can resolve by using `as()` or renaming.

**Concern 2: Mutable router after include.**

```perl
my $users = TodoApp::Routes::Users->router;
$router->group('/api' => $users);
$users->get('/late-addition' => $handler);  # Shows up in $router??
```

The answer MUST be NO — `group()` copies routes at call time. The included router
is a snapshot, not a live reference. This differs from the callback form where routes
register immediately during callback execution. Document this clearly.

Implementation: `group()` with a Router object iterates the Router's internal route
arrays and copies each route into the parent (with prefix prepended and middleware
prepended), rather than holding a reference to the Router.

**Concern 3: Type inheritance.**

If the included router has `add_type(int => qr/\d+/)` and the parent doesn't,
what happens to routes using `{id:int}` in the included router?

Options:
- (a) Types are resolved at compile time on the included router — already baked
  into the regex by the time we include. This "just works" but means the parent
  can't override types.
- (b) Types must be defined on the parent — included router's types are ignored.
  Routes are recompiled with parent's types at include time.
- (c) Types are merged — included router's types are copied to parent if no conflict.

Recommendation: (a) — types resolve at the source router's compile time. The regex
is already built when `_compile_path()` runs during route registration on the included
router. By the time `group()` copies the routes, the regex is fixed. This is the
simplest approach and avoids type-merging complexity. Document that types should be
defined on the router where routes are registered.

**Concern 4: Argument type detection.**

The `group()` method must distinguish three final-argument types:
- `CODE` ref → callback form
- `PAGI::App::Router` instance → include form
- Anything else → `croak` with helpful error message

```perl
sub group {
    my ($self, $prefix, @rest) = @_;
    my ($middleware, $target) = $self->_parse_route_args(@rest);

    if (ref($target) eq 'CODE') {
        # Callback form: execute immediately
        ...
    }
    elsif (blessed($target) && $target->isa('PAGI::App::Router')) {
        # Include form: copy routes from target
        ...
    }
    else {
        croak "group() target must be a coderef or PAGI::App::Router object, "
            . "got " . (ref($target) || 'scalar');
    }
}
```

Edge case: a blessed coderef that also `isa('PAGI::App::Router')` — check `isa` first
since it's more specific. In practice this will never happen, but the precedence should
be documented in a code comment.

**Concern 5: `as()` behavior differs between forms.**

For the callback form, `as()` is less useful because routes are defined inline with
explicit names. For the Router-object form, `as()` is important for namespacing
imported named routes (same as it works on `mount()` today).

Both forms should support `as()` with the same behavior: prefix all named routes
from the group with the namespace. The callback form benefits from this too when
the callback registers many named routes that should share a namespace.

**Concern 6: The group `$r` proxy in callback form.**

In the callback form, the `$r` passed to the callback needs to be a proxy/wrapper
that prepends the group prefix to all registrations. This proxy should also expose
`group()` (for nesting), `name()`, `as()`, `uri_for()`, and `named_routes()`.

For the Router-object form, no proxy is needed — the routes are copied directly.

This means the callback form needs a `GroupBuilder` internal class (similar to how
`PAGI::Endpoint::Router` has `RouteBuilder`), while the Router-object form just
iterates and copies. These are different code paths under one method — make sure
both are thoroughly tested.

---

### 5. Path Parameters in Mount Prefixes

**Importance**: Critical

**Problem**: Mount prefixes currently do not support path parameters. The mount dispatch
code uses `\Q$prefix\E` (quotemeta), which treats `:user_id` as literal text:

```perl
# Current code (lib/PAGI/App/Router.pm lines 362-378):
if ($path eq $prefix || $path =~ m{^\Q$prefix\E(/.*)$}) {
```

This means you cannot mount an independent sub-application at a parameterized path:

```perl
# DOES NOT WORK TODAY:
$router->mount('/users/:user_id' => $user_app);
# The literal string ":user_id" would need to appear in the URL
```

**Found in**:

Most frameworks that have mount/nest support path params in the prefix:

| Framework | Syntax |
|-----------|--------|
| Chi (Go) | `r.Mount("/users/{userID}", handler)` |
| Axum (Rust) | `Router::nest("/users/:id", sub_router)` |
| Express.js | `app.use('/users/:id', router)` — params via `mergeParams` |
| Starlette | `Mount("/users/{user_id}", app=sub_app)` |

**Proposed API**:

```perl
# Mount with path params
$router->mount('/users/:user_id' => $user_app);

# With constraints
$router->mount('/orgs/{org_id:[a-z]+}' => $org_app);

# With middleware
$router->mount('/tenants/{tenant_id:\d+}' => [$load_tenant] => $tenant_app);

# The mounted app receives:
#   $scope->{path} = sub-path with prefix stripped (e.g., '/profile')
#   $scope->{root_path} = accumulated prefix (e.g., '/users/42')
#   $scope->{path_params} = { user_id => '42', ...any existing params }

# Nested mounts with params accumulate
my $post_app = ...;  # handles /edit, /comments, etc.
my $user_app = PAGI::App::Router->new;
$user_app->mount('/posts/{post_id:\d+}' => $post_app);

$router->mount('/users/{user_id:\d+}' => $user_app);
# GET /users/42/posts/7/edit
#   user_app sees: path=/posts/7/edit, path_params={user_id=>42}
#   post_app sees: path=/edit, path_params={user_id=>42, post_id=>7}
```

**Implementation notes**:

- The mount prefix must be compiled to a regex (reuse `_compile_path()`)
- When matching, captured params are merged into `$scope->{path_params}`
- Params from outer mounts MUST NOT be clobbered — merge, don't replace
- `root_path` should contain the resolved path (with actual values, not param names):
  `/users/42` not `/users/:user_id`
- Longest-prefix-first sorting still applies, but now based on compiled regex complexity
  or the static portion of the prefix

**Bundled with #4 (grouping)** because both require the same `_compile_path()` changes
to support params and constraints in prefixes, and they share the param accumulation logic.

---

### 6. Optional Path Segments

**Importance**: High

**Problem**: No way to make path segments optional. To handle both `/users` and
`/users/42`, you must register two separate routes:

```perl
# Current workaround — two routes, same handler
$router->get('/users' => $handler);
$router->get('/users/:id' => $handler);
```

**Found in**:

| Framework | Syntax | Notes |
|-----------|--------|-------|
| Rails | `/users(/:id)` | Parentheses for optional segments |
| Sinatra | `/:param?` | Trailing `?` |
| Mojolicious | Default stash values make params optional | Implicit via defaults |
| Hono | `/:type?` | Trailing `?` |
| Fastify | `/:param?` | Terminal param only |
| Path::Router | `?:param` | Leading `?` |
| Hanami | `(.:format)` | Parentheses |

**Proposed API**: Parentheses syntax (like Rails/Hanami — most explicit):

```perl
# Optional trailing segment
$router->get('/users(/:id)' => $handler);
# Matches: /users        => path_params = {}
# Matches: /users/42     => path_params = { id => '42' }

# Optional with constraints
$router->get('/archive(/{year:\d{4}}(/{month:\d{2}}))' => $handler);
# Matches: /archive           => {}
# Matches: /archive/2024      => { year => '2024' }
# Matches: /archive/2024/01   => { year => '2024', month => '01' }

# Multiple optional segments (nested parens)
$router->get('/docs(/:section(/:page))' => $handler);

# Optional format extension
$router->get('/data(.:format)' => $handler);
# Matches: /data         => {}
# Matches: /data.json    => { format => 'json' }
```

**Implementation notes**:

- Parenthesized segments compile to regex alternation:
  `/users(/:id)` → `^/users(?:/([^/]+))?$`
- Nested parens compile to nested optional groups:
  `/a(/:b(/:c))` → `^/a(?:/([^/]+)(?:/([^/]+))?)?$`
- Missing optional params are simply absent from `path_params` (not set to undef)
- `uri_for()` must handle optional params: omitted optional params produce the
  shorter URL form
- Constraints work inside optional segments:
  `(/{id:\d+})` → `(?:/(\d+))?`

---

### 7. Route Introspection

**Importance**: High

**Problem**: No way to list or inspect registered routes. Essential for debugging,
building CLI tools (like Mojolicious's `routes` command or Rails's `bin/rails routes`),
and for CatalystNextGen to introspect the compiled dispatch table.

**Found in**:

| Framework | Mechanism | Notes |
|-----------|-----------|-------|
| Mojolicious | `./myapp routes` CLI + `$r->find()`, `$r->lookup()` | Tree dump with flags |
| Rails | `bin/rails routes`, `routes --expanded`, `routes -g PATTERN` | Comprehensive CLI |
| Gin (Go) | `router.Routes()` returns `RoutesInfo` slice | Programmatic access |
| Chi (Go) | `r.Routes()` returns routing tree | Tree structure |
| Gorilla/mux | `r.Walk(callback)` | Walking with callback |
| Router::Simple | `$router->as_string()` | Formatted string dump |
| Hanami | `hanami routes` CLI | CLI tool |

**Proposed API**:

```perl
# Programmatic access — returns list of route info hashrefs
my @routes = $router->routes_info;
# Returns:
# (
#   {
#     method => 'GET',
#     path   => '/users/{id:\d+}',
#     name   => 'users.get',
#     type   => 'http',
#     middleware_count => 2,
#   },
#   {
#     method => 'POST',
#     path   => '/users',
#     name   => 'users.create',
#     type   => 'http',
#     middleware_count => 1,
#   },
#   {
#     method => '*',
#     path   => '/health',
#     name   => undef,
#     type   => 'http',
#     middleware_count => 0,
#   },
#   {
#     path   => '/ws/chat/:room',
#     name   => undef,
#     type   => 'websocket',
#     middleware_count => 0,
#   },
#   {
#     path   => '/events/:channel',
#     name   => undef,
#     type   => 'sse',
#     middleware_count => 0,
#   },
#   {
#     prefix => '/api',
#     type   => 'mount',
#     has_path_params => 1,
#     middleware_count => 1,
#   },
# )

# Formatted string dump (for CLI tools and debugging)
my $table = $router->routes_dump;
print $table;
# Output:
# METHOD  PATH                     NAME            TYPE
# GET     /users/{id:\d+}          users.get       http
# POST    /users                   users.create    http
# *       /health                  -               http
# WS      /ws/chat/:room           -               websocket
# SSE     /events/:channel         -               sse
# MOUNT   /api/*                   -               mount

# Walk routes with callback (like Gorilla/mux)
$router->walk(sub {
    my ($route_info) = @_;
    # ... process each route
});
```

**Implementation notes**:

- `routes_info()` returns shallow copies of route metadata (not internal refs)
- Groups are shown as their flattened routes (since groups flatten into parent)
- Mounts are shown as opaque entries (can't introspect into mounted apps)
- If a mounted app is a `PAGI::App::Router` instance (detected via `isa`), its
  routes could optionally be recursively included
- `routes_dump()` is a convenience wrapper that formats `routes_info()` as a table

---

### 7b. Per-Route Metadata (`->meta()`)

**Importance**: Medium

**Status**: NEEDS DESIGN DISCUSSION before implementation. The core question is whether
metadata belongs ON the router (built-in `->meta()` method) or as a decorator/wrapper
AROUND the router (better composability). Do not implement until this is resolved.

**Problem**: Routes carry no application-level metadata. Frameworks and tools (OpenAPI
generators, debug inspectors, permission systems) need to associate metadata with routes
but have no standard place to put it. Without router support, frameworks maintain a
fragile parallel data structure keyed by route name or path+method.

**Found in**:

| Framework | Mechanism | Notes |
|-----------|-----------|-------|
| FastAPI | Decorator params: `summary`, `tags`, `responses`, `deprecated`, etc. | Per-operation OpenAPI metadata |
| Fastify | `config` option per route | Arbitrary per-route config object |
| Actix-web | `.name()` + external resource mapping | Named resources with URL generation |
| Rails | Route constraints + annotations via comments | Less formal |

**Use cases**:

- **OpenAPI generation**: summary, description, tags, response schemas, parameter docs
- **Permission/auth declarations**: required roles, scopes
- **Deprecation flags**: mark routes as deprecated for tooling
- **Framework-specific config**: CatalystNextGen action attributes, feature flags

**The API if built into the router**:

```perl
$router->get('/users/{uid:int}' => $handler)
    ->name('users.show')
    ->meta(
        summary   => 'Get user by ID',
        tags      => ['users'],
        responses => {
            200 => { schema => 'UserResponse' },
            404 => { description => 'User not found' },
        },
    );

# Retrieve:
my $meta = $route_info->{meta};  # via routes_info()
```

**OPEN QUESTION: Built-in vs Decorator**

There are two fundamentally different approaches. This needs to be discussed and
decided before implementation.

**Approach A: Built into the router (`->meta()` method)**

```perl
# Meta is a first-class router feature
$router->get('/users/:id' => $handler)->meta(\%openapi_stuff);

# routes_info() includes meta
my @info = $router->routes_info;  # each has {meta => ...}
```

Pros:
- Simple, discoverable, one place to look
- Metadata travels with the route through group(), include, introspection
- No extra objects or wrappers

Cons:
- Puts framework-specific concerns (OpenAPI) in a routing primitive
- Router's responsibility expands beyond matching/dispatching
- Every framework invents its own metadata schema, no enforcement
- "Kitchen sink" risk — everything gets dumped into meta

**Approach B: Decorator/wrapper around the router**

```perl
# A MetaRouter wraps a plain Router, adding metadata tracking
use PAGI::App::Router::WithMeta;  # or PAGI::Router::Documented, etc.

my $router = PAGI::App::Router::WithMeta->new;

# Same routing API, but with ->meta() added by the decorator
$router->get('/users/:id' => $handler)->meta(\%openapi_stuff);

# The decorator tracks metadata separately
my @meta = $router->routes_with_meta;  # decorated introspection

# Plain Router doesn't know about meta at all
# Framework chooses to use the decorator or not
```

Pros:
- Router stays focused on matching/dispatching (single responsibility)
- Metadata is opt-in — use the decorator only if you need it
- Different decorators for different purposes (OpenAPI decorator, permissions
  decorator, debug decorator) — better composability
- CatalystNextGen ships its own decorator with its own metadata schema
- A plain PAGI::App::Router stays lightweight for simple use cases

Cons:
- More objects, more indirection
- The decorator must proxy ALL router methods (get, post, group, mount, name, etc.)
  to add metadata tracking — maintenance burden
- Group/include behavior must be replicated in the decorator
- Two layers of introspection: router's routes_info() + decorator's metadata

**Approach C: Hybrid — router stores opaque slot, framework interprets**

```perl
# Router has a minimal ->meta() that stores ONE hashref per route
# but makes zero assumptions about contents
$router->get('/users/:id' => $handler)->meta(\%anything);

# The router's ONLY contract:
# - meta() stores/returns a hashref
# - routes_info() includes it
# - group() copies it
# - That's it. No merging, no schema, no interpretation.

# Frameworks define their own conventions:
# CatalystNextGen: ->meta({ action_class => '...', chain => '...' })
# OpenAPI plugin:  ->meta({ openapi => { summary => '...' } })
# Auth framework:  ->meta({ requires_role => 'admin' })
```

Pros:
- Minimal router change (one hashref, one method)
- No opinion about what goes in meta — pure storage
- Frameworks compose by using different keys in the same hashref
- No decorator overhead

Cons:
- Key collision risk between frameworks (both want `meta->{tags}`)
- Still adds a non-routing concern to the router
- "Minimal" has a way of growing — next someone wants `merge_meta`, `inherit_meta`...

**Design concerns that apply regardless of approach**:

1. **Group metadata**: Should groups have metadata? If so, does it merge into child
   routes? Recommendation: NO merging at the router level. Each route owns its own
   metadata. Frameworks handle inheritance in their own layer.

2. **Mount metadata**: Mounted apps are opaque — metadata on a mount entry describes
   the mount point, not the mounted app's routes. Only meaningful for introspection
   of the parent router.

3. **Metadata copying in group() Router-object form (4b)**: When routes are copied
   from an included router, metadata is shallow-copied. Framework-specific objects
   in metadata should be safe to share (they're typically config, not mutable state).

4. **OpenAPI specifically**: Most of an OpenAPI spec can be inferred from what the
   router already knows — path pattern, method, param names, constraints. Metadata
   adds the human parts (summary, description, examples, response schemas). An OpenAPI
   generator should use BOTH router introspection AND metadata, not rely solely on
   either.

**Recommendation**: Discuss further. The decorator approach (B) has the best
composability story and keeps the router clean. The hybrid approach (C) is pragmatic
and low-cost. Approach A is fine for a simple codebase but may cause regret at scale.
Leaning toward C as the sweet spot, but this warrants a real discussion before committing.

---

### 8. `pass` / Fall-Through to Next Matching Route

**Importance**: High

**Problem**: Once a route matches, its handler runs unconditionally. There is no way
for a handler to "decline" the route and let the router try the next matching route.
This is useful for conditional routing logic where the decision depends on runtime
state, not just the URL pattern.

**Found in**:

| Framework | Mechanism | Notes |
|-----------|-----------|-------|
| Dancer2 | `pass` keyword | Skip to next matching route |
| Sinatra | `pass` keyword | Delegate to next matching route |
| Express.js | `next('route')` | Skip remaining middleware, try next route |
| Mojolicious | `$c->continue` + conditions | Conditions can reject matches |

**Proposed API**:

```perl
use PAGI::App::Router qw(PASS);

# Handler returns PASS sentinel to decline the route
my $numeric_handler = async sub ($scope, $receive, $send) {
    my $id = $scope->{path_params}{id};
    return PASS unless $id =~ /^\d+$/;
    # ... handle numeric ID
};

my $slug_handler = async sub ($scope, $receive, $send) {
    my $id = $scope->{path_params}{id};
    # This runs if numeric_handler passed
    # ... handle slug
};

$router->get('/items/:id' => $numeric_handler);
$router->get('/items/:id' => $slug_handler);

# Also works with middleware — middleware can PASS too
my $conditional_mw = async sub ($scope, $receive, $send, $next) {
    return PASS unless $scope->{headers}{'x-api-key'};
    await $next->();
};

$router->get('/data' => [$conditional_mw] => $api_handler);
$router->get('/data' => $public_handler);  # fallback if no API key
```

**Implementation notes**:

- `PASS` is an exported constant (blessed ref or specific string) that handlers return
- In `to_app()` dispatch, after a handler returns, check if return value is `PASS`
- If `PASS`, continue the route matching loop instead of returning
- The `PASS` check applies to all route types (HTTP, WebSocket, SSE)
- If ALL matching routes pass, fall through to mounts, then 404
- `PASS` from middleware short-circuits the middleware chain for that route and
  falls through to the next matching route

**Consideration**: This requires the dispatch loop to `await` the handler and check
its return value, which means the handler's return value becomes semantically meaningful.
Currently handlers return nothing meaningful. This is a protocol-level decision worth
careful thought.

**Alternative approach**: Instead of a return value, use an exception/die:

```perl
use PAGI::App::Router qw(pass);

my $handler = async sub ($scope, $receive, $send) {
    pass() unless $scope->{path_params}{id} =~ /^\d+$/;
    # ... handle
};

# pass() throws a specific exception type caught by the dispatch loop
```

This avoids making return values meaningful but uses exceptions for flow control,
which has its own tradeoffs.

---

### 9. Custom Path Types / Converters

**Importance**: Medium

**Problem**: Regex constraints (feature #2) are powerful but verbose and not reusable.
You end up repeating the same regex across many routes. Named types provide reusable,
self-documenting constraints.

**Found in**:

| Framework | Syntax | Notes |
|-----------|--------|-------|
| Mojolicious | `$r->add_type(name => qr/.../)` then `/:param<name>` | Named types |
| Mojolicious | `$r->add_type(name => ['a','b'])` | Value-list types |
| Starlette | `register_url_convertor(key, cls)` | Class with regex + convert |
| Django | `register_converter(cls, name)` | Class with regex + to_python + to_url |
| Flask | `app.url_map.converters['name'] = cls` | Werkzeug converter class |
| Dancer2 | `type_library: MyApp::Types` | Type::Tiny integration |
| Path::Router | `validations => { id => 'PositiveInt' }` | Moose type names |

**Proposed API**:

```perl
# Register reusable named types (Mojo-inspired)
$router->add_type(int  => qr/\d+/);
$router->add_type(uuid => qr/[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}/i);
$router->add_type(slug => qr/[a-z0-9]+(?:-[a-z0-9]+)*/);

# Value-list types (enum-like)
$router->add_type(format => ['json', 'xml', 'html', 'csv']);
$router->add_type(status => ['active', 'inactive', 'pending']);

# Use in routes with angle-bracket syntax (Mojo-style)
$router->get('/users/:id<int>' => $handler);
$router->get('/posts/:slug<slug>' => $handler);
$router->get('/items/:uuid<uuid>' => $handler);
$router->get('/data.:format<format>' => $handler);

# Use in groups/mounts
$router->group('/users/:user_id<int>' => sub { ... });

# Built-in types (registered by default)
# int   => qr/\d+/
# uuid  => qr/[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}/i
# slug  => qr/[a-z0-9]+(?:-[a-z0-9]+)*/
# path  => qr/.+/    (like wildcard, matches across /)
```

**Implementation notes**:

- Types are stored on the router instance in a `_types` hashref
- `_compile_path()` resolves type names to regex at compile time
- Types are inherited by groups (the group's `$r` parameter shares the parent's types)
- Unknown type names `croak` at registration time
- Value-list types compile to alternation: `['json','xml']` → `(?:json|xml)`

#### 9b. `find_type_via()` — External Type Registry Hook

**Problem**: `add_type()` is local to a router instance. In a larger application
(especially CatalystNextGen), types should be defined once in a central registry
and available to all routers. Repeating `add_type(int => qr/\d+/)` on every router
is tedious and error-prone.

**Proposed API**:

```perl
# Hook into an external type registry
$router->find_type_via(sub ($type_name) {
    # Called when a type isn't found in local add_type registry
    # Return: qr/.../ (regex), ['val1','val2'] (value list), or undef (unknown)
    my $type = MyApp::Types->lookup($type_name);
    return $type ? $type->{regex} : undef;
});

# Resolution order:
# 1. Local add_type registry (per-router) → wins if found
# 2. find_type_via callback → called if not found locally
# 3. croak "Unknown type" → if both return nothing

# Type::Tiny integration example:
use Type::Registry;
my $reg = Type::Registry->for_class('MyApp');
$reg->add_types('Types::Standard');

$router->find_type_via(sub ($type_name) {
    my $type = eval { $reg->lookup($type_name) };
    return undef unless $type;
    return $type->_regexp if $type->can('_regexp');
    return undef;  # type exists but can't extract regex — fall through to croak
});

# Now use Type::Tiny names directly in routes:
$router->get('/users/:id<PositiveInt>' => $handler);
$router->get('/posts/:date<DateStr>' => $handler);

# CatalystNextGen provides its own registry:
$router->find_type_via(\&CatalystNG::Types::resolve);

# A simple shared registry across routers:
my %global_types = (
    int  => qr/\d+/,
    uuid => qr/[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}/i,
    slug => qr/[a-z0-9]+(?:-[a-z0-9]+)*/,
);
$router->find_type_via(sub ($name) { $global_types{$name} });
```

**Design decisions**:

- **One callback per router** (last `find_type_via()` call wins). If you need to
  check multiple registries, compose them in your callback. Keeps the router simple.
- **Groups inherit parent's `find_type_via`**. Types are typically app-wide, not
  per-group. The group's `$r` proxy shares the parent's callback.
- **Return type**: Consistent with `add_type` — a regex (`qr/.../`) or a value list
  (`['a','b']`). No new return types.
- **Called at route registration time** (during `_compile_path`), not at dispatch time.
  The callback's result is baked into the compiled regex. This means the callback must
  be set BEFORE registering routes that use external types.

**Interaction with #4b (Router-object include)**:

When a Router object is built independently and then included via `group()`, its routes
were compiled against ITS `find_type_via` callback (or lack thereof). The parent's
`find_type_via` does NOT retroactively recompile included routes. Types resolve at the
source router's compile time (consistent with Concern 3 from #4b).

This means: if you want included routers to use a shared type registry, set
`find_type_via` on the included router BEFORE registering its routes:

```perl
# In the route module:
sub router {
    my $r = PAGI::App::Router->new;
    $r->find_type_via(\&MyApp::Types::resolve);  # BEFORE routes
    $r->get('/users/:id<int>' => \&show_user);
    return $r;
}
```

Or better — provide a factory/base class that pre-configures new routers:

```perl
# MyApp::Router — pre-configured router factory
sub new_router {
    my $r = PAGI::App::Router->new;
    $r->find_type_via(\&MyApp::Types::resolve);
    return $r;
}
```

**FUTURE DIRECTION — Coderef validators (not for now)**:

Currently types are regex-only (for route matching). A future extension could allow
types to provide both a regex (for matching) AND a coderef (for post-match validation):

```perl
# FUTURE — not part of current design:
$router->add_type(user_id => {
    regex => qr/\d+/,                      # route matching (path candidate?)
    check => sub ($val) { $val <= 99999 },  # post-match validation
});
```

The distinction matters: regex determines whether a route is a *candidate* (failed regex
→ try next route). A coderef validator runs AFTER the route matches — rejection at that
point is semantically different (closer to `pass`/fall-through from #8, or a 400 Bad
Request). The "what happens on coderef rejection?" question needs careful design:

- Treat as non-match and fall through to next route? (like `pass`)
- Return 400 Bad Request? (validation error, not routing error)
- Let the handler decide? (just set a flag in scope)

This interacts with #8 (pass/fall-through) and should be designed alongside it.
For now, types are regex-only. Flag this for Phase 3+ consideration.

**FUTURE DIRECTION — Coderef constraints on `->constraints()` (not for now)**:

The same coderef validation concept applies to `->constraints()` (feature #2), not just
named types. A coderef constraint would receive the captured param value AND the request
context, enabling rich validation that goes beyond regex pattern matching:

```perl
# FUTURE — not part of current design:
$router->get('/users/:id' => $handler)->constraints(
    id => sub ($value, $scope) {
        # $value is the captured param string
        # $scope is the raw PAGI scope hash
        # Could construct PAGI::Request, PAGI::WebSocket, etc. from $scope
        return $value =~ /^\d+$/ && $value > 0 && $value < 100000;
    },
);

# Or with request object construction (handler could be a helper):
$router->get('/orders/:id' => $handler)->constraints(
    id => sub ($value, $scope) {
        my $req = PAGI::Request->new($scope);
        # Access headers, query params, auth info for constraint logic
        return $value =~ /^\d+$/ && $req->header('x-api-version') ge '2.0';
    },
);
```

Key design considerations for when this is implemented:

- **Must be designed alongside #8 (pass/fall-through).** Without fall-through, a failed
  coderef constraint has no good failure semantic — the path matched but the constraint
  didn't, and there's nowhere to "try next." With fall-through, the dispatch loop can
  naturally move to the next candidate route.
- **`$scope` not request objects.** The router should pass raw `$scope`, not protocol-
  specific objects like `PAGI::Request`. This keeps the router decoupled from the request
  layer. Users who want a Request object can construct one in their coderef.
- **Performance.** Coderef constraints run at dispatch time on every request that matches
  the path regex. They should be lightweight. Heavy validation belongs in middleware or
  handlers, not constraints.
- **Regex constraints remain the fast path.** Inline `{id:\d+}` and regex `->constraints()`
  compile into the path regex and reject non-candidates before dispatch. Coderef constraints
  are a post-match filter — a different stage in the pipeline.

---

### 10. Trailing Slash Policy

**Importance**: Medium

**Problem**: Currently `/users` and `/users/` are treated as completely different paths.
No normalization or redirect behavior. This is a common source of user confusion and
can cause "route not found" errors that are hard to debug.

**Found in**:

| Framework | Mechanism | Default |
|-----------|-----------|---------|
| Starlette | `redirect_slashes=True` on Router | Redirect to slashed version |
| Flask | Rules ending with `/` auto-redirect | `/foo` → 301 → `/foo/` |
| Django | `APPEND_SLASH` setting | Redirect if no match without slash |
| Gin (Go) | `RedirectTrailingSlash` option | Auto-redirect |
| Gorilla/mux | `StrictSlash(true)` | Redirect between forms |
| Fastify | `prefixTrailingSlash` option | Configurable per-route |
| Actix-web | `NormalizePath` middleware | Trim, Append, or MergeOnly |

**Proposed API**:

```perl
my $router = PAGI::App::Router->new(
    trailing_slash => 'strip',     # /foo/ matches as /foo (normalize input)
    # trailing_slash => 'add',     # /foo matches as /foo/ (normalize input)
    # trailing_slash => 'redirect', # 301 redirect /foo/ → /foo
    # trailing_slash => undef,     # (default) treat as distinct paths
);
```

**Implementation notes**:

- `strip` and `add` normalize the path before matching (no redirect, transparent)
- `redirect` sends a 301 response to the normalized form
- The root path `/` is never modified
- This applies before route matching in `to_app()`
- Mount prefix matching should also respect this policy

---

### 11. Redirect Routes

**Importance**: Medium

**Problem**: Defining a redirect currently requires a full handler:

```perl
$router->get('/old-page' => async sub ($scope, $receive, $send) {
    await $send->({
        type => 'http.response.start',
        status => 301,
        headers => [['location', '/new-page']],
    });
    await $send->({ type => 'http.response.body', body => '', more => 0 });
});
```

**Found in**:

| Framework | Syntax |
|-----------|--------|
| Rails | `get '/old', to: redirect('/new')` with optional status |
| Rails | `redirect { \|params\| "/articles/#{params[:name]}" }` (dynamic) |
| Hanami | `redirect '/old', to: '/new'` |
| Sinatra | `redirect to('/new')` (in handler, not route-level) |

**Proposed API**:

```perl
# Simple redirect (301 by default)
$router->redirect('/old-path' => '/new-path');

# With explicit status code
$router->redirect('/moved' => '/new-location', 302);

# Dynamic redirect preserving path params
$router->redirect('/users/:id/profile' => '/profiles/:id');

# Redirect with wildcard
$router->redirect('/blog/*path' => '/articles/*path');
```

**Implementation notes**:

- `redirect()` is syntactic sugar that creates a handler internally
- Path param substitution happens at request time using captured values
- Default status is 301 (Moved Permanently)
- Creates a `GET` + `HEAD` route (redirects shouldn't be for POST/PUT/etc. by default)
- The generated handler sends the PAGI response protocol events directly

---

### 12. Host-Based Routing

**Importance**: Medium-Low

**Problem**: No way to route based on the `Host` header. Useful for multi-tenant
applications, subdomain-based routing, and virtual hosting.

**Found in**:

| Framework | Syntax | Notes |
|-----------|--------|-------|
| Gorilla/mux | `r.Host("{sub}.example.com")` | With variables |
| Starlette | `Host("{subdomain}.example.org", app=router)` | Host class |
| Plack::App::URLMap | `mount 'http://api.example.com/' => $app` | In URL |
| Koa | `new Router({ host: /pattern/ })` | On router constructor |
| Rails | `constraints(subdomain: 'admin')` | Constraint block |
| Sinatra | `get '/', host_name: /^admin\./` | Condition |
| Mojolicious | `->requires(host => 'docs.example.com')` | Route condition |

**Proposed API**:

```perl
# String match on individual routes
$router->get('/dashboard' => $handler)->host('admin.example.com');

# Regex match
$router->get('/api/v1/*path' => $handler)->host(qr/^api\./);

# Dynamic host params (like Gorilla/mux, Starlette)
$router->get('/' => $handler)->host(':tenant.example.com');
# $scope->{host_params}{tenant} = 'acme'

# On groups
$router->group('/admin' => sub { ... })->host('admin.example.com');

# On mounts
$router->mount('/api' => $api_app)->host(qr/^api\./);
```

**Implementation notes**:

- Host matching happens before path matching
- Host is extracted from `$scope->{headers}` (the Host header)
- Dynamic host params stored in `$scope->{host_params}` (separate from `path_params`)
- If no host constraint is set, the route matches any host (backward compatible)
- Host matching should be case-insensitive per HTTP spec

---

### 13. Param Middleware

**Importance**: Medium-Low

**Problem**: When multiple routes share the same path parameter (e.g., `:user_id`),
the resource-loading logic must be duplicated in each handler or extracted into a
middleware that's manually applied to each route.

**Found in**:

| Framework | Syntax | Notes |
|-----------|--------|-------|
| Express.js | `router.param('user_id', callback)` | Pre-handler per param |
| Koa | `router.param('user_id', middleware)` | Same pattern |

**Proposed API**:

```perl
# Register middleware triggered by param name
$router->param('user_id' => async sub ($scope, $receive, $send, $next) {
    my $id = $scope->{path_params}{user_id};
    $scope->{'pagi.stash'}{user} = await load_user($id);
    await $next->();
});

# Now ANY route with :user_id automatically gets user loading
$router->get('/users/:user_id' => $show_user);         # user loaded
$router->put('/users/:user_id' => $update_user);        # user loaded
$router->get('/users/:user_id/posts' => $user_posts);   # user loaded
$router->get('/items/:item_id' => $show_item);           # NOT triggered (different param)
```

**Implementation notes**:

- Param middleware is stored in a `_param_middleware` hashref keyed by param name
- At `to_app()` time (or at route registration time), param middleware is prepended
  to the route's middleware chain if the route's path contains that param name
- Multiple param middlewares can be registered for different params; all matching
  ones are applied
- Execution order: param middleware runs before per-route middleware
- Param middleware registered after a route definition should still apply (resolved
  at `to_app()` time, not at registration time)

**Note**: This feature overlaps significantly with group middleware. If you use
`group('/users/:user_id' => [$load_user] => sub { ... })`, you get the same effect
for routes within that group. Param middleware is more useful for "loose" routes
that aren't grouped but share a param name.

---

### 14. Content Negotiation / Format Detection

**Importance**: Low

**Problem**: No built-in support for routing based on response format (`.json`, `.html`
extensions) or `Accept` header content negotiation.

**Found in**:

| Framework | Mechanism |
|-----------|-----------|
| Mojolicious | Format detection from extension, `_format` param, Accept header |
| Sinatra | `provides: 'html'` condition |
| Rails | Format constraints, `respond_to` block |

**Proposed API** (if implemented):

```perl
# Format extension detection
$router->get('/data(.:format)' => $handler);
# /data.json  => path_params = { format => 'json' }
# /data.xml   => path_params = { format => 'xml' }
# /data       => path_params = {}

# With format constraint
$router->get('/data(.:format<format>)' => $handler);
# Only matches registered format types
```

**Note**: This is mostly handled by optional segments (#6) + types (#9). A dedicated
content negotiation system based on `Accept` headers would be better as middleware
than a router feature.

---

### 15. Custom Conditions / Guards

**Importance**: Low

**Problem**: No way to add arbitrary matching conditions beyond path and HTTP method.
For example, matching based on headers, query parameters, or custom request predicates.

**Found in**:

| Framework | Mechanism |
|-----------|-----------|
| Mojolicious | `$r->requires(headers => {...})`, custom conditions |
| Actix-web | Guard trait with AND/OR/NOT composition |
| Gorilla/mux | `.Headers()`, `.Queries()`, `.Schemes()`, `.MatcherFunc()` |
| Sinatra | Custom conditions via `set(:name) { \|val\| condition { ... } }` |

**Proposed API** (if implemented):

```perl
# Condition as coderef
$router->get('/api/data' => $handler)
    ->when(sub ($scope) {
        return exists $scope->{headers}{'x-api-key'};
    });

# Built-in condition helpers
$router->get('/secure' => $handler)->when_header('X-Custom', qr/^valid/);
$router->get('/admin' => $handler)->when_scheme('https');
```

**Note**: Most of these conditions are better handled by middleware. The guard pattern
adds complexity to route matching. Only worth adding if there's strong user demand.

---

### 16. RESTful Resource Generation

**Importance**: Low

**Problem**: No shorthand for generating standard CRUD routes. Currently requires
manual registration of 4-7 routes per resource.

**Found in**:

| Framework | Syntax |
|-----------|--------|
| Rails | `resources :users` generates 7 routes |
| Hanami | `resources :books` (since 2.3) |
| Mojolicious | Custom via `add_shortcut()` |

**Proposed API** (if implemented):

```perl
# Generate standard REST routes
$router->resources('/users' => {
    index   => $list_users,    # GET    /users
    create  => $create_user,   # POST   /users
    show    => $show_user,     # GET    /users/:id
    update  => $update_user,   # PUT    /users/:id
    patch   => $patch_user,    # PATCH  /users/:id
    destroy => $delete_user,   # DELETE /users/:id
});

# Partial resource (only some actions)
$router->resources('/posts' => {
    index => $list_posts,
    show  => $show_post,
});
```

**Note**: This is very opinionated and may belong in a higher-level framework
(like CatalystNextGen) rather than in the base router. The router should provide
the primitives (group, constraints, any) that make building resource generators easy.

---

### 17. Route Caching

**Importance**: Low

**Problem**: Route matching is a linear scan through the route list. For applications
with many routes and high request rates, this could become a bottleneck.

**Found in**:

| Framework | Mechanism |
|-----------|-----------|
| Mojolicious | `Mojo::Cache` for recurring requests |
| HTTP::Router | `freeze()` for inline matcher |

**Note**: Linear scan is fine for typical route counts (< 100 routes). If performance
becomes an issue, consider switching to a radix tree (like Chi, Gin, Fastify's
find-my-way). This is a significant internal refactor and should only be done if
profiling shows route matching is actually a bottleneck.

---

### 18. Versioned Routing

**Importance**: Low

**Problem**: No built-in support for API versioning via headers.

**Found in**: Fastify only (via `Accept-Version` header with semver matching).

**Note**: API versioning is typically handled via URL prefix (`/api/v1/`, `/api/v2/`)
which already works with groups and mounts, or via middleware that inspects headers.
A dedicated router feature for this is overkill.

---

### 19. `on_event()` — Custom Scope Type Routing

**Importance**: For Consideration (not yet committed to any phase)

**Status**: NEEDS FURTHER DISCUSSION. This feature is architecturally interesting but
has significant open questions about matching semantics, naming, and whether it belongs
in the core router. Documented here to capture the analysis; do not implement without
a clear use case driving it.

**Problem**: The router hardcodes three scope types (`http`, `websocket`, `sse`) plus
`lifespan` (silently ignored). The PAGI spec itself treats scope types as extensible —
they are NOT a closed set. But the router treats them as one. Any request with an
unrecognized `$scope->{type}` falls through to 404.

The dispatch logic in `to_app()` has three near-identical code blocks:

```perl
if ($type eq 'websocket') {
    for my $route (@websocket_routes) { ... }  # path-only matching
}
if ($type eq 'sse') {
    for my $route (@sse_routes) { ... }        # path-only matching (identical)
}
# HTTP: method+path matching
for my $route (@routes) { ... }
```

WebSocket and SSE dispatch are copy-paste identical except for which array they check.
This is both a missed abstraction and a barrier to extensibility.

**Potential use cases for custom scope types**:

- `graphql` — GraphQL subscription connections
- `grpc` — gRPC streaming RPCs (if someone builds a gRPC PAGI server)
- `mqtt` — MQTT-style pub/sub topics
- `job` / `queue` — Background job dispatch
- `cron` — Scheduled task routing
- Custom application-level protocols
- CatalystNextGen internal dispatch types (action chains, private actions)

**Proposed API**:

```perl
# Generic scope-type routing
$router->on_event('graphql', '/subscriptions/:channel' => $handler);
$router->on_event('grpc', '/myapp.UserService/GetUser' => $handler);
$router->on_event('mqtt', '/sensors/:device_id/temperature' => $handler);

# With middleware
$router->on_event('graphql', '/subs/:ch' => [$auth] => $handler);

# Existing methods become sugar over the generic form:
# $router->websocket($path, @rest) === $router->on_event('websocket', $path, @rest)
# $router->sse($path, @rest)       === $router->on_event('sse', $path, @rest)

# In groups
$router->group('/realtime' => [$auth] => sub {
    my ($r) = @_;
    $r->on_event('graphql', '/subs/:channel' => $gql_handler);
    $r->websocket('/ws' => $ws_handler);  # sugar still works
});

# Custom types get path-only matching (same as websocket/sse)
# HTTP remains special with method+path matching
```

**Internal simplification**: Replace three separate arrays with one hashref keyed by
scope type. Two dispatch codepaths instead of three:

```perl
# Internal route storage:
{
    _type_routes => {
        http      => [@http_routes],       # special: method+path matching
        websocket => [@ws_routes],         # path-only matching
        sse       => [@sse_routes],        # path-only matching
        graphql   => [@graphql_routes],    # path-only matching (user-registered)
    },
}

# Dispatch in to_app():
if ($type eq 'http' || !defined $type) {
    # HTTP dispatch: method+path matching, 405 handling
    ...
} else {
    # Generic dispatch: path-only matching for ALL other types
    my $type_routes = $type_routes{$type} // [];
    for my $route (@$type_routes) { ... }
    # Fall through to mounts, then not_found
}
```

**FINDINGS — What's Good About This**:

1. **True to PAGI's identity.** PAGI is an async gateway interface, not just a web
   framework. The spec supports arbitrary scope types. The router should too.

2. **Simplifies router internals.** Eliminates the copy-paste duplication between
   websocket and sse dispatch. One generic path-only dispatcher handles all non-HTTP
   types.

3. **Future-proofing.** If PAGI adds WebTransport, HTTP/3 server push, or other
   protocols, the router doesn't need code changes — just register routes for the
   new scope type.

4. **CatalystNextGen extensibility.** A framework could define internal scope types
   for dispatch chain control without hacking the router.

5. **Low implementation cost.** The refactor from three arrays to one hashref is
   straightforward. The public API adds one method.

**FINDINGS — What's Bad About This**:

1. **API surface growth.** Users now have `get`, `post`, `put`, `patch`, `delete`,
   `head`, `options`, `any`, `websocket`, `sse`, AND `on_event`. That's 11 methods
   for registering routes. Though `websocket` and `sse` could become sugar over
   `on_event`, keeping the convenience methods means more methods, not fewer.

2. **Custom types get one-size-fits-all matching.** All non-HTTP types get path-only
   matching (regex against `$scope->{path}`). This is correct for protocols that map
   to URL-like paths (GraphQL subscriptions, gRPC). It's wrong for protocols with
   fundamentally different addressing (MQTT topic wildcards `+` and `#`, message
   queue routing keys with `*` and `#`). If your protocol doesn't use URL paths,
   `on_event` doesn't help — you'd still need to `mount()` a custom dispatcher.

3. **405 is HTTP-only.** The 405 Method Not Allowed response with `Allow` header is
   HTTP-specific. Custom types don't have an HTTP method concept. The dispatch logic
   must cleanly separate "HTTP-like with method matching" from "everything else with
   path-only matching." This is already handled by the proposed two-codepath design,
   but it's a semantic distinction that must be documented.

4. **Not all scope types have paths.** The proposed design assumes `$scope->{path}`
   exists and is meaningful for all types. HTTP, WebSocket, and SSE all have paths.
   But a hypothetical `cron` or `queue` scope type might not have a meaningful path —
   it might have a `queue_name` or `schedule` instead. `on_event` wouldn't help for
   those unless the server puts the relevant identifier in `$scope->{path}`.

5. **Testing burden.** Every feature in the router (groups, mounts, middleware,
   constraints, named routes, introspection, pass/fall-through) needs to work with
   custom types. That's a combinatorial testing explosion. Currently these features
   are tested against 3 known types; with open-ended types, coverage gaps are likely.

**FINDINGS — What's Ugly About This**:

1. **Naming: `on_event` has event-listener connotations.** In most async frameworks,
   `.on('event', handler)` means "subscribe to events" (fire-and-forget, many times).
   In PAGI's router, it means "match this scope type and dispatch" (request-response,
   once). The semantics are close but not identical.

   Alternative names considered:
   - `on()` — shortest, but strongest event-listener connotation
   - `on_event()` — slightly more descriptive, still event-like
   - `scope_type()` — clear but verbose
   - `for_type()` — clear, concise
   - `handle()` — generic, could conflict with other meanings
   - `dispatch()` — accurate but sounds internal

   No clear winner. `on_event` is the current working name.

2. **Custom types with method-like sub-matching.** gRPC has service/method pairs.
   If someone wants `on_event('grpc', '/UserService/GetUser')`, that works fine as
   a path. But if they want method-based dispatch WITHIN a gRPC type (like HTTP's
   GET/POST), the path-only matching isn't enough. Do we allow custom types to opt
   into method+path matching? That starts to look like a pluggable dispatch strategy,
   which is significant complexity.

   Recommendation: don't go there. If a custom type needs method-like sub-matching,
   the handler does it internally, or the protocol maps it into the path.

3. **Interaction with `not_found`.** The current `not_found` handler fires for ALL
   unmatched types. If a request comes in with `type => 'graphql'` and no graphql
   routes are registered, it falls through to `not_found`. Is that correct? Or should
   unrecognized types be silently ignored (like `lifespan`)? Or should there be a
   per-type fallback?

   This needs a clear policy. Options:
   - (a) All unmatched types go to `not_found` (current behavior, consistent)
   - (b) Only known types (http, websocket, sse, + any type with registered routes)
     go to `not_found`; unknown types are silently ignored
   - (c) Per-type `not_found` handlers

   Recommendation: (a) for simplicity. The `not_found` handler can inspect
   `$scope->{type}` and decide how to respond.

4. **The "do we even need this?" question.** The honest answer is: probably not yet.
   The current hardcoded types cover 99%+ of PAGI usage. Custom scope types are a
   PAGI spec feature that almost nobody uses today. Adding router support for them
   is forward-looking but risks over-engineering.

   The counterargument: the refactor from three arrays to one hashref SIMPLIFIES the
   code even if no one uses custom types. It's a code quality win independent of the
   feature.

**ADDITIONAL CONSIDERATION: Intra-Connection Event Dispatch**

There is a related but distinct concept that expands the scope of `on_event` beyond
scope-type routing: **dispatching on event types WITHIN a connection**. Today, every
WebSocket or SSE handler contains a manual while-loop dispatcher:

```perl
async sub ws_handler ($scope, $receive, $send) {
    await $send->({ type => 'websocket.accept' });

    while (1) {
        my $event = await $receive->();
        last if ($event->{type} // '') eq 'websocket.disconnect';

        if ($event->{type} eq 'websocket.receive') {
            my $msg = decode_json($event->{text});

            # Manual event dispatch — this is routing!
            if ($msg->{action} eq 'chat.message') { ... }
            elsif ($msg->{action} eq 'presence.join') { ... }
            elsif ($msg->{action} eq 'presence.leave') { ... }
            else { ... }  # unknown action
        }
    }
}
```

This is effectively a mini-router inside every handler. The `if/elsif` chain IS
dispatch — matching an event type string to a handler. As the number of event types
grows, this becomes the same maintenance burden that URL routing solves for HTTP.

**Three placement options for event dispatch**:

1. **In the Router itself** (`on_event` as sub-route matching):

   ```perl
   $router->websocket('/ws/chat/:room' => sub {
       my ($events) = @_;
       $events->on('chat.message'  => \&handle_chat_msg);
       $events->on('presence.join' => \&handle_join);
       $events->on('presence.leave' => \&handle_leave);
   });
   ```

   Pro: Unified dispatch model, visible in route introspection.
   Con: Mixes connection-level concerns (accept, disconnect) with app-level concerns.

2. **In PAGI::WebSocket / PAGI::SSE** (protocol-layer feature):

   ```perl
   # A PAGI::WebSocket helper that does the event loop for you
   use PAGI::WebSocket::EventRouter;
   my $er = PAGI::WebSocket::EventRouter->new;
   $er->on('chat.message'  => \&handle_chat_msg);
   $er->on('presence.join' => \&handle_join);

   $router->websocket('/ws/chat/:room' => $er->to_handler);
   ```

   Pro: Separation of concerns — router routes connections, EventRouter routes events.
   Con: Two routing concepts to learn.

3. **Separate EventRouter utility** (completely independent):

   ```perl
   use PAGI::EventRouter;
   my $event_router = PAGI::EventRouter->new;
   $event_router->on('chat.message'  => \&handle_msg);
   $event_router->on('order.*'       => \&handle_order_event);  # wildcard
   $event_router->on('*'             => \&catch_all);

   # Used inside any handler — HTTP, WS, SSE, anything
   async sub handler ($scope, $receive, $send) {
       ...
       $event_router->dispatch($event);
       ...
   }
   ```

   Pro: Maximum composability — use it anywhere, with any protocol.
   Con: No integration with router introspection.

**BROADLY USEFUL BEYOND SSE/WEBSOCKET**

This is not just a WebSocket concern. Event dispatch patterns appear in ANY protocol
where a single connection or endpoint handles multiple logical operations:

- **Complex HTTP workflows**: An ordering system where `POST /orders` receives
  different event payloads (`order.created`, `order.updated`, `order.cancelled`,
  `payment.received`, `shipment.dispatched`) — the URL is the same but the business
  event type determines the handler logic. Today this is a giant `if/elsif` inside
  the POST handler. An EventRouter would make it declarative:

  ```perl
  my $order_events = PAGI::EventRouter->new;
  $order_events->on('order.created'       => \&handle_order_created);
  $order_events->on('order.cancelled'     => \&handle_order_cancelled);
  $order_events->on('payment.received'    => \&handle_payment);
  $order_events->on('shipment.dispatched' => \&handle_shipment);

  $router->post('/orders/events' => async sub ($scope, $receive, $send) {
      my $body = await read_body($receive);
      my $event = decode_json($body);
      await $order_events->dispatch($event->{type}, $scope, $event);
  });
  ```

- **Webhook receivers**: A single endpoint receives webhooks from Stripe, GitHub,
  etc. with different event types (`charge.succeeded`, `push`, `pull_request.opened`).
  Same pattern — one URL, many event types.

- **Message queue consumers**: A PAGI app that processes messages from a queue
  dispatches on message type.

- **State machines / workflow engines**: An entity moves through states, and each
  state transition is an event that needs a different handler.

This realization suggests option 3 (separate EventRouter) is the strongest approach,
because it's not tied to any specific PAGI scope type. It's a general-purpose
event-to-handler dispatch utility that happens to be very useful alongside the
URL router.

**Endpoint::Router integration (declarative DSL)**:

If we build an EventRouter, the `PAGI::Endpoint::Router` (class-based wrapper) could
provide a declarative DSL for it:

```perl
# In Endpoint::Router — method-name based event handlers
package MyApp::OrderHandler;
use PAGI::Endpoint::Router;

websocket '/ws/orders' => sub {
    on 'order.created'  => 'handle_creation';
    on 'order.cancelled' => 'handle_cancellation';
    on 'payment.*'      => 'handle_payment_event';
};

# Or for HTTP event dispatch:
post '/orders/events' => sub {
    on_body_event 'order.created'  => 'handle_creation';
    on_body_event 'order.cancelled' => 'handle_cancellation';
};
```

This would be the "CatalystNextGen" layer — high-level declarative syntax that
compiles down to PAGI primitives (Router + EventRouter).

**Recommendation**: Don't implement in Phase 1-3. Revisit when:
- CatalystNextGen has a concrete need for custom dispatch types, OR
- Someone builds a non-HTTP PAGI server and hits the limitation, OR
- The router internals are being refactored anyway (good time to generalize)
- A complex workflow (ordering system, webhook handler) needs declarative event dispatch

The internal simplification (hashref instead of three arrays) could be done as a
refactor during Phase 1 without exposing `on_event()` publicly. This would make the
future public API addition trivial.

The EventRouter concept (option 3) could be prototyped independently as a standalone
utility module — it has no dependency on the router and could be useful immediately
for any PAGI app with event dispatch needs.

---

## Implementation Phases

### Phase 1 — Critical Foundations

Features: #1 (regex escaping bug fix), #2 (constraints), #3 (any), #4 (group + 4b router-object overload), #5 (mount path params)

These form the minimum viable feature set for CatalystNextGen. They should be implemented
together because #2, #4, #4b, and #5 all require changes to `_compile_path()`.

**Important**: #4 and #4b MUST be designed together. The callback form and Router-object
form of `group()` need consistent behavior for middleware prepending, named route handling,
and `as()` namespacing. Resolve all open concerns from #4b before implementing either form.

### Phase 2 — Developer Experience

Features: #6 (optional segments), #7 (introspection), #8 (pass/fall-through)

These significantly improve the developer experience and enable framework tooling.

### Phase 3 — Polish

Features: #9 (custom types), #10 (trailing slash), #11 (redirect routes)

Nice-to-have features that round out the router.

### Phase 4 — Specialized (As Needed)

Features: #12-#18

Only implement these if there's specific demand from users or from CatalystNextGen.

### For Consideration (No Phase Assigned)

Features: #7b (per-route metadata), #19 (on_event custom scope types)

These features are architecturally interesting but have unresolved design questions.
They are documented for future discussion, not committed to any implementation phase.

- **#7b**: Needs design discussion on built-in vs decorator vs hybrid approach.
  Best composability story is the decorator, but most pragmatic is the hybrid.
- **#19**: The internal refactor (hashref instead of three arrays) could happen
  during Phase 1 as a code quality improvement without exposing `on_event()`.
  The public API should wait for a concrete use case.

---

## Appendix: Frameworks Surveyed

### Perl
- Mojolicious::Routes (most feature-rich Perl router)
- Dancer2 routing
- Router::Simple
- Path::Router
- HTTP::Router
- Plack::App::URLMap
- Catalyst::ActionChain (chaining dispatch with `->next`)

### Python
- Starlette/FastAPI routing (ASGI, closest to PAGI's model)
- Django URL dispatcher
- Flask/Werkzeug routing

### Ruby
- Rails routing (most feature-rich overall)
- Sinatra routing
- Hanami routing

### JavaScript/TypeScript
- Express.js routing
- Fastify routing (find-my-way)
- Hono routing
- Koa (@koa/router)

### Go
- Chi router
- Gorilla/mux (richest request matching)
- Gin routing

### Rust
- Axum routing (type-safe, Tower middleware)
- Actix-web routing (guards system)
