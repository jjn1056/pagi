# Router Features Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add regex escaping for literal path segments, regex constraints on path parameters, and an `any()` multi-method matcher to PAGI::App::Router.

**Architecture:** Rewrite `_compile_path()` as a tokenizer that properly escapes literals and supports `{name}` / `{name:pattern}` syntax. Add `constraints()` chained method and `any()` route method. Update dispatch logic in `to_app()` for constraint checking and multi-method matching.

**Tech Stack:** Perl 5.18+, Test2::V0, Future::AsyncAwait, PAGI::App::Router

**Perlbrew:** All Perl commands MUST be prefixed with:
```bash
source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.40.0@default
```

---

## Task 1: Baseline — Run Existing Tests

Ensure the existing test suite passes before making any changes.

**Files:**
- Test: `t/app-router.t`, `t/router-named-routes.t`, `t/router-middleware.t`, `t/app/03-router.t`

**Step 1: Run all router tests**

Run:
```bash
bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.40.0@default && prove -l t/app-router.t t/router-named-routes.t t/router-middleware.t t/app/03-router.t'
```

Expected: All tests pass.

**Step 2: Note any pre-existing failures**

If any tests fail, document which ones and stop to consult John. Do NOT proceed with changes on a broken baseline.

---

## Task 2: Feature #1 — Write Failing Tests for Regex Escaping

Write tests that demonstrate the current `_compile_path()` bug with regex metacharacters in literal path segments.

**Files:**
- Test: `t/app-router.t` (add new subtest at end, before `done_testing`)

**Step 1: Write the failing tests**

Add this subtest to `t/app-router.t` before `done_testing;`:

```perl
subtest 'regex metacharacters in literal paths' => sub {
    my @calls;
    my $router = PAGI::App::Router->new;
    $router->get('/api/v1.0/users' => make_handler('v1_users', \@calls));
    $router->get('/files/report[2024]' => make_handler('report', \@calls));
    $router->get('/search' => make_handler('search', \@calls));

    my $app = $router->to_app;

    # Dot in path should match literally, not as regex "any char"
    my ($send, $sent) = mock_send();
    $app->({ method => 'GET', path => '/api/v1.0/users' }, sub { Future->done }, $send)->get;
    is $sent->[0]{status}, 200, 'literal dot in path matches';
    is $sent->[1]{body}, 'v1_users', 'correct handler for dotted path';

    # /api/v1X0/users should NOT match (dot is not "any char")
    ($send, $sent) = mock_send();
    $app->({ method => 'GET', path => '/api/v1X0/users' }, sub { Future->done }, $send)->get;
    is $sent->[0]{status}, 404, 'dot does not match arbitrary char';

    # Brackets in path should match literally
    ($send, $sent) = mock_send();
    $app->({ method => 'GET', path => '/files/report[2024]' }, sub { Future->done }, $send)->get;
    is $sent->[0]{status}, 200, 'literal brackets in path match';
    is $sent->[1]{body}, 'report', 'correct handler for bracketed path';
};
```

**Step 2: Run the test to verify it fails**

Run:
```bash
bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.40.0@default && prove -l t/app-router.t'
```

Expected: The new subtest FAILS — the "dot does not match arbitrary char" assertion will fail because the current code treats `.` as regex wildcard. The brackets test may die with a regex compilation error.

**Step 3: Commit the failing test**

```bash
git add t/app-router.t
git commit -m "test: add failing tests for regex metacharacters in literal paths"
```

---

## Task 3: Feature #1 — Implement Tokenizer-Based _compile_path()

Rewrite `_compile_path()` to properly escape literal segments using a tokenizer approach.

**Files:**
- Modify: `lib/PAGI/App/Router.pm:163-180` (replace `_compile_path`)

**Step 1: Implement the new _compile_path()**

Replace the existing `_compile_path` method (lines 163-180) with:

```perl
sub _compile_path {
    my ($self, $path) = @_;

    my @names;
    my @constraints;
    my $regex = '';

    # Tokenize the path
    my $remaining = $path;
    while (length $remaining) {
        # {name:pattern} — constrained parameter
        if ($remaining =~ s{^\{(\w+):([^}]+)\}}{}) {
            push @names, $1;
            push @constraints, [$1, $2];
            $regex .= "([^/]+)";
        }
        # {name} — unconstrained parameter (same as :name)
        elsif ($remaining =~ s{^\{(\w+)\}}{}) {
            push @names, $1;
            $regex .= "([^/]+)";
        }
        # *name — wildcard/splat
        elsif ($remaining =~ s{^\*(\w+)}{}) {
            push @names, $1;
            $regex .= "(.+)";
        }
        # :name — named parameter (legacy syntax)
        elsif ($remaining =~ s{^:(\w+)}{}) {
            push @names, $1;
            $regex .= "([^/]+)";
        }
        # Literal text up to next special token
        elsif ($remaining =~ s{^([^{:*]+)}{}) {
            $regex .= quotemeta($1);
        }
        # Safety: consume one character to avoid infinite loop
        else {
            $regex .= quotemeta(substr($remaining, 0, 1, ''));
        }
    }

    return (qr{^$regex$}, \@names, \@constraints);
}
```

