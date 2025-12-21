#!/usr/bin/env perl

use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use IO::Async::Loop;

use lib 'lib';

use PAGI::App::Router;

my $loop = IO::Async::Loop->new;

sub run_async {
    my ($code) = @_;
    my $future = $code->();
    $loop->await($future);
}

# =============================================================================
# Test: PAGI::App::Router
# =============================================================================

subtest 'Basic routing' => sub {

    subtest 'matches exact path' => sub {
        my $router = PAGI::App::Router->new;
        $router->get('/users' => async sub  {
        my ($scope, $receive, $send) = @_;
            await $send->({ type => 'http.response.start', status => 200, headers => [] });
            await $send->({ type => 'http.response.body', body => 'Users list', more => 0 });
        });
        my $app = $router->to_app;

        my @sent;
        run_async(async sub {
            await $app->(
                { type => 'http', method => 'GET', path => '/users' },
                async sub { { type => 'http.disconnect' } },
                async sub  {
        my ($event) = @_; push @sent, $event },
            );
        });

        is $sent[0]{status}, 200, 'matches exact path';
        is $sent[1]{body}, 'Users list', 'correct response';
    };

    subtest 'returns 404 for non-matching path' => sub {
        my $router = PAGI::App::Router->new;
        $router->get('/users' => async sub  {
        my ($scope, $receive, $send) = @_;
            await $send->({ type => 'http.response.start', status => 200, headers => [] });
            await $send->({ type => 'http.response.body', body => 'Users', more => 0 });
        });
        my $app = $router->to_app;

        my @sent;
        run_async(async sub {
            await $app->(
                { type => 'http', method => 'GET', path => '/posts' },
                async sub { { type => 'http.disconnect' } },
                async sub  {
        my ($event) = @_; push @sent, $event },
            );
        });

        is $sent[0]{status}, 404, 'returns 404';
    };

    subtest 'returns 405 for wrong method' => sub {
        my $router = PAGI::App::Router->new;
        $router->get('/users' => async sub  {
        my ($scope, $receive, $send) = @_;
            await $send->({ type => 'http.response.start', status => 200, headers => [] });
            await $send->({ type => 'http.response.body', body => 'Users', more => 0 });
        });
        my $app = $router->to_app;

        my @sent;
        run_async(async sub {
            await $app->(
                { type => 'http', method => 'POST', path => '/users' },
                async sub { { type => 'http.disconnect' } },
                async sub  {
        my ($event) = @_; push @sent, $event },
            );
        });

        is $sent[0]{status}, 405, 'returns 405';
        ok((grep { $_->[0] eq 'allow' } @{$sent[0]{headers}}), 'Allow header present');
    };
};

subtest 'Path parameters' => sub {

    subtest 'captures named parameter' => sub {
        my $captured_params;
        my $router = PAGI::App::Router->new;
        $router->get('/users/:id' => async sub  {
        my ($scope, $receive, $send) = @_;
            $captured_params = $scope->{'pagi.router'}{params};
            await $send->({ type => 'http.response.start', status => 200, headers => [] });
            await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
        });
        my $app = $router->to_app;

        run_async(async sub {
            await $app->(
                { type => 'http', method => 'GET', path => '/users/123' },
                async sub { { type => 'http.disconnect' } },
                async sub  {
        my ($event) = @_; },
            );
        });

        is $captured_params->{id}, '123', 'captured id parameter';
    };

    subtest 'captures multiple parameters' => sub {
        my $captured_params;
        my $router = PAGI::App::Router->new;
        $router->get('/users/:user_id/posts/:post_id' => async sub  {
        my ($scope, $receive, $send) = @_;
            $captured_params = $scope->{'pagi.router'}{params};
            await $send->({ type => 'http.response.start', status => 200, headers => [] });
            await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
        });
        my $app = $router->to_app;

        run_async(async sub {
            await $app->(
                { type => 'http', method => 'GET', path => '/users/42/posts/99' },
                async sub { { type => 'http.disconnect' } },
                async sub  {
        my ($event) = @_; },
            );
        });

        is $captured_params->{user_id}, '42', 'captured user_id';
        is $captured_params->{post_id}, '99', 'captured post_id';
    };

    subtest 'captures wildcard' => sub {
        my $captured_params;
        my $router = PAGI::App::Router->new;
        $router->get('/files/*filepath' => async sub  {
        my ($scope, $receive, $send) = @_;
            $captured_params = $scope->{'pagi.router'}{params};
            await $send->({ type => 'http.response.start', status => 200, headers => [] });
            await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
        });
        my $app = $router->to_app;

        run_async(async sub {
            await $app->(
                { type => 'http', method => 'GET', path => '/files/path/to/file.txt' },
                async sub { { type => 'http.disconnect' } },
                async sub  {
        my ($event) = @_; },
            );
        });

        is $captured_params->{filepath}, 'path/to/file.txt', 'captured filepath wildcard';
    };
};

subtest 'HTTP methods' => sub {

    subtest 'POST route' => sub {
        my $router = PAGI::App::Router->new;
        $router->post('/users' => async sub  {
        my ($scope, $receive, $send) = @_;
            await $send->({ type => 'http.response.start', status => 201, headers => [] });
            await $send->({ type => 'http.response.body', body => 'Created', more => 0 });
        });
        my $app = $router->to_app;

        my @sent;
        run_async(async sub {
            await $app->(
                { type => 'http', method => 'POST', path => '/users' },
                async sub { { type => 'http.disconnect' } },
                async sub  {
        my ($event) = @_; push @sent, $event },
            );
        });

        is $sent[0]{status}, 201, 'POST route matched';
    };

    subtest 'DELETE route' => sub {
        my $router = PAGI::App::Router->new;
        $router->delete('/users/:id' => async sub  {
        my ($scope, $receive, $send) = @_;
            await $send->({ type => 'http.response.start', status => 204, headers => [] });
            await $send->({ type => 'http.response.body', body => '', more => 0 });
        });
        my $app = $router->to_app;

        my @sent;
        run_async(async sub {
            await $app->(
                { type => 'http', method => 'DELETE', path => '/users/123' },
                async sub { { type => 'http.disconnect' } },
                async sub  {
        my ($event) = @_; push @sent, $event },
            );
        });

        is $sent[0]{status}, 204, 'DELETE route matched';
    };

    subtest 'HEAD matches GET route' => sub {
        my $router = PAGI::App::Router->new;
        $router->get('/users' => async sub  {
        my ($scope, $receive, $send) = @_;
            await $send->({ type => 'http.response.start', status => 200, headers => [] });
            await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
        });
        my $app = $router->to_app;

        my @sent;
        run_async(async sub {
            await $app->(
                { type => 'http', method => 'HEAD', path => '/users' },
                async sub { { type => 'http.disconnect' } },
                async sub  {
        my ($event) = @_; push @sent, $event },
            );
        });

        is $sent[0]{status}, 200, 'HEAD matches GET route';
    };
};

subtest 'Route info in scope' => sub {
    my $captured_route;
    my $router = PAGI::App::Router->new;
    $router->get('/users/:id' => async sub  {
        my ($scope, $receive, $send) = @_;
        $captured_route = $scope->{'pagi.router'}{route};
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
    });
    my $app = $router->to_app;

    run_async(async sub {
        await $app->(
            { type => 'http', method => 'GET', path => '/users/123' },
            async sub { { type => 'http.disconnect' } },
            async sub  {
        my ($event) = @_; },
        );
    });

    is $captured_route, '/users/:id', 'route pattern in scope';
};

done_testing;
