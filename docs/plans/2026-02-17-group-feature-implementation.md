# Route Grouping (`group()`) Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add `group()` to `PAGI::App::Router` for flattening routes under a shared prefix with shared middleware.

**Architecture:** Prefix stack on the router — `route()`, `websocket()`, `sse()` check `_group_stack` and prepend accumulated prefix/middleware before compiling. Three forms: callback (coderef), router-object (`PAGI::App::Router`), and string (auto-require + `->router`). Constraint storage split into inline vs chained to support clean route copying.

**Tech Stack:** Perl 5.18+, Test2::V0, Future::AsyncAwait

**Perlbrew:** `source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.40.0@default`

**Design doc:** `docs/plans/2026-02-17-group-feature-design.md`

---

### Task 1: Baseline — Verify All Existing Tests Pass

**Files:**
- Test: `t/app-router.t`
- Test: `t/router-named-routes.t`

**Step 1: Run all router tests**

Run: `bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.40.0@default && prove -l t/app-router.t t/router-named-routes.t'`
Expected: All tests pass (56 tests across both files)

**Step 2: Run full test suite**

Run: `bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.40.0@default && prove -l t/'`
Expected: All tests pass

---

### Task 2: Constraint Storage Refactor

Split internal constraint storage so chained constraints survive route copying.

**Files:**
- Modify: `lib/PAGI/App/Router.pm:270-287` (`constraints()` method)
- Modify: `lib/PAGI/App/Router.pm:238-247` (`_check_constraints()` method)
- Test: `t/app-router.t` (existing tests verify behavior unchanged)

**Step 1: Write a failing test for separate constraint storage**

Add to `t/app-router.t` before `done_testing;`:

```perl
subtest 'internal: chained constraints stored separately' => sub {
    my $router = PAGI::App::Router->new;
    $router->get('/users/{id:\d+}' => sub {})
        ->constraints(id => qr/^\d+$/);

    my $route = $router->{routes}[0];
    ok $route->{constraints}, 'has inline constraints';
    ok $route->{_user_constraints}, 'has separate user constraints';
    is scalar @{$route->{constraints}}, 1, 'one inline constraint';
    is scalar @{$route->{_user_constraints}}, 1, 'one user constraint';
};
```

**Step 2: Run test to verify it fails**

Run: `bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.40.0@default && prove -l t/app-router.t :: internal'`
Expected: FAIL — `_user_constraints` doesn't exist yet

**Step 3: Implement constraint storage split**

In `lib/PAGI/App/Router.pm`, modify `constraints()` method (lines 270-287):

```perl
sub constraints {
    my ($self, %new_constraints) = @_;

    croak "constraints() called without a preceding route" unless $self->{_last_route};

    my $route = $self->{_last_route};
    my $user_constraints = $route->{_user_constraints} //= [];

    for my $name (keys %new_constraints) {
        my $pattern = $new_constraints{$name};
        croak "Constraint for '$name' must be a Regexp (qr//), got " . ref($pattern)
            unless ref($pattern) eq 'Regexp';
        push @$user_constraints, [$name, $pattern];
    }

    return $self;
}
```

Modify `_check_constraints()` method (lines 238-247):

```perl
sub _check_constraints {
    my ($self, $route, $params) = @_;
    for my $constraints_list ($route->{constraints} // [], $route->{_user_constraints} // []) {
        for my $c (@$constraints_list) {
            my ($name, $pattern) = @$c;
            my $value = $params->{$name} // return 0;
            return 0 unless $value =~ m/^(?:$pattern)$/;
        }
    }
    return 1;
}
```

**Step 4: Run tests to verify everything passes**

Run: `bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.40.0@default && prove -l t/app-router.t t/router-named-routes.t'`
Expected: ALL tests pass (new test + all existing constraint tests)

**Step 5: Commit**

```bash
git add lib/PAGI/App/Router.pm t/app-router.t
git commit -m "refactor: split constraint storage into inline and chained"
```

---

### Task 3: Group Stack Infrastructure

Add `_group_stack` to the router and make `route()`, `websocket()`, and `sse()` group-aware.

**Files:**
- Modify: `lib/PAGI/App/Router.pm:67-80` (`new`)
- Modify: `lib/PAGI/App/Router.pm:173-192` (`route()`)
- Modify: `lib/PAGI/App/Router.pm:135-152` (`websocket()`)
- Modify: `lib/PAGI/App/Router.pm:154-171` (`sse()`)

**Step 1: Add `_group_stack` to `new()`**

In `new()`, add to the blessed hash:

```perl
_group_stack  => [],   # for group() prefix/middleware accumulation
```

**Step 2: Add stack application to `route()`**

At the top of `route()`, after parsing args, add:

```perl
sub route {
    my ($self, $method, $path, @rest) = @_;

    my ($middleware, $app) = $self->_parse_route_args(@rest);

    # Apply accumulated group context
    for my $ctx (@{$self->{_group_stack}}) {
        $path = $ctx->{prefix} . $path;
        unshift @$middleware, @{$ctx->{middleware}};
    }

    my ($regex, $names, $constraints) = $self->_compile_path($path);
    # ... rest unchanged
```

**Step 3: Add stack application to `websocket()`**

Same pattern — after `_parse_route_args`, apply stack:

```perl
sub websocket {
    my ($self, $path, @rest) = @_;
    my ($middleware, $app) = $self->_parse_route_args(@rest);

    # Apply accumulated group context
    for my $ctx (@{$self->{_group_stack}}) {
        $path = $ctx->{prefix} . $path;
        unshift @$middleware, @{$ctx->{middleware}};
    }

    my ($regex, $names, $constraints) = $self->_compile_path($path);
    # ... rest unchanged
```