**IMPORTANT**: The return value changes from `(qr{...}, @names)` to `(qr{...}, \@names, \@constraints)`. This is an internal-only method, but all callers must be updated.

**Step 2: Update all callers of _compile_path()**

There are 3 callers: `route()` (line 147), `websocket()` (line 110), and `sse()` (line 128).

In each, change:
```perl
my ($regex, @names) = $self->_compile_path($path);
```
to:
```perl
my ($regex, $names, $constraints) = $self->_compile_path($path);
```

And in each route hash, change:
```perl
names => \@names,
```
to:
```perl
names       => $names,
constraints => $constraints,
```

**Step 3: Run the tests**

Run:
```bash
bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.40.0@default && prove -l t/app-router.t t/router-named-routes.t t/router-middleware.t t/app/03-router.t'
```

Expected: The new regex escaping test passes. All existing tests pass (the `\@names` → `$names` change is transparent since both produce the same arrayref).

**Step 4: Commit**

```bash
git add lib/PAGI/App/Router.pm
git commit -m "feat: rewrite _compile_path() as tokenizer with proper regex escaping

Literal path segments are now escaped with quotemeta(), fixing incorrect
matching of regex metacharacters like dots and brackets. Also adds support
for {name} and {name:pattern} token types (used by constraint feature)."
```

---

## Task 4: Feature #1 — Review and Edge Cases

Review the tokenizer for edge cases and add coverage.

**Files:**
- Test: `t/app-router.t` (add edge case tests)

**Step 1: Add edge case tests**

Add another subtest to `t/app-router.t` before `done_testing;`:

```perl
subtest 'path parameter syntax variants' => sub {
    my @calls;
    my $router = PAGI::App::Router->new;
    $router->get('/users/{id}' => make_handler('brace_user', \@calls));
    $router->get('/items/:item_id/reviews/:review_id' => make_handler('review', \@calls));

    my $app = $router->to_app;

    # {name} syntax (brace-style, unconstrained)
    my ($send, $sent) = mock_send();
    $app->({ method => 'GET', path => '/users/99' }, sub { Future->done }, $send)->get;
    is $sent->[0]{status}, 200, '{id} syntax matched';
    is $calls[0]{scope}{path_params}{id}, '99', '{id} captured param';

    # Multiple params with colon syntax
    @calls = ();
    ($send, $sent) = mock_send();
    $app->({ method => 'GET', path => '/items/5/reviews/10' }, sub { Future->done }, $send)->get;
    is $sent->[0]{status}, 200, 'multiple params matched';
    is $calls[0]{scope}{path_params}{item_id}, '5', 'first param captured';
    is $calls[0]{scope}{path_params}{review_id}, '10', 'second param captured';
};
```

**Step 2: Run the test**

Run:
```bash
bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.40.0@default && prove -l t/app-router.t'
```

Expected: PASS

**Step 3: Commit**

```bash
git add t/app-router.t
git commit -m "test: add edge case tests for brace syntax and multiple params"
```

---

## Task 5: Feature #2 — Write Failing Tests for Inline Constraints

Write tests for the `{id:\d+}` inline constraint syntax.

**Files:**
- Test: `t/app-router.t` (add new subtest)

**Step 1: Write the failing tests**

Add subtest to `t/app-router.t` before `done_testing;`:

```perl
subtest 'inline constraints {name:pattern}' => sub {
    my @calls;
    my $router = PAGI::App::Router->new;
    $router->get('/users/{id:\d+}' => make_handler('user_by_id', \@calls));
    $router->get('/users/{name:[a-zA-Z]+}' => make_handler('user_by_name', \@calls));

    my $app = $router->to_app;

    # Numeric id matches first route
    my ($send, $sent) = mock_send();
    $app->({ method => 'GET', path => '/users/42' }, sub { Future->done }, $send)->get;
    is $sent->[0]{status}, 200, 'numeric id matches constrained route';
    is $sent->[1]{body}, 'user_by_id', 'correct handler for numeric id';
    is $calls[0]{scope}{path_params}{id}, '42', 'id param captured';

    # Alpha name matches second route
    @calls = ();
    ($send, $sent) = mock_send();
    $app->({ method => 'GET', path => '/users/alice' }, sub { Future->done }, $send)->get;
    is $sent->[0]{status}, 200, 'alpha name matches constrained route';
    is $sent->[1]{body}, 'user_by_name', 'correct handler for alpha name';
    is $calls[0]{scope}{path_params}{name}, 'alice', 'name param captured';

    # Mixed alphanumeric matches neither — 404
    @calls = ();
    ($send, $sent) = mock_send();
    $app->({ method => 'GET', path => '/users/bob123' }, sub { Future->done }, $send)->get;
    is $sent->[0]{status}, 404, 'mixed value matches no constrained route';
};
```

