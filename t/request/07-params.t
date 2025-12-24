#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;

use lib 'lib';
use PAGI::Request;

subtest 'params from scope' => sub {
    my $scope = {
        type    => 'http',
        method  => 'GET',
        path    => '/users/42/posts/100',
        headers => [],
        # Router sets path_params directly in scope (router-agnostic)
        path_params => { user_id => '42', post_id => '100' },
        'pagi.router' => {
            route  => '/users/:user_id/posts/:post_id',
        },
    };

    my $req = PAGI::Request->new($scope);

    is($req->path_params, { user_id => '42', post_id => '100' }, 'params returns hashref');
    is($req->path_param('user_id'), '42', 'param() gets single value');
    is($req->path_param('post_id'), '100', 'param() another value');
    is($req->path_param('missing'), undef, 'missing param is undef');
};

subtest 'params set via scope' => sub {
    # Simulating how router sets path_params in scope before handler is called
    my $scope = {
        type => 'http',
        method => 'GET',
        headers => [],
        path_params => { id => '123', slug => 'hello-world' },
    };
    my $req = PAGI::Request->new($scope);

    is($req->path_param('id'), '123', 'param from scope');
    is($req->path_param('slug'), 'hello-world', 'another param');
};

subtest 'no params' => sub {
    my $scope = { type => 'http', method => 'GET', headers => [] };
    my $req = PAGI::Request->new($scope);

    is($req->path_params, {}, 'empty params by default');
    is($req->path_param('anything'), undef, 'missing returns undef');
};

subtest 'path_param does not include query params' => sub {
    my $scope = {
        type => 'http',
        method => 'GET',
        headers => [],
        query_string => 'foo=bar&baz=qux',
        path_params => { id => '42' },
    };
    my $req = PAGI::Request->new($scope);

    # path_param only returns path params, not query params
    is($req->path_param('id'), '42', 'path param exists');
    is($req->path_param('foo'), undef, 'query param not returned by path_param');
    is($req->path_param('baz'), undef, 'query params accessed via query method');
    # Query params should be accessed via $req->query('foo')
    is($req->query('foo'), 'bar', 'query() returns query param');
};

done_testing;