**Step 4: Add stack application to `sse()`**

Same pattern as websocket.

**Step 5: Run all existing tests to verify no regression**

Run: `bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.40.0@default && prove -l t/app-router.t t/router-named-routes.t'`
Expected: All tests still pass (stack is empty, zero behavioral change)

**Step 6: Commit**

```bash
git add lib/PAGI/App/Router.pm
git commit -m "feat: add group stack infrastructure to route registration"
```

---

### Task 4: Callback Form — Basic Prefix Grouping

**Files:**
- Modify: `lib/PAGI/App/Router.pm` (add `group()` method)
- Create: `t/app-router-group.t`

**Step 1: Write failing tests for basic callback group**

Create `t/app-router-group.t`:

```perl
use strict;
use warnings;

use Test2::V0;
use Future::AsyncAwait;

use PAGI::App::Router;

# Helper to capture response
sub mock_send {
    my @sent;
    my $send = sub { my ($msg) = @_; push @sent, $msg; Future->done };
    return ($send, \@sent);
}

# Helper to create a simple handler
sub make_handler {
    my ($name, $capture) = @_;
    return async sub {
        my ($scope, $receive, $send) = @_;
        push @$capture, { name => $name, scope => $scope } if $capture;
        await $send->({
            type => 'http.response.start',
            status => 200,
            headers => [['content-type', 'text/plain']],
        });
        await $send->({
            type => 'http.response.body',
            body => $name,
            more => 0,
        });
    };
}

subtest 'callback group: basic prefix' => sub {
    my @calls;
    my $router = PAGI::App::Router->new;

    $router->group('/api' => sub {
        my ($r) = @_;
        $r->get('/users' => make_handler('list_users', \@calls));
        $r->post('/users' => make_handler('create_user', \@calls));
        $r->get('/users/:id' => make_handler('get_user', \@calls));
    });

    my $app = $router->to_app;

    # GET /api/users
    my ($send, $sent) = mock_send();
    $app->({ method => 'GET', path => '/api/users' }, sub { Future->done }, $send)->get;
    is $sent->[0]{status}, 200, 'GET /api/users matches';
    is $sent->[1]{body}, 'list_users', 'correct handler';

    # POST /api/users
    ($send, $sent) = mock_send();
    $app->({ method => 'POST', path => '/api/users' }, sub { Future->done }, $send)->get;
    is $sent->[0]{status}, 200, 'POST /api/users matches';
    is $sent->[1]{body}, 'create_user', 'correct handler';

    # GET /api/users/42
    @calls = ();
    ($send, $sent) = mock_send();
    $app->({ method => 'GET', path => '/api/users/42' }, sub { Future->done }, $send)->get;
    is $sent->[0]{status}, 200, 'GET /api/users/:id matches';
    is $calls[0]{scope}{path_params}{id}, '42', 'param captured with prefix';

    # /users without prefix — 404
    ($send, $sent) = mock_send();
    $app->({ method => 'GET', path => '/users' }, sub { Future->done }, $send)->get;
    is $sent->[0]{status}, 404, '/users without prefix is 404';

    # Routes coexist with non-grouped routes
    $router->get('/health' => make_handler('health'));
    $app = $router->to_app;
    ($send, $sent) = mock_send();
    $app->({ method => 'GET', path => '/health' }, sub { Future->done }, $send)->get;
    is $sent->[0]{status}, 200, 'non-grouped route still works';
};

done_testing;
```

**Step 2: Run test to verify it fails**

Run: `bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.40.0@default && prove -l t/app-router-group.t'`
Expected: FAIL — `group()` method doesn't exist

**Step 3: Implement `group()` — callback form only**

Add to `lib/PAGI/App/Router.pm` after the `any()` method (after line 133):

```perl
sub group {
    my ($self, $prefix, @rest) = @_;
    $prefix =~ s{/$}{}; # strip trailing slash

    my ($middleware, $target) = $self->_parse_route_args(@rest);

    if (ref($target) eq 'CODE') {
        push @{$self->{_group_stack}}, {
            prefix     => $prefix,
            middleware => [@$middleware],
        };
        $target->($self);
        pop @{$self->{_group_stack}};
    }
    else {
        croak "group() target must be a coderef, PAGI::App::Router, or package name, got "
            . (ref($target) || 'scalar');
    }

    $self->{_last_route} = undef;
    $self->{_last_mount} = undef;

    return $self;
}
```

**Step 4: Run tests**

Run: `bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.40.0@default && prove -l t/app-router-group.t t/app-router.t t/router-named-routes.t'`
Expected: All pass

**Step 5: Commit**

```bash
git add lib/PAGI/App/Router.pm t/app-router-group.t
git commit -m "feat: add group() callback form with basic prefix"
```

---

### Task 5: Callback Form — Middleware and Nesting

**Files:**
- Modify: `t/app-router-group.t`
- (No implementation changes needed — stack already handles this)

**Step 1: Write failing tests for middleware and nesting**

Add to `t/app-router-group.t` before `done_testing;`:

```perl
subtest 'callback group: with middleware' => sub {
    my @calls;
    my $mw_log = [];
    my $auth_mw = async sub {
        my ($scope, $receive, $send, $next) = @_;
        push @$mw_log, 'auth';
        $scope->{authed} = 1;
        await $next->();
    };

    my $router = PAGI::App::Router->new;
    $router->group('/admin' => [$auth_mw] => sub {
        my ($r) = @_;
        $r->get('/dashboard' => make_handler('dashboard', \@calls));
        $r->get('/settings' => make_handler('settings', \@calls));
    });

    my $app = $router->to_app;

    my ($send, $sent) = mock_send();
    $app->({ method => 'GET', path => '/admin/dashboard' }, sub { Future->done }, $send)->get;
    is $sent->[0]{status}, 200, 'grouped route with middleware matches';
    is scalar @$mw_log, 1, 'middleware executed once';
    is $calls[0]{scope}{authed}, 1, 'middleware modified scope';
};

subtest 'callback group: middleware stacking with route middleware' => sub {
    my $order = [];
    my $group_mw = async sub {
        my ($scope, $receive, $send, $next) = @_;
        push @$order, 'group';
        await $next->();
    };
    my $route_mw = async sub {
        my ($scope, $receive, $send, $next) = @_;
        push @$order, 'route';
        await $next->();
    };

    my $router = PAGI::App::Router->new;
    $router->group('/api' => [$group_mw] => sub {
        my ($r) = @_;
        $r->get('/data' => [$route_mw] => make_handler('data'));
    });

    my $app = $router->to_app;
    my ($send, $sent) = mock_send();
    $app->({ method => 'GET', path => '/api/data' }, sub { Future->done }, $send)->get;
    is $sent->[0]{status}, 200, 'stacked middleware route matches';
    is $order->[0], 'group', 'group middleware runs first';
    is $order->[1], 'route', 'route middleware runs second';
};

subtest 'callback group: nested groups' => sub {
    my @calls;
    my $org_mw_ran = 0;
    my $org_mw = async sub {
        my ($scope, $receive, $send, $next) = @_;
        $org_mw_ran++;
        await $next->();
    };
    my $team_mw_ran = 0;
    my $team_mw = async sub {
        my ($scope, $receive, $send, $next) = @_;
        $team_mw_ran++;
        await $next->();
    };

    my $router = PAGI::App::Router->new;
    $router->group('/orgs/:org_id' => [$org_mw] => sub {
        my ($r) = @_;
        $r->get('/info' => make_handler('org_info', \@calls));

        $r->group('/teams/:team_id' => [$team_mw] => sub {
            my ($r) = @_;
            $r->get('/members' => make_handler('team_members', \@calls));
        });
    });

    my $app = $router->to_app;

    # GET /orgs/acme/info
    my ($send, $sent) = mock_send();
    $app->({ method => 'GET', path => '/orgs/acme/info' }, sub { Future->done }, $send)->get;
    is $sent->[0]{status}, 200, 'outer group route matches';
    is $calls[0]{scope}{path_params}{org_id}, 'acme', 'outer param captured';
    is $org_mw_ran, 1, 'outer middleware ran';
    is $team_mw_ran, 0, 'inner middleware did not run';

    # GET /orgs/acme/teams/eng/members
    @calls = ();
    $org_mw_ran = 0;
    ($send, $sent) = mock_send();
    $app->({ method => 'GET', path => '/orgs/acme/teams/eng/members' }, sub { Future->done }, $send)->get;
    is $sent->[0]{status}, 200, 'nested group route matches';
    is $calls[0]{scope}{path_params}{org_id}, 'acme', 'outer param captured in nested';
    is $calls[0]{scope}{path_params}{team_id}, 'eng', 'inner param captured';
    is $org_mw_ran, 1, 'outer middleware ran for nested route';
    is $team_mw_ran, 1, 'inner middleware ran for nested route';
};
```

**Step 2: Run tests**

Run: `bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.40.0@default && prove -l t/app-router-group.t'`
Expected: All pass (stack already handles middleware and nesting)

**Step 3: Commit**

```bash
git add t/app-router-group.t
git commit -m "test: add group middleware and nesting tests"
```

---

### Task 6: Named Routes in Groups and Conflict Detection

**Files:**
- Modify: `lib/PAGI/App/Router.pm:253-268` (`name()` method)
- Modify: `t/app-router-group.t`

**Step 1: Write failing tests**

Add to `t/app-router-group.t` before `done_testing;`:

```perl
subtest 'named routes in groups' => sub {
    my $router = PAGI::App::Router->new;

    $router->group('/api/v1' => sub {
        my ($r) = @_;
        $r->get('/users' => sub {})->name('users.list');
        $r->get('/users/:id' => sub {})->name('users.get');
    });

    # Named routes get full prefixed path
    is $router->uri_for('users.list'), '/api/v1/users', 'grouped named route has prefix';
    is $router->uri_for('users.get', { id => 42 }), '/api/v1/users/42', 'grouped named route with param';
};

subtest 'named route conflict detection' => sub {
    my $router = PAGI::App::Router->new;

    $router->get('/a' => sub {})->name('dup');

    like dies {
        $router->get('/b' => sub {})->name('dup');
    }, qr/already exists/, 'croak on duplicate named route';
};
```

**Step 2: Run tests to verify they fail**

Run: `bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.40.0@default && prove -l t/app-router-group.t'`
Expected: The named routes test may pass (stack already applies prefix to path before `name()` stores it). The conflict test fails (no conflict detection yet).

**Step 3: Add conflict detection to `name()`**

In `name()` method, add a check before storing:

```perl
sub name {
    my ($self, $name) = @_;

    croak "name() called without a preceding route" unless $self->{_last_route};
    croak "Route name required" unless defined $name && length $name;
    croak "Named route '$name' already exists" if exists $self->{_named_routes}{$name};

    my $route = $self->{_last_route};
    $route->{name} = $name;
    $self->{_named_routes}{$name} = {
        path   => $route->{path},
        names  => $route->{names},
        prefix => '',
    };

    return $self;
}
```

**Step 4: Run all tests**

Run: `bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.40.0@default && prove -l t/app-router-group.t t/app-router.t t/router-named-routes.t'`
Expected: All pass

**Step 5: Commit**

```bash
git add lib/PAGI/App/Router.pm t/app-router-group.t
git commit -m "feat: named routes in groups with conflict detection"
```

---

### Task 7: `as()` Support for Groups

**Files:**
- Modify: `lib/PAGI/App/Router.pm` (`group()` and `as()` methods)
- Modify: `t/app-router-group.t`

**Step 1: Write failing test**

Add to `t/app-router-group.t` before `done_testing;`:

```perl
subtest 'as() namespacing for groups' => sub {
    my $router = PAGI::App::Router->new;

    $router->group('/api/v1' => sub {
        my ($r) = @_;
        $r->get('/users' => sub {})->name('users.list');
        $r->get('/users/:id' => sub {})->name('users.get');
    })->as('v1');

    # Named routes should be namespaced
    is $router->uri_for('v1.users.list'), '/api/v1/users', 'as() namespaces group named routes';
    is $router->uri_for('v1.users.get', { id => 5 }), '/api/v1/users/5', 'as() with params';

    # Original names should not exist
    ok !exists($router->named_routes->{'users.list'}), 'original name removed';
};
```

**Step 2: Run test to verify it fails**

Run: `bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.40.0@default && prove -l t/app-router-group.t'`
Expected: FAIL — `as()` doesn't handle groups yet

**Step 3: Implement `as()` for groups**

In `group()`, add named route tracking. Snapshot `_named_routes` keys before the callback, diff after:

```perl
sub group {
    my ($self, $prefix, @rest) = @_;
    $prefix =~ s{/$}{};

    my ($middleware, $target) = $self->_parse_route_args(@rest);

    # Snapshot named routes for as() support
    my %names_before = map { $_ => 1 } keys %{$self->{_named_routes}};

    if (ref($target) eq 'CODE') {
        push @{$self->{_group_stack}}, {
            prefix     => $prefix,
            middleware => [@$middleware],
        };
        $target->($self);
        pop @{$self->{_group_stack}};
    }
    else {
        croak "group() target must be a coderef, PAGI::App::Router, or package name, got "
            . (ref($target) || 'scalar');
    }

    # Track names added during this group (for as() chaining)
    my @new_names = grep { !$names_before{$_} } keys %{$self->{_named_routes}};
    $self->{_last_group_names} = \@new_names if @new_names;

    $self->{_last_route} = undef;
    $self->{_last_mount} = undef;

    return $self;
}
```

Update `as()` to handle groups:

```perl
sub as {
    my ($self, $namespace) = @_;

    croak "Namespace required" unless defined $namespace && length $namespace;

    # Handle group namespacing
    if ($self->{_last_group_names} && @{$self->{_last_group_names}}) {
        for my $name (@{$self->{_last_group_names}}) {
            my $info = delete $self->{_named_routes}{$name};
            my $full_name = "$namespace.$name";
            croak "Named route '$full_name' already exists"
                if exists $self->{_named_routes}{$full_name};
            $self->{_named_routes}{$full_name} = $info;
        }
        $self->{_last_group_names} = undef;
        return $self;
    }

    # Handle mount namespacing (existing behavior)
    croak "as() called without a preceding mount or group"
        unless $self->{_last_mount};

    my $mount = $self->{_last_mount};
    my $sub_router = $mount->{sub_router};

    croak "as() requires mounting a router object, not an app coderef"
        unless $sub_router;

    my $prefix = $mount->{prefix};
    for my $name (keys %{$sub_router->{_named_routes}}) {
        my $info = $sub_router->{_named_routes}{$name};
        my $full_name = "$namespace.$name";
        $self->{_named_routes}{$full_name} = {
            path   => $info->{path},
            names  => $info->{names},
            prefix => $prefix . ($info->{prefix} // ''),
        };
    }

    return $self;
}
```

**Step 4: Run all tests**

Run: `bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.40.0@default && prove -l t/app-router-group.t t/app-router.t t/router-named-routes.t'`
Expected: All pass

**Step 5: Commit**

```bash
git add lib/PAGI/App/Router.pm t/app-router-group.t
git commit -m "feat: add as() namespacing support for groups"
```

---

### Task 8: Router-Object Form

**Files:**
- Modify: `lib/PAGI/App/Router.pm` (`group()` method)
- Modify: `t/app-router-group.t`

**Step 1: Write failing tests for router-object form**

Add to `t/app-router-group.t` before `done_testing;`:

```perl
subtest 'router-object form: basic' => sub {
    my @calls;
    my $api = PAGI::App::Router->new;
    $api->get('/users' => make_handler('list_users', \@calls));
    $api->get('/users/:id' => make_handler('get_user', \@calls));

    my $router = PAGI::App::Router->new;
    $router->group('/api' => $api);

    my $app = $router->to_app;

    my ($send, $sent) = mock_send();
    $app->({ method => 'GET', path => '/api/users' }, sub { Future->done }, $send)->get;
    is $sent->[0]{status}, 200, 'router-object group matches';
    is $sent->[1]{body}, 'list_users', 'correct handler';

    @calls = ();
    ($send, $sent) = mock_send();
    $app->({ method => 'GET', path => '/api/users/7' }, sub { Future->done }, $send)->get;
    is $sent->[0]{status}, 200, 'router-object group with param';
    is $calls[0]{scope}{path_params}{id}, '7', 'param captured';
};

subtest 'router-object form: with middleware' => sub {
    my $mw_ran = 0;
    my $mw = async sub {
        my ($scope, $receive, $send, $next) = @_;
        $mw_ran++;
        await $next->();
    };

    my $api = PAGI::App::Router->new;
    $api->get('/data' => make_handler('data'));

    my $router = PAGI::App::Router->new;
    $router->group('/api' => [$mw] => $api);

    my $app = $router->to_app;
    my ($send, $sent) = mock_send();
    $app->({ method => 'GET', path => '/api/data' }, sub { Future->done }, $send)->get;
    is $sent->[0]{status}, 200, 'router-object with middleware matches';
    is $mw_ran, 1, 'group middleware ran';
};

subtest 'router-object form: snapshot semantics' => sub {
    my $api = PAGI::App::Router->new;
    $api->get('/early' => make_handler('early'));

    my $router = PAGI::App::Router->new;
    $router->group('/api' => $api);

    # Add route to source AFTER group() — should NOT appear in router
    $api->get('/late' => make_handler('late'));

    my $app = $router->to_app;

    my ($send, $sent) = mock_send();
    $app->({ method => 'GET', path => '/api/early' }, sub { Future->done }, $send)->get;
    is $sent->[0]{status}, 200, 'route from before group() works';

    ($send, $sent) = mock_send();
    $app->({ method => 'GET', path => '/api/late' }, sub { Future->done }, $send)->get;
    is $sent->[0]{status}, 404, 'route added after group() is NOT included';
};

subtest 'router-object form: named routes' => sub {
    my $api = PAGI::App::Router->new;
    $api->get('/users' => sub {})->name('users.list');
    $api->get('/users/:id' => sub {})->name('users.get');

    my $router = PAGI::App::Router->new;
    $router->group('/api' => $api);

    is $router->uri_for('users.list'), '/api/users', 'named route from included router';
    is $router->uri_for('users.get', { id => 3 }), '/api/users/3', 'named route with param';
};

subtest 'router-object form: chained constraints preserved' => sub {
    my @calls;
    my $api = PAGI::App::Router->new;
    $api->get('/users/:id' => make_handler('user', \@calls))
        ->constraints(id => qr/^\d+$/);

    my $router = PAGI::App::Router->new;
    $router->group('/api' => $api);

    my $app = $router->to_app;

    # Numeric id matches
    my ($send, $sent) = mock_send();
    $app->({ method => 'GET', path => '/api/users/42' }, sub { Future->done }, $send)->get;
    is $sent->[0]{status}, 200, 'chained constraint preserved — match';

    # Non-numeric id rejected
    ($send, $sent) = mock_send();
    $app->({ method => 'GET', path => '/api/users/abc' }, sub { Future->done }, $send)->get;
    is $sent->[0]{status}, 404, 'chained constraint preserved — reject';
};
```

**Step 2: Run tests to verify they fail**

Run: `bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.40.0@default && prove -l t/app-router-group.t'`
Expected: FAIL — group() doesn't handle Router objects yet

**Step 3: Implement router-object form in `group()`**

Update the `group()` method to handle `PAGI::App::Router` objects:

```perl
sub group {
    my ($self, $prefix, @rest) = @_;
    $prefix =~ s{/$}{};

    my ($middleware, $target) = $self->_parse_route_args(@rest);

    # Snapshot named routes for as() support
    my %names_before = map { $_ => 1 } keys %{$self->{_named_routes}};

    if (ref($target) eq 'CODE') {
        push @{$self->{_group_stack}}, {
            prefix     => $prefix,
            middleware => [@$middleware],
        };
        $target->($self);
        pop @{$self->{_group_stack}};
    }
    elsif (blessed($target) && $target->isa('PAGI::App::Router')) {
        push @{$self->{_group_stack}}, {
            prefix     => $prefix,
            middleware => [@$middleware],
        };
        $self->_include_router($target);
        pop @{$self->{_group_stack}};
    }
    else {
        croak "group() target must be a coderef, PAGI::App::Router, or package name, got "
            . (ref($target) || 'scalar');
    }

    # Track names added during this group (for as() chaining)
    my @new_names = grep { !$names_before{$_} } keys %{$self->{_named_routes}};
    $self->{_last_group_names} = \@new_names if @new_names;

    $self->{_last_route} = undef;
    $self->{_last_mount} = undef;

    return $self;
}

sub _include_router {
    my ($self, $source) = @_;

    # Re-register HTTP routes through route() (stack applies prefix/middleware)
    for my $route (@{$source->{routes}}) {
        $self->route(
            $route->{method},
            $route->{path},
            [@{$route->{middleware}}],
            $route->{app},
        );
        if ($route->{name}) {
            $self->name($route->{name});
        }
        if ($route->{_user_constraints} && @{$route->{_user_constraints}}) {
            my %uc = map { $_->[0] => $_->[1] } @{$route->{_user_constraints}};
            $self->constraints(%uc);
        }
    }

    # Re-register WebSocket routes
    for my $route (@{$source->{websocket_routes}}) {
        $self->websocket(
            $route->{path},
            [@{$route->{middleware}}],
            $route->{app},
        );
        if ($route->{name}) {
            $self->name($route->{name});
        }
        if ($route->{_user_constraints} && @{$route->{_user_constraints}}) {
            my %uc = map { $_->[0] => $_->[1] } @{$route->{_user_constraints}};
            $self->constraints(%uc);
        }
    }

    # Re-register SSE routes
    for my $route (@{$source->{sse_routes}}) {
        $self->sse(
            $route->{path},
            [@{$route->{middleware}}],
            $route->{app},
        );
        if ($route->{name}) {
            $self->name($route->{name});
        }
        if ($route->{_user_constraints} && @{$route->{_user_constraints}}) {
            my %uc = map { $_->[0] => $_->[1] } @{$route->{_user_constraints}};
            $self->constraints(%uc);
        }
    }
}
```

**Step 4: Run all tests**

Run: `bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.40.0@default && prove -l t/app-router-group.t t/app-router.t t/router-named-routes.t'`
Expected: All pass

**Step 5: Commit**

```bash
git add lib/PAGI/App/Router.pm t/app-router-group.t
git commit -m "feat: add group() router-object form with route copying"
```

---

### Task 9: String Form

**Files:**
- Modify: `lib/PAGI/App/Router.pm` (`group()` method)
- Create: `t/lib/TestRoutes/Users.pm` (test route module)
- Modify: `t/app-router-group.t`

**Step 1: Create test route module**

Create `t/lib/TestRoutes/Users.pm`:

```perl
package TestRoutes::Users;

use strict;
use warnings;
use PAGI::App::Router;
use Future::AsyncAwait;

sub router {
    my $r = PAGI::App::Router->new;

    $r->get('/' => async sub {
        my ($scope, $receive, $send) = @_;
        await $send->({ type => 'http.response.start', status => 200, headers => [['content-type', 'text/plain']] });
        await $send->({ type => 'http.response.body', body => 'users_list', more => 0 });
    })->name('users.list');

    $r->get('/:id' => async sub {
        my ($scope, $receive, $send) = @_;
        await $send->({ type => 'http.response.start', status => 200, headers => [['content-type', 'text/plain']] });
        await $send->({ type => 'http.response.body', body => 'user_detail', more => 0 });
    })->name('users.get');

    return $r;
}

1;
```

**Step 2: Write failing tests**

Add to `t/app-router-group.t`, update the `use lib` and add tests before `done_testing;`:

At the top of the file, after `use PAGI::App::Router;`, add:

```perl
use FindBin;
use lib "$FindBin::Bin/lib";
```

Then add the test:

```perl
subtest 'string form: auto-require' => sub {
    my $router = PAGI::App::Router->new;
    $router->group('/api/users' => 'TestRoutes::Users');

    my $app = $router->to_app;

    my ($send, $sent) = mock_send();
    $app->({ method => 'GET', path => '/api/users/' }, sub { Future->done }, $send)->get;
    is $sent->[0]{status}, 200, 'string form loads and registers routes';
    is $sent->[1]{body}, 'users_list', 'correct handler';

    # Named routes transferred
    is $router->uri_for('users.list'), '/api/users/', 'named route from string form';
    is $router->uri_for('users.get', { id => 7 }), '/api/users/7', 'named route with param';
};

subtest 'string form: bad package' => sub {
    my $router = PAGI::App::Router->new;

    like dies {
        $router->group('/api' => 'No::Such::Package::At::All');
    }, qr/Failed to load/, 'croak on failed require';
};
```

**Step 3: Run tests to verify they fail**

Run: `bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.40.0@default && prove -l t/app-router-group.t'`
Expected: FAIL — group() doesn't handle strings yet

**Step 4: Implement string form in `group()`**

Update the `else` branch in `group()`:

```perl
    elsif (!ref($target)) {
        # String form: auto-require and call ->router
        my $pkg = $target;
        {
            local $@;
            eval "require $pkg; 1" or croak "Failed to load '$pkg': $@";
        }
        croak "'$pkg' does not have a router() method" unless $pkg->can('router');
        my $router_obj = $pkg->router;
        croak "'${pkg}->router()' must return a PAGI::App::Router, got "
            . (ref($router_obj) || 'scalar')
            unless blessed($router_obj) && $router_obj->isa('PAGI::App::Router');

        push @{$self->{_group_stack}}, {
            prefix     => $prefix,
            middleware => [@$middleware],
        };
        $self->_include_router($router_obj);
        pop @{$self->{_group_stack}};
    }
```

**Step 5: Run all tests**

Run: `bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.40.0@default && prove -l t/app-router-group.t t/app-router.t t/router-named-routes.t'`
Expected: All pass

**Step 6: Commit**

```bash
git add lib/PAGI/App/Router.pm t/app-router-group.t t/lib/TestRoutes/Users.pm
git commit -m "feat: add group() string form with auto-require"
```

---

### Task 10: WebSocket and SSE in Groups

**Files:**
- Modify: `t/app-router-group.t`

**Step 1: Write tests**

Add to `t/app-router-group.t` before `done_testing;`:

```perl
subtest 'websocket and sse in groups' => sub {
    my @calls;
    my $router = PAGI::App::Router->new;

    $router->group('/realtime' => sub {
        my ($r) = @_;
        $r->websocket('/chat/:room' => make_handler('ws_chat', \@calls));
        $r->sse('/events/:channel' => make_handler('sse_events', \@calls));
    });

    my $app = $router->to_app;

    # WebSocket
    my ($send, $sent) = mock_send();
    $app->({ type => 'websocket', path => '/realtime/chat/general' }, sub { Future->done }, $send)->get;
    is $sent->[0]{status}, 200, 'websocket in group matches';
    is $calls[0]{scope}{path_params}{room}, 'general', 'ws param captured';

    # SSE
    @calls = ();
    ($send, $sent) = mock_send();
    $app->({ type => 'sse', path => '/realtime/events/news' }, sub { Future->done }, $send)->get;
    is $sent->[0]{status}, 200, 'sse in group matches';
    is $calls[0]{scope}{path_params}{channel}, 'news', 'sse param captured';

    # Without prefix — 404
    ($send, $sent) = mock_send();
    $app->({ type => 'websocket', path => '/chat/general' }, sub { Future->done }, $send)->get;
    is $sent->[0]{status}, 404, 'ws without group prefix is 404';
};
```

**Step 2: Run tests**

Run: `bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.40.0@default && prove -l t/app-router-group.t'`
Expected: All pass (stack already applies to websocket/sse)

**Step 3: Commit**

```bash
git add t/app-router-group.t
git commit -m "test: add websocket and sse in groups tests"
```

---

### Task 11: Group Error Handling

**Files:**
- Modify: `t/app-router-group.t`

**Step 1: Write error handling tests**

Add to `t/app-router-group.t` before `done_testing;`:

```perl
subtest 'group() error handling' => sub {
    my $router = PAGI::App::Router->new;

    # Invalid target type
    like dies {
        $router->group('/api' => { foo => 'bar' });
    }, qr/group\(\) target must be/, 'croak on invalid target type';

    # String form: package without router() method
    # Use a known module that doesn't have router()
    like dies {
        $router->group('/api' => 'Carp');
    }, qr/does not have a router\(\) method/, 'croak on package without router()';
};

subtest 'group clears _last_route' => sub {
    my $router = PAGI::App::Router->new;

    $router->get('/before' => sub {})->name('before');

    $router->group('/api' => sub {
        my ($r) = @_;
        $r->get('/inside' => sub {});
    });

    # name() after group() should croak — _last_route was cleared
    like dies {
        $router->name('bad');
    }, qr/name\(\) called without a preceding route/, 'group clears _last_route';
};
```

**Step 2: Run tests**

Run: `bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.40.0@default && prove -l t/app-router-group.t'`
Expected: All pass

**Step 3: Commit**

```bash
git add t/app-router-group.t
git commit -m "test: add group error handling tests"
```

---

### Task 12: Integration Tests

**Files:**
- Modify: `t/app-router-group.t`

**Step 1: Write integration tests combining group with other features**

Add to `t/app-router-group.t` before `done_testing;`:

```perl
subtest 'group with constraints and any()' => sub {
    my @calls;
    my $router = PAGI::App::Router->new;

    $router->group('/api' => sub {
        my ($r) = @_;
        $r->get('/users/{id:\d+}' => make_handler('user', \@calls));
        $r->any('/health' => make_handler('health', \@calls));
        $r->any('/items/:id' => make_handler('item', \@calls), method => ['GET', 'PUT'])
            ->constraints(id => qr/^\d+$/);
    });

    my $app = $router->to_app;

    # Inline constraint in group
    my ($send, $sent) = mock_send();
    $app->({ method => 'GET', path => '/api/users/42' }, sub { Future->done }, $send)->get;
    is $sent->[0]{status}, 200, 'inline constraint in group works';

    ($send, $sent) = mock_send();
    $app->({ method => 'GET', path => '/api/users/abc' }, sub { Future->done }, $send)->get;
    is $sent->[0]{status}, 404, 'inline constraint in group rejects';

    # any() in group
    ($send, $sent) = mock_send();
    $app->({ method => 'DELETE', path => '/api/health' }, sub { Future->done }, $send)->get;
    is $sent->[0]{status}, 200, 'any() in group matches DELETE';

    # any() with method list + chained constraint in group
    ($send, $sent) = mock_send();
    $app->({ method => 'PUT', path => '/api/items/5' }, sub { Future->done }, $send)->get;
    is $sent->[0]{status}, 200, 'any() + constraint in group — match';

    ($send, $sent) = mock_send();
    $app->({ method => 'DELETE', path => '/api/items/5' }, sub { Future->done }, $send)->get;
    is $sent->[0]{status}, 405, 'any() method restriction in group — 405';

    ($send, $sent) = mock_send();
    $app->({ method => 'GET', path => '/api/items/abc' }, sub { Future->done }, $send)->get;
    is $sent->[0]{status}, 404, 'chained constraint in group — reject';
};

subtest 'group with 405 across grouped and ungrouped' => sub {
    my $router = PAGI::App::Router->new;

    $router->get('/shared' => make_handler('get_shared'));
    $router->group('/api' => sub {
        my ($r) = @_;
        $r->post('/shared' => make_handler('post_shared'));
    });

    # Note: /shared and /api/shared are different paths
    # This tests that grouped routes participate in 405 correctly
    my $app = $router->to_app;

    my ($send, $sent) = mock_send();
    $app->({ method => 'DELETE', path => '/shared' }, sub { Future->done }, $send)->get;
    is $sent->[0]{status}, 405, '405 for ungrouped route';

    ($send, $sent) = mock_send();
    $app->({ method => 'DELETE', path => '/api/shared' }, sub { Future->done }, $send)->get;
    is $sent->[0]{status}, 405, '405 for grouped route';
};

subtest 'group with regex metacharacters in prefix' => sub {
    my @calls;
    my $router = PAGI::App::Router->new;

    $router->group('/api/v1.0' => sub {
        my ($r) = @_;
        $r->get('/users' => make_handler('users', \@calls));
    });

    my $app = $router->to_app;

    my ($send, $sent) = mock_send();
    $app->({ method => 'GET', path => '/api/v1.0/users' }, sub { Future->done }, $send)->get;
    is $sent->[0]{status}, 200, 'group prefix with dot matches literally';

    ($send, $sent) = mock_send();
    $app->({ method => 'GET', path => '/api/v1X0/users' }, sub { Future->done }, $send)->get;
    is $sent->[0]{status}, 404, 'dot in group prefix is not wildcard';
};
```

**Step 2: Run tests**

Run: `bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.40.0@default && prove -l t/app-router-group.t'`
Expected: All pass

**Step 3: Run full test suite**

Run: `bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.40.0@default && prove -l t/'`
Expected: All pass

**Step 4: Commit**

```bash
git add t/app-router-group.t
git commit -m "test: add group integration tests with constraints and any()"
```

---

### Task 13: POD Documentation

**Files:**
- Modify: `lib/PAGI/App/Router.pm` (POD sections)

**Step 1: Update SYNOPSIS**

Add group examples to the SYNOPSIS (after the constraints examples, before `my $app = $router->to_app;`):

```pod
    # Route grouping (flattened into parent)
    $router->group('/api' => [$auth_mw] => sub {
        my ($r) = @_;
        $r->get('/users' => $list_users);
        $r->post('/users' => $create_user);
    });

    # Include routes from another router
    $router->group('/api/v2' => $v2_router);

    # Include routes from a package
    $router->group('/api/users' => 'MyApp::Routes::Users');
```

**Step 2: Add `group` method documentation**

Add after the `any` method documentation in the METHODS section:

```pod
=head2 group

    # Callback form
    $router->group('/prefix' => sub { my ($r) = @_; ... });
    $router->group('/prefix' => \@middleware => sub { my ($r) = @_; ... });

    # Router-object form
    $router->group('/prefix' => $other_router);
    $router->group('/prefix' => \@middleware => $other_router);

    # String form (auto-require)
    $router->group('/prefix' => 'MyApp::Routes::Users');
    $router->group('/prefix' => \@middleware => 'MyApp::Routes::Users');

Flatten routes under a shared prefix with optional shared middleware. Unlike
C<mount()>, grouped routes are registered directly on the parent router —
there is no separate dispatch context, 405 handling is unified, and named
routes are directly accessible.

B<Callback form:> The coderef receives the router itself. All route
registrations inside the callback are prefixed automatically.

B<Router-object form:> Routes are copied from the source router at call
time (snapshot semantics). Later modifications to the source do not affect
the parent.

B<String form:> The package is loaded via C<require>, then
C<< $package->router >> is called. The result must be a
C<PAGI::App::Router> instance.

Group middleware is prepended to each route's middleware chain:

    $router->group('/api' => [$auth] => sub {
        my ($r) = @_;
        $r->get('/data' => [$rate_limit] => $handler);
        # Middleware chain: $auth -> $rate_limit -> $handler
    });

Groups can be nested:

    $router->group('/orgs/:org_id' => [$load_org] => sub {
        my ($r) = @_;
        $r->group('/teams/:team_id' => [$load_team] => sub {
            my ($r) = @_;
            $r->get('/members' => $handler);
            # Path: /orgs/:org_id/teams/:team_id/members
            # Middleware: $load_org -> $load_team -> $handler
        });
    });

Returns C<$self> for chaining (supports C<as()> for named route namespacing).

=head3 group vs mount

    # group: routes flattened into parent
    $router->group('/api' => $api_router);

    # mount: separate dispatch context
    $router->mount('/api' => $api_router->to_app);

Use C<group()> to organize routes within one application. Use C<mount()>
to compose independent applications.

=cut
```

**Step 3: Update `as()` documentation to mention groups**

Update the existing `as()` POD:

```pod
=head2 as

    $router->mount('/api' => $sub_router)->as('api');
    $router->group('/api' => $api_router)->as('api');

Assign a namespace to named routes from a mounted router or group.

    $router->group('/api/v1' => sub {
        my ($r) = @_;
        $r->get('/users' => $h)->name('users.list');
    })->as('v1');

    $router->uri_for('v1.users.list');
    # Returns: "/api/v1/users"
```

**Step 4: Run tests to make sure nothing broke**

Run: `bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.40.0@default && prove -l t/app-router.t t/router-named-routes.t t/app-router-group.t'`
Expected: All pass

**Step 5: Commit**

```bash
git add lib/PAGI/App/Router.pm
git commit -m "docs: add group() POD documentation"
```

---

### Task 14: Final Code Review

**Step 1: Run full test suite**

Run: `bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.40.0@default && prove -l t/'`
Expected: All pass

**Step 2: Review implementation against design doc**

Read `docs/plans/2026-02-17-group-feature-design.md` and verify:
- [ ] Callback form works with prefix, middleware, nesting
- [ ] Router-object form copies routes with snapshot semantics
- [ ] String form auto-requires and calls `->router`
- [ ] Chained constraints preserved via separate storage
- [ ] Named route conflict detection (croak on duplicate)
- [ ] `as()` namespacing for groups
- [ ] WebSocket and SSE routes in groups
- [ ] Group prefix with regex metacharacters escaped correctly
- [ ] `_last_route` cleared after group()
- [ ] Error messages for invalid targets

**Step 3: Dispatch code reviewer subagent**