**Step 2: Run the test to verify it fails**

Run:
```bash
bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.40.0@default && prove -l t/app-router.t'
```

Expected: FAIL — the constraint check is not yet implemented in `to_app()`, so `42` matches the first route but `alice` also matches the first route (since `[^/]+` accepts anything), and `bob123` matches instead of returning 404.

**Step 3: Commit the failing test**

```bash
git add t/app-router.t
git commit -m "test: add failing tests for inline constraint syntax {name:pattern}"
```

---

## Task 6: Feature #2 — Implement Constraint Checking in Dispatch

Add constraint checking in `to_app()` dispatch logic so that inline constraints actually filter routes.

**Files:**
- Modify: `lib/PAGI/App/Router.pm` — `to_app()` method, all three dispatch sections (HTTP, WebSocket, SSE)

**Step 1: Add constraint-checking helper**

Add this method after `_compile_path()` in Router.pm:

```perl
sub _check_constraints {
    my ($self, $route, $params) = @_;
    my $constraints = $route->{constraints} // [];
    for my $c (@$constraints) {
        my ($name, $pattern) = @$c;
        my $value = $params->{$name} // return 0;
        return 0 unless $value =~ m{^(?:$pattern)$};
    }
    return 1;
}
```

**Step 2: Update HTTP dispatch (lines ~467-491)**

In the HTTP route loop inside `to_app()`, after capturing params and before calling the handler, add constraint checking. The loop currently looks like:

```perl
for my $route (@routes) {
    if ($path =~ $route->{regex}) {
        my @captures = ($path =~ $route->{regex});
        # Check method
        if ($route->{method} eq $match_method || $route->{method} eq $method) {
            # Build params ...
            await $route->{_handler}->(...);
            return;
        }
        push @method_matches, $route->{method};
    }
}
```

Restructure to:

```perl
for my $route (@routes) {
    if ($path =~ $route->{regex}) {
        my @captures = ($path =~ $route->{regex});

        # Build params
        my %params;
        for my $i (0 .. $#{$route->{names}}) {
            $params{$route->{names}[$i]} = $captures[$i];
        }

        # Check constraints
        next unless $self_ref->_check_constraints($route, \%params);

        # Check method
        if ($route->{method} eq $match_method || $route->{method} eq $method) {
            my $new_scope = {
                %$scope,
                path_params => \%params,
                'pagi.router' => { route => $route->{path} },
            };
            await $route->{_handler}->($new_scope, $receive, $send);
            return;
        }

        push @method_matches, $route->{method};
    }
}
```

**IMPORTANT**: The `to_app()` closure currently has no reference to `$self`. You need to capture `$self` as a weak reference for constraint checking. Add at the top of `to_app()`:

```perl
my $self_ref = $self;
```

Then use `$self_ref->_check_constraints(...)` inside the closure.

**Step 3: Update WebSocket dispatch (lines ~391-406)**

Same pattern — add params build and constraint check before calling handler:

```perl
for my $route (@websocket_routes) {
    if ($path =~ $route->{regex}) {
        my @captures = ($path =~ $route->{regex});
        my %params;
        for my $i (0 .. $#{$route->{names}}) {
            $params{$route->{names}[$i]} = $captures[$i];
        }
        next unless $self_ref->_check_constraints($route, \%params);

        my $new_scope = {
            %$scope,
            path_params => \%params,
            'pagi.router' => { route => $route->{path} },
        };
        await $route->{_handler}->($new_scope, $receive, $send);
        return;
    }
}
```

**Step 4: Update SSE dispatch (lines ~427-442)**

Same pattern as WebSocket.

**Step 5: Run the tests**

Run:
```bash
bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.40.0@default && prove -l t/app-router.t t/router-named-routes.t t/router-middleware.t t/app/03-router.t'
```

Expected: ALL tests pass including the inline constraint tests.

**Step 6: Commit**

```bash
git add lib/PAGI/App/Router.pm
git commit -m "feat: implement constraint checking in dispatch

Routes with inline constraints {name:pattern} now properly filter during
dispatch. If a path parameter fails its constraint regex, the route is
skipped and the next matching route is tried."
```

