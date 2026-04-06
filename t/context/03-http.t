#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use Future;

use PAGI::Context;

subtest 'HTTP context has correct methods' => sub {
    my $ctx = PAGI::Context->new(
        { type => 'http', method => 'GET', path => '/test', headers => [] },
        sub {}, sub {},
    );

    ok($ctx->can('request'), 'has request');
    ok($ctx->can('response'), 'has response');
    ok($ctx->can('method'), 'has method');
    ok($ctx->can('req'), 'has req alias');
    ok($ctx->can('resp'), 'has resp alias');

    # Should NOT have protocol-specific methods from other subclasses
    ok(!$ctx->can('websocket'), 'no websocket method');
    ok(!$ctx->can('sse'), 'no sse method');
};

subtest 'method accessor' => sub {
    my $ctx = PAGI::Context->new(
        { type => 'http', method => 'POST', path => '/', headers => [] },
        sub {}, sub {},
    );

    is($ctx->method, 'POST', 'method returns HTTP method');
};

subtest 'request accessor' => sub {
    my $receive = sub { Future->done({ type => 'http.request', body => '' }) };
    my $scope = {
        type    => 'http',
        method  => 'GET',
        path    => '/hello',
        headers => [['host', 'example.com']],
    };

    my $ctx = PAGI::Context->new($scope, $receive, sub {});
    my $req = $ctx->request;

    isa_ok($req, 'PAGI::Request');
    is($req->method, 'GET', 'request method works');
    is($req->path, '/hello', 'request path works');
    is($req->header('host'), 'example.com', 'request headers work');

    # Cached
    my $req2 = $ctx->request;
    ok($req == $req2, 'request is cached');
};

subtest 'response accessor' => sub {
    my @sent;
    my $send = sub { push @sent, $_[0]; Future->done };
    my $scope = {
        type    => 'http',
        method  => 'GET',
        path    => '/',
        headers => [],
    };

    my $ctx = PAGI::Context->new($scope, sub {}, $send);
    my $res = $ctx->response;

    isa_ok($res, 'PAGI::Response');

    # Cached
    my $res2 = $ctx->response;
    ok($res == $res2, 'response is cached');
};

subtest 'request and response share scope' => sub {
    my $scope = {
        type    => 'http',
        method  => 'GET',
        path    => '/',
        headers => [],
    };

    my $ctx = PAGI::Context->new($scope, sub {}, sub { Future->done });

    # Stash set via context is visible through request's scope
    $ctx->stash->set(user => 'alice');

    my $req_stash = PAGI::Stash->new($ctx->request);
    is($req_stash->get('user'), 'alice', 'stash flows from context to request');
};

subtest 'req and resp aliases' => sub {
    my $scope = {
        type    => 'http',
        method  => 'GET',
        path    => '/test',
        headers => [],
    };
    my $ctx = PAGI::Context->new($scope, sub {}, sub { Future->done });

    ok($ctx->req == $ctx->request, 'req returns same object as request');
    ok($ctx->resp == $ctx->response, 'resp returns same object as response');
};

subtest 'full HTTP round-trip' => sub {
    my @sent;
    my $send = sub { push @sent, $_[0]; Future->done };
    my $receive = sub { Future->done({ type => 'http.request', body => '' }) };

    my $scope = {
        type    => 'http',
        method  => 'GET',
        path    => '/test',
        headers => [],
    };

    my $ctx = PAGI::Context->new($scope, $receive, $send);

    (async sub {
        await $ctx->response->text('Hello from context!');
    })->()->get;

    is($sent[0]{status}, 200, 'response status sent');
    is($sent[1]{body}, 'Hello from context!', 'response body sent');
};

done_testing;
