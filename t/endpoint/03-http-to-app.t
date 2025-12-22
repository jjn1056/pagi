#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use Future;

use lib 'lib';
use PAGI::Endpoint::HTTP;

package HelloEndpoint {
    use parent 'PAGI::Endpoint::HTTP';
    use v5.32;
    use feature 'signatures';
    no warnings 'experimental::signatures';
    use Future::AsyncAwait;

    async sub get ($self, $req, $res) {
        my $name = $req->query('name') // 'World';
        await $res->text("Hello, $name");
    }
}

subtest 'to_app returns PAGI-compatible coderef' => sub {
    my $app = HelloEndpoint->to_app;

    ref_ok($app, 'CODE', 'to_app returns coderef');
};

subtest 'app handles full request cycle' => sub {
    my $app = HelloEndpoint->to_app;

    my @sent;
    my $scope = {
        type => 'http',
        method => 'GET',
        path => '/hello',
        query_string => 'name=PAGI',
        headers => [],
    };
    my $receive = sub { Future->done({ type => 'http.request' }) };
    my $send = sub { push @sent, $_[0]; Future->done };

    $app->($scope, $receive, $send)->get;

    # Should have response.start and response.body
    ok(@sent >= 1, 'sent response events');
    is($sent[0]{type}, 'http.response.start', 'starts with response.start');
};

done_testing;
