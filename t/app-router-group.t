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