---

## Task 7: Feature #2 — Write Failing Tests for Chained constraints()

Write tests for the `->constraints()` chained method.

**Files:**
- Test: `t/app-router.t` (add new subtest)

**Step 1: Write the failing tests**

Add subtest to `t/app-router.t` before `done_testing;`:

```perl
subtest 'chained constraints() method' => sub {
    my @calls;
    my $router = PAGI::App::Router->new;
    $router->get('/posts/:id' => make_handler('post', \@calls))
        ->constraints(id => qr/^\d+$/);

    my $app = $router->to_app;

    # Numeric id matches
    my ($send, $sent) = mock_send();
    $app->({ method => 'GET', path => '/posts/7' }, sub { Future->done }, $send)->get;
    is $sent->[0]{status}, 200, 'numeric id matches with chained constraint';
    is $calls[0]{scope}{path_params}{id}, '7', 'param captured';

    # Non-numeric id does not match — 404
    @calls = ();
    ($send, $sent) = mock_send();
    $app->({ method => 'GET', path => '/posts/latest' }, sub { Future->done }, $send)->get;
    is $sent->[0]{status}, 404, 'non-numeric id rejected by chained constraint';
};

subtest 'constraints on websocket and sse routes' => sub {
    my @calls;
    my $router = PAGI::App::Router->new;
    $router->websocket('/ws/{room:\w+}' => make_handler('ws', \@calls));
    $router->sse('/events/:channel' => make_handler('sse', \@calls))
        ->constraints(channel => qr/^[a-z]+$/);

    my $app = $router->to_app;

    # WebSocket with inline constraint
    my ($send, $sent) = mock_send();
    $app->({ type => 'websocket', path => '/ws/lobby' }, sub { Future->done }, $send)->get;
    is $sent->[0]{status}, 200, 'websocket inline constraint matches';

    # WebSocket fails constraint
    ($send, $sent) = mock_send();
    $app->({ type => 'websocket', path => '/ws/lobby!!' }, sub { Future->done }, $send)->get;
    is $sent->[0]{status}, 404, 'websocket inline constraint rejects';

    # SSE with chained constraint
    @calls = ();
    ($send, $sent) = mock_send();
    $app->({ type => 'sse', path => '/events/news' }, sub { Future->done }, $send)->get;
    is $sent->[0]{status}, 200, 'sse chained constraint matches';

    # SSE fails chained constraint
    ($send, $sent) = mock_send();
    $app->({ type => 'sse', path => '/events/NEWS123' }, sub { Future->done }, $send)->get;
    is $sent->[0]{status}, 404, 'sse chained constraint rejects';
};
```

**Step 2: Run the test to verify it fails**

Run:
```bash
bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.40.0@default && prove -l t/app-router.t'
```

Expected: FAIL — `constraints()` method doesn't exist yet.

**Step 3: Commit the failing test**

```bash
git add t/app-router.t
git commit -m "test: add failing tests for chained constraints() method"
```

---

## Task 8: Feature #2 — Implement constraints() Method

Add the chainable `constraints()` method.

**Files:**
- Modify: `lib/PAGI/App/Router.pm` — add `constraints()` method

**Step 1: Implement constraints()**

Add this method after the `name()` method (after line 201):

```perl
sub constraints {
    my ($self, %new_constraints) = @_;

    croak "constraints() called without a preceding route" unless $self->{_last_route};

    my $route = $self->{_last_route};
    my $existing = $route->{constraints} // [];

    for my $name (keys %new_constraints) {
        my $pattern = $new_constraints{$name};
        croak "Constraint for '$name' must be a Regexp (qr//), got " . ref($pattern)
            unless ref($pattern) eq 'Regexp';
        push @$existing, [$name, $pattern];
    }
    $route->{constraints} = $existing;

    return $self;
}
```

**Step 2: Run the tests**

Run:
```bash
bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.40.0@default && prove -l t/app-router.t t/router-named-routes.t t/router-middleware.t t/app/03-router.t'
```

Expected: ALL tests pass.

**Step 3: Commit**

```bash
git add lib/PAGI/App/Router.pm
git commit -m "feat: add chainable constraints() method for regex path constraints

Allows post-registration constraint application via chaining:
  \$router->get('/posts/:id' => \$h)->constraints(id => qr/^\d+\$/);

Constraints are merged into the route's constraint list and checked
during dispatch alongside inline {name:pattern} constraints."
```

---

## Task 9: Feature #2 — Constraint Error Tests and Edge Cases

Test error handling and edge cases for constraints.

**Files:**
- Test: `t/app-router.t` (add new subtest)

