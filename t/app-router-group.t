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

done_testing;
