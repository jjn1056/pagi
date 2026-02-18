use strict;
use warnings;

use Test2::V0;
use Future::AsyncAwait;

use PAGI::App::Router;
use FindBin;
use lib "$FindBin::Bin/lib";

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

subtest 'as() with router-object form' => sub {
    my $api = PAGI::App::Router->new;
    $api->get('/users' => sub {})->name('users.list');
    $api->get('/users/:id' => sub {})->name('users.get');

    my $router = PAGI::App::Router->new;
    $router->group('/api' => $api)->as('api');

    is $router->uri_for('api.users.list'), '/api/users', 'as() with router-object form';
    is $router->uri_for('api.users.get', { id => 3 }), '/api/users/3', 'as() with router-object and params';
    ok !exists($router->named_routes->{'users.list'}), 'original name removed';
};

subtest 'as() not confused by preceding group without names' => sub {
    my $router = PAGI::App::Router->new;

    # First group adds named routes
    $router->group('/v1' => sub {
        my ($r) = @_;
        $r->get('/a' => sub {})->name('a');
    })->as('v1');

    # Second group adds NO named routes
    $router->group('/v2' => sub {
        my ($r) = @_;
        $r->get('/b' => sub {});
    });

    # as() after second group should croak (no group names to namespace)
    like dies {
        $router->as('v2');
    }, qr/as\(\) called without a preceding mount or group/, 'as() not confused by nameless group';

    # v1 names still intact
    is $router->uri_for('v1.a'), '/v1/a', 'earlier namespaced route unaffected';
};

done_testing;