**Step 1: Write error and edge case tests**

Add subtest to `t/app-router.t` before `done_testing;`:

```perl
subtest 'constraints error handling' => sub {
    my $router = PAGI::App::Router->new;

    # constraints() without preceding route
    like dies { $router->constraints(id => qr/\d+/) },
        qr/constraints\(\) called without a preceding route/,
        'croak when no route to constrain';

    # Non-regex constraint value
    $router->get('/test/:id' => sub {});
    like dies { $router->constraints(id => 'not_a_regex') },
        qr/must be a Regexp/,
        'croak on non-Regexp constraint';
};

subtest 'constraints with 405 interaction' => sub {
    my @calls;
    my $router = PAGI::App::Router->new;
    $router->get('/items/{id:\d+}' => make_handler('get_item', \@calls));
    $router->delete('/items/{id:\d+}' => make_handler('delete_item', \@calls));

    my $app = $router->to_app;

    # PUT /items/5 — path matches but method doesn't, should be 405
    my ($send, $sent) = mock_send();
    $app->({ method => 'PUT', path => '/items/5' }, sub { Future->done }, $send)->get;
    is $sent->[0]{status}, 405, 'constrained route gives 405 on wrong method';
    my %headers = map { $_->[0] => $_->[1] } @{$sent->[0]{headers}};
    like $headers{allow}, qr/DELETE/, 'Allow includes DELETE';
    like $headers{allow}, qr/GET/, 'Allow includes GET';

    # PUT /items/abc — constraint fails, no path match at all, should be 404
    ($send, $sent) = mock_send();
    $app->({ method => 'PUT', path => '/items/abc' }, sub { Future->done }, $send)->get;
    is $sent->[0]{status}, 404, 'failed constraint gives 404 not 405';
};
```

**Step 2: Run the tests**

Run:
```bash
bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.40.0@default && prove -l t/app-router.t'
```

Expected: PASS

**Step 3: Commit**

```bash
git add t/app-router.t
git commit -m "test: add constraint error handling and 405 interaction tests"
```

---

## Task 10: Feature #3 — Write Failing Tests for any()

Write tests for the `any()` multi-method matcher.

**Files:**
- Test: `t/app-router.t` (add new subtest)

**Step 1: Write the failing tests**

Add subtests to `t/app-router.t` before `done_testing;`:

```perl
subtest 'any() wildcard matches all methods' => sub {
    my @calls;
    my $router = PAGI::App::Router->new;
    $router->any('/health' => make_handler('health', \@calls));

    my $app = $router->to_app;

    for my $method (qw(GET POST PUT DELETE PATCH HEAD OPTIONS)) {
        @calls = ();
        my ($send, $sent) = mock_send();
        $app->({ method => $method, path => '/health' }, sub { Future->done }, $send)->get;
        is $sent->[0]{status}, 200, "any() matches $method";
    }
};

subtest 'any() with explicit method list' => sub {
    my @calls;
    my $router = PAGI::App::Router->new;
    $router->any('/resource' => make_handler('resource', \@calls), method => ['GET', 'POST']);

    my $app = $router->to_app;

    # GET matches
    my ($send, $sent) = mock_send();
    $app->({ method => 'GET', path => '/resource' }, sub { Future->done }, $send)->get;
    is $sent->[0]{status}, 200, 'any([GET,POST]) matches GET';

    # POST matches
    ($send, $sent) = mock_send();
    $app->({ method => 'POST', path => '/resource' }, sub { Future->done }, $send)->get;
    is $sent->[0]{status}, 200, 'any([GET,POST]) matches POST';

    # DELETE does not match — should be 405
    ($send, $sent) = mock_send();
    $app->({ method => 'DELETE', path => '/resource' }, sub { Future->done }, $send)->get;
    is $sent->[0]{status}, 405, 'any([GET,POST]) gives 405 for DELETE';
    my %headers = map { $_->[0] => $_->[1] } @{$sent->[0]{headers}};
    like $headers{allow}, qr/GET/, 'Allow includes GET';
    like $headers{allow}, qr/POST/, 'Allow includes POST';
};

subtest 'any() with params and constraints' => sub {
    my @calls;
    my $router = PAGI::App::Router->new;
    $router->any('/items/{id:\d+}' => make_handler('item', \@calls));

    my $app = $router->to_app;

    my ($send, $sent) = mock_send();
    $app->({ method => 'PATCH', path => '/items/42' }, sub { Future->done }, $send)->get;
    is $sent->[0]{status}, 200, 'any() with constraint matches';
    is $calls[0]{scope}{path_params}{id}, '42', 'param captured';
};

subtest 'any() with middleware' => sub {
    my @calls;
    my $mw = async sub {
        my ($scope, $receive, $send, $next) = @_;
        $scope->{mw_ran} = 1;
        await $next->();
    };

    my $router = PAGI::App::Router->new;
    $router->any('/mw-test' => [$mw] => make_handler('mw_handler', \@calls));

    my $app = $router->to_app;

    my ($send, $sent) = mock_send();
    $app->({ method => 'GET', path => '/mw-test' }, sub { Future->done }, $send)->get;
    is $sent->[0]{status}, 200, 'any() with middleware works';
    is $calls[0]{scope}{mw_ran}, 1, 'middleware executed';
};
```

