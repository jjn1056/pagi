#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use Future;

use PAGI::Context;

subtest 'WebSocket context has correct methods' => sub {
    my $ctx = PAGI::Context->new(
        { type => 'websocket', path => '/ws', headers => [] },
        sub {}, sub {},
    );

    ok($ctx->can('websocket'), 'has websocket');
    ok($ctx->can('ws'), 'has ws alias');
    ok(!$ctx->can('request'), 'no request method');
    ok(!$ctx->can('response'), 'no response method');
    ok(!$ctx->can('method'), 'no method method');
    ok(!$ctx->can('sse'), 'no sse method');
};

subtest 'websocket accessor' => sub {
    my @sent;
    my $send = sub { push @sent, $_[0]; Future->done };
    my $receive = sub { Future->done({ type => 'websocket.disconnect' }) };

    my $scope = {
        type    => 'websocket',
        path    => '/ws/chat',
        headers => [['sec-websocket-protocol', 'chat']],
    };

    my $ctx = PAGI::Context->new($scope, $receive, $send);
    my $ws = $ctx->websocket;

    isa_ok($ws, 'PAGI::WebSocket');
    is($ws->path, '/ws/chat', 'websocket path works');

    # Cached
    my $ws2 = $ctx->websocket;
    ok($ws == $ws2, 'websocket is cached');

    # Alias
    ok($ctx->ws == $ws, 'ws alias returns same object');
};

subtest 'shared methods work on WebSocket context' => sub {
    my $scope = {
        type    => 'websocket',
        path    => '/ws',
        headers => [['authorization', 'Bearer token123']],
    };

    my $ctx = PAGI::Context->new($scope, sub {}, sub {});

    is($ctx->type, 'websocket', 'type accessor');
    is($ctx->path, '/ws', 'path accessor');
    is($ctx->header('authorization'), 'Bearer token123', 'header lookup');
    ok($ctx->is_websocket, 'is_websocket true');
    ok(!$ctx->is_http, 'is_http false');

    $ctx->stash->set(room => 'general');
    is($ctx->stash->get('room'), 'general', 'stash works');
};

subtest 'WebSocket accept round-trip' => sub {
    my @sent;
    my $send = sub { push @sent, $_[0]; Future->done };
    my $receive = sub { Future->done({ type => 'websocket.disconnect' }) };

    my $scope = {
        type    => 'websocket',
        path    => '/ws',
        headers => [],
    };

    my $ctx = PAGI::Context->new($scope, $receive, $send);

    (async sub {
        await $ctx->websocket->accept;
    })->()->get;

    is($sent[0]{type}, 'websocket.accept', 'accept event sent');
};

done_testing;
