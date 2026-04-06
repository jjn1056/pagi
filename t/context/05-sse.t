#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use Future;

use PAGI::Context;

subtest 'SSE context has correct methods' => sub {
    my $ctx = PAGI::Context->new(
        { type => 'sse', path => '/events', headers => [] },
        sub {}, sub {},
    );

    ok($ctx->can('sse'), 'has sse');
    ok(!$ctx->can('request'), 'no request method');
    ok(!$ctx->can('response'), 'no response method');
    ok(!$ctx->can('method'), 'no method method');
    ok(!$ctx->can('websocket'), 'no websocket method');
};

subtest 'sse accessor' => sub {
    my @sent;
    my $send = sub { push @sent, $_[0]; Future->done };
    my $receive = sub { Future->done({ type => 'sse.disconnect' }) };

    my $scope = {
        type    => 'sse',
        path    => '/events/news',
        headers => [['accept', 'text/event-stream']],
    };

    my $ctx = PAGI::Context->new($scope, $receive, $send);
    my $sse = $ctx->sse;

    isa_ok($sse, 'PAGI::SSE');
    is($sse->path, '/events/news', 'sse path works');

    # Cached
    my $sse2 = $ctx->sse;
    ok($sse == $sse2, 'sse is cached');
};

subtest 'shared methods work on SSE context' => sub {
    my $scope = {
        type    => 'sse',
        path    => '/events',
        headers => [['last-event-id', '42']],
    };

    my $ctx = PAGI::Context->new($scope, sub {}, sub {});

    is($ctx->type, 'sse', 'type accessor');
    is($ctx->path, '/events', 'path accessor');
    is($ctx->header('last-event-id'), '42', 'header lookup');
    ok($ctx->is_sse, 'is_sse true');
    ok(!$ctx->is_http, 'is_http false');
    ok(!$ctx->is_websocket, 'is_websocket false');

    $ctx->stash->set(channel => 'news');
    is($ctx->stash->get('channel'), 'news', 'stash works');
};

subtest 'SSE send event round-trip' => sub {
    my @sent;
    my $send = sub { push @sent, $_[0]; Future->done };
    my $receive = sub { Future->done({ type => 'sse.disconnect' }) };

    my $scope = {
        type    => 'sse',
        path    => '/events',
        headers => [],
    };

    my $ctx = PAGI::Context->new($scope, $receive, $send);

    (async sub {
        await $ctx->sse->send_event(event => 'ping', data => { ts => 1 });
    })->()->get;

    ok(scalar @sent > 0, 'SSE sent events');
};

done_testing;