**Step 2: Run the test to verify it fails**

Run:
```bash
bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.40.0@default && prove -l t/app-router.t'
```

Expected: FAIL — `any()` method doesn't exist yet.

**Step 3: Commit the failing test**

```bash
git add t/app-router.t
git commit -m "test: add failing tests for any() multi-method matcher"
```

---

## Task 11: Feature #3 — Implement any() Method

Add the `any()` route method.

**Files:**
- Modify: `lib/PAGI/App/Router.pm` — add `any()` method, update `route()`, update dispatch

**Step 1: Implement any()**

Add after the `options` method (after line 105):

```perl
sub any {
    my ($self, $path, @rest) = @_;

    # Parse optional trailing key-value args (method => [...])
    my %opts;
    if (@rest >= 2 && !ref($rest[-2]) && $rest[-2] eq 'method') {
        %opts = splice(@rest, -2);
    }

    my $method = $opts{method} // '*';
    if (ref($method) eq 'ARRAY') {
        $method = [map { uc($_) } @$method];
    }

    $self->route($method, $path, @rest);
}
```

**Step 2: Update route() to accept arrayref and '*'**

Change `route()` method's `method` line from:

```perl
method => uc($method),
```

to:

```perl
method => ref($method) eq 'ARRAY' ? $method : ($method eq '*' ? '*' : uc($method)),
```

**Step 3: Update HTTP dispatch method matching**

In the HTTP dispatch loop inside `to_app()`, change the method check from:

```perl
if ($route->{method} eq $match_method || $route->{method} eq $method) {
```

to:

```perl
my $route_method = $route->{method};
my $method_match = ref($route_method) eq 'ARRAY'
    ? (grep { $_ eq $match_method || $_ eq $method } @$route_method)
    : ($route_method eq '*' || $route_method eq $match_method || $route_method eq $method);

if ($method_match) {
```

**Step 4: Update 405 Allow header computation**

In the method_matches push (the else branch when method doesn't match), change from:

```perl
push @method_matches, $route->{method};
```

to:

```perl
if (ref($route->{method}) eq 'ARRAY') {
    push @method_matches, @{$route->{method}};
} elsif ($route->{method} ne '*') {
    push @method_matches, $route->{method};
}
```

Note: Wildcard (`*`) routes should NOT produce a 405 since they accept all methods. If a wildcard route's path matches, it always matches on method too, so it won't reach this else branch. But if constraints cause a wildcard to be skipped, we don't add it to `@method_matches` because it would accept all methods.

**Step 5: Run the tests**

Run:
```bash
bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.40.0@default && prove -l t/app-router.t t/router-named-routes.t t/router-middleware.t t/app/03-router.t'
```

Expected: ALL tests pass.

**Step 6: Commit**

```bash
git add lib/PAGI/App/Router.pm
git commit -m "feat: add any() multi-method matcher

Supports wildcard (all methods) and explicit method list:
  \$router->any('/health' => \$handler);            # all methods
  \$router->any('/res' => \$handler, method => ['GET','POST']);

Wildcard routes match any HTTP method. Explicit lists produce 405
with correct Allow header for non-matching methods."
```

---

## Task 12: Feature #3 — any() Named Route and uri_for Support

Ensure `any()` routes work with `name()` and `uri_for()`.

**Files:**
- Test: `t/router-named-routes.t` (add new subtest)

**Step 1: Write the test**

Add subtest to `t/router-named-routes.t` before `done_testing;`:

```perl
subtest 'any() route with name' => sub {
    my $router = PAGI::App::Router->new;

    $router->any('/health' => sub {})->name('health');
    $router->any('/items/{id:\d+}' => sub {}, method => ['GET', 'PUT'])->name('items.detail');

    is $router->uri_for('health'), '/health', 'any() route uri_for works';
    is $router->uri_for('items.detail', { id => 5 }), '/items/5', 'any() with constraint uri_for works';
};
```

**Step 2: Run the test**

Run:
```bash
bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.40.0@default && prove -l t/router-named-routes.t'
```

Expected: PASS (or FAIL if `uri_for` doesn't handle `{name}` / `{name:pattern}` substitution).

**Step 3: If uri_for fails, update it**

The current `uri_for` only handles `:name` and `*name` substitution. It needs to also handle `{name}` and `{name:pattern}`. Update the substitution loop in `uri_for()`:

Change:
```perl
$path =~ s/:$param_name\b/$value/;
$path =~ s/\*$param_name\b/$value/;
```

To:
```perl
$path =~ s/:$param_name\b/$value/
    || $path =~ s/\{$param_name(?::[^}]*)?\}/$value/
    || $path =~ s/\*$param_name\b/$value/;
```

**Step 4: Run all named route tests**

Run:
```bash
bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.40.0@default && prove -l t/router-named-routes.t'
```

Expected: ALL tests pass.

**Step 5: Commit**

```bash
git add lib/PAGI/App/Router.pm t/router-named-routes.t
git commit -m "feat: support any() and {name:pattern} in named routes and uri_for"
```

---

## Task 13: Comprehensive Integration Tests

Write integration tests that combine all three features together.

**Files:**
- Test: `t/app-router.t` (add new subtest)

**Step 1: Write integration tests**

Add subtest to `t/app-router.t` before `done_testing;`:

```perl
subtest 'combined features integration' => sub {
    my @calls;
    my $router = PAGI::App::Router->new;

    # Feature #1: Regex escaping with Feature #2: constraints
    $router->get('/api/v2.0/users/{id:\d+}' => make_handler('v2_user', \@calls));

    # Feature #2: Chained constraints with Feature #3: any()
    $router->any('/articles/:slug' => make_handler('article', \@calls), method => ['GET', 'PUT'])
        ->constraints(slug => qr/^[a-z0-9-]+$/);

    # Feature #3: Wildcard any() with Feature #1: escaped path
    $router->any('/status(check)' => make_handler('status', \@calls));

    my $app = $router->to_app;

    # v2.0 with dots + constraint
    my ($send, $sent) = mock_send();
    $app->({ method => 'GET', path => '/api/v2.0/users/99' }, sub { Future->done }, $send)->get;
    is $sent->[0]{status}, 200, 'dotted path + constraint match';
    is $calls[0]{scope}{path_params}{id}, '99', 'param captured';

    # v2.0 + failed constraint
    @calls = ();
    ($send, $sent) = mock_send();
    $app->({ method => 'GET', path => '/api/v2.0/users/abc' }, sub { Future->done }, $send)->get;
    is $sent->[0]{status}, 404, 'dotted path + failed constraint = 404';

    # any() + chained constraint — valid slug, allowed method
    @calls = ();
    ($send, $sent) = mock_send();
    $app->({ method => 'GET', path => '/articles/my-first-post' }, sub { Future->done }, $send)->get;
    is $sent->[0]{status}, 200, 'any() + chained constraint match';

    # any() + chained constraint — valid slug, disallowed method
    ($send, $sent) = mock_send();
    $app->({ method => 'DELETE', path => '/articles/my-first-post' }, sub { Future->done }, $send)->get;
    is $sent->[0]{status}, 405, 'any() + chained constraint 405 on wrong method';

    # any() + chained constraint — invalid slug
    ($send, $sent) = mock_send();
    $app->({ method => 'GET', path => '/articles/BAD SLUG!' }, sub { Future->done }, $send)->get;
    is $sent->[0]{status}, 404, 'any() + failed chained constraint = 404';

    # Escaped parens in path
    @calls = ();
    ($send, $sent) = mock_send();
    $app->({ method => 'POST', path => '/status(check)' }, sub { Future->done }, $send)->get;
    is $sent->[0]{status}, 200, 'escaped parens in path match';
};
```

**Step 2: Run the tests**

Run:
```bash
bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.40.0@default && prove -l t/app-router.t'
```

Expected: PASS

**Step 3: Commit**

```bash
git add t/app-router.t
git commit -m "test: add comprehensive integration tests for all three features"
```

---

## Task 14: Update POD Documentation

Update the Router.pm POD to document all three features.

**Files:**
- Modify: `lib/PAGI/App/Router.pm` — update SYNOPSIS, PATH PATTERNS, add CONSTRAINTS section, add `any()` docs

**Step 1: Update SYNOPSIS**

Add to the SYNOPSIS block (after the existing examples, before `my $app = $router->to_app`):

```perl
    # Match any HTTP method
    $router->any('/health' => $health_handler);
    $router->any('/resource' => $handler, method => ['GET', 'POST']);

    # Path constraints (inline)
    $router->get('/users/{id:\d+}' => $get_user);

    # Path constraints (chained)
    $router->get('/posts/:slug' => $get_post)
        ->constraints(slug => qr/^[a-z0-9-]+$/);
```

**Step 2: Update PATH PATTERNS section**

Replace the PATH PATTERNS section with:

```pod
=head1 PATH PATTERNS

=over 4

=item * C</users/:id> - Named parameter (colon syntax), captured as C<params-E<gt>{id}>

=item * C</users/{id}> - Named parameter (brace syntax), same as C<:id>

=item * C</users/{id:\d+}> - Constrained parameter, only matches if value matches C<\d+>

=item * C</files/*path> - Wildcard, captures rest of path as C<params-E<gt>{path}>

=back

Literal path segments are properly escaped, so metacharacters like C<.>, C<(>, C<[>
in paths match literally. For example, C</api/v1.0/users> only matches a literal
dot, not any character.
```

**Step 3: Add CONSTRAINTS section**

Add after the PATH PATTERNS section:

```pod
=head1 CONSTRAINTS

Path parameters can be constrained with regex patterns. A constrained parameter
must match its pattern for the route to match; if it doesn't, the router tries
the next route.

=head2 Inline Constraints

Embed the pattern directly in the path:

    $router->get('/users/{id:\d+}' => $handler);
    $router->get('/posts/{slug:[a-z0-9-]+}' => $handler);

=head2 Chained Constraints

Apply constraints after route registration using C<constraints()>:

    $router->get('/users/:id' => $handler)
        ->constraints(id => qr/^\d+$/);

Constraint values must be compiled regexes (C<qr//>). The regex is
anchored to the full parameter value during matching.

Both syntaxes can be combined. Chained constraints are merged with
any inline constraints.

=head2 constraints

    $router->get('/path/:param' => $handler)->constraints(param => qr/pattern/);

Apply regex constraints to path parameters. Returns C<$self> for chaining.
Croaks if called without a preceding route or with a non-Regexp constraint.
```

**Step 4: Add any() documentation**

Add to the HTTP Route Methods section, after the existing method docs:

```pod
=head2 any

    $router->any('/health' => $app);                              # all methods
    $router->any('/resource' => $app, method => ['GET', 'POST']); # specific methods
    $router->any('/path' => \@middleware => $app);                 # with middleware

Register a route that matches multiple or all HTTP methods. Without a
C<method> option, matches any HTTP method. With C<method>, only matches
the specified methods and returns 405 for others.

Returns C<$self> for chaining (supports C<name()>, C<constraints()>).
```

**Step 5: Run all tests to ensure nothing broke**

Run:
```bash
bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.40.0@default && prove -l t/app-router.t t/router-named-routes.t t/router-middleware.t t/app/03-router.t'
```

Expected: ALL tests pass (POD changes don't affect behavior).

**Step 6: Commit**

```bash
git add lib/PAGI/App/Router.pm
git commit -m "docs: update Router POD for constraints, any(), and regex escaping"
```

---

## Task 15: Final Consistency Review

Review all changes for dead code, inconsistencies between code/docs/tests, bugs, security issues, and performance.

**Files:**
- Review: `lib/PAGI/App/Router.pm` (full read)
- Review: `t/app-router.t` (full read)
- Review: `t/router-named-routes.t` (full read)

**Step 1: Full re-read of Router.pm**

Read the entire file. Check for:
- Dead code or unused variables
- Inconsistencies between docs and implementation
- Missing error handling (e.g., invalid regex in inline constraint)
- Performance issues (constraint checking in hot path)
- Security issues (regex injection via user-provided constraint patterns — not applicable since constraints are developer-authored)

**Step 2: Full re-read of test files**

Read all modified test files. Check for:
- Tests that test mocked behavior instead of real logic
- Missing test coverage (e.g., HEAD matching with any(), constraints on wildcard params)
- Test descriptions that don't match what's being tested

**Step 3: Cross-check docs vs implementation**

Verify every feature documented in POD has corresponding test coverage and vice versa.

**Step 4: Run the full router test suite one final time**

Run:
```bash
bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.40.0@default && prove -l t/app-router.t t/router-named-routes.t t/router-middleware.t t/app/03-router.t'
```

Expected: ALL tests pass.

**Step 5: Fix any issues found, commit if needed**

If issues are found, fix them and commit with a descriptive message.

**Step 6: Final commit if any cleanup was needed**

```bash
git add -A
git commit -m "review: final consistency pass across router code, docs, and tests"
```

---

Plan complete and saved to `docs/plans/2026-02-17-router-features-implementation.md`. Two execution options:

**1. Subagent-Driven (this session)** - I dispatch fresh subagent per task, review between tasks, fast iteration

**2. Parallel Session (separate)** - Open new session with executing-plans, batch execution with checkpoints

Which approach, John?