#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;

use PAGI::Context;

subtest 'module loads and has expected methods' => sub {
    ok(PAGI::Context->can('new'), 'has new');
    ok(PAGI::Context->can('_type_map'), 'has _type_map');
    ok(PAGI::Context->can('_resolve_class'), 'has _resolve_class');
    ok(PAGI::Context->can('scope'), 'has scope');
    ok(PAGI::Context->can('type'), 'has type');
    ok(PAGI::Context->can('path'), 'has path');
};

subtest '_type_map returns expected mapping' => sub {
    my $map = PAGI::Context->_type_map;
    is(ref($map), 'HASH', 'returns hashref');
    is($map->{http}, 'PAGI::Context::HTTP', 'http maps to HTTP');
    is($map->{websocket}, 'PAGI::Context::WebSocket', 'websocket maps to WebSocket');
    is($map->{sse}, 'PAGI::Context::SSE', 'sse maps to SSE');
};

subtest '_resolve_class returns correct subclass' => sub {
    is(PAGI::Context->_resolve_class({ type => 'http' }),
        'PAGI::Context::HTTP', 'http type resolves');
    is(PAGI::Context->_resolve_class({ type => 'websocket' }),
        'PAGI::Context::WebSocket', 'websocket type resolves');
    is(PAGI::Context->_resolve_class({ type => 'sse' }),
        'PAGI::Context::SSE', 'sse type resolves');
    is(PAGI::Context->_resolve_class({}),
        'PAGI::Context::HTTP', 'missing type defaults to HTTP');
    is(PAGI::Context->_resolve_class({ type => 'unknown' }),
        'PAGI::Context::HTTP', 'unknown type defaults to HTTP');
};

subtest 'new returns correct subclass' => sub {
    my $receive = sub {};
    my $send = sub {};

    my $http_ctx = PAGI::Context->new(
        { type => 'http', method => 'GET', path => '/test', headers => [] },
        $receive, $send,
    );
    isa_ok($http_ctx, 'PAGI::Context');
    isa_ok($http_ctx, 'PAGI::Context::HTTP');

    my $ws_ctx = PAGI::Context->new(
        { type => 'websocket', path => '/ws', headers => [] },
        $receive, $send,
    );
    isa_ok($ws_ctx, 'PAGI::Context');
    isa_ok($ws_ctx, 'PAGI::Context::WebSocket');

    my $sse_ctx = PAGI::Context->new(
        { type => 'sse', path => '/events', headers => [] },
        $receive, $send,
    );
    isa_ok($sse_ctx, 'PAGI::Context');
    isa_ok($sse_ctx, 'PAGI::Context::SSE');
};

subtest 'scope accessors work' => sub {
    my $scope = {
        type         => 'http',
        method       => 'GET',
        path         => '/hello',
        raw_path     => '/hello%20world',
        query_string => 'a=1&b=2',
        scheme       => 'https',
        client       => ['127.0.0.1', 8080],
        server       => ['0.0.0.0', 443],
        headers      => [['host', 'example.com'], ['accept', 'text/html']],
    };

    my $ctx = PAGI::Context->new($scope, sub {}, sub {});

    is($ctx->scope, $scope, 'scope returns raw hashref');
    is($ctx->type, 'http', 'type accessor');
    is($ctx->path, '/hello', 'path accessor');
    is($ctx->raw_path, '/hello%20world', 'raw_path accessor');
    is($ctx->query_string, 'a=1&b=2', 'query_string accessor');
    is($ctx->scheme, 'https', 'scheme accessor');
    is($ctx->client, ['127.0.0.1', 8080], 'client accessor');
    is($ctx->server, ['0.0.0.0', 443], 'server accessor');
    is($ctx->headers, $scope->{headers}, 'headers accessor');
};

subtest 'scope accessor defaults' => sub {
    my $ctx = PAGI::Context->new({ type => 'http', headers => [] }, sub {}, sub {});

    is($ctx->raw_path, undef, 'raw_path undef when both undef');
    is($ctx->query_string, '', 'query_string defaults to empty string');
    is($ctx->scheme, 'http', 'scheme defaults to http');

    # raw_path falls back to path when raw_path is absent
    my $ctx2 = PAGI::Context->new(
        { type => 'http', path => '/fallback', headers => [] }, sub {}, sub {},
    );
    is($ctx2->raw_path, '/fallback', 'raw_path falls back to path');
};

subtest 'protocol introspection' => sub {
    my $receive = sub {};
    my $send = sub {};

    my $http = PAGI::Context->new({ type => 'http', headers => [] }, $receive, $send);
    ok($http->is_http, 'is_http true');
    ok(!$http->is_websocket, 'is_websocket false');
    ok(!$http->is_sse, 'is_sse false');

    my $ws = PAGI::Context->new({ type => 'websocket', headers => [] }, $receive, $send);
    ok(!$ws->is_http, 'is_http false');
    ok($ws->is_websocket, 'is_websocket true');
    ok(!$ws->is_sse, 'is_sse false');

    my $sse = PAGI::Context->new({ type => 'sse', headers => [] }, $receive, $send);
    ok(!$sse->is_http, 'is_http false');
    ok(!$sse->is_websocket, 'is_websocket false');
    ok($sse->is_sse, 'is_sse true');
};

subtest 'header lookup' => sub {
    my $scope = {
        type    => 'http',
        headers => [
            ['host', 'example.com'],
            ['accept', 'text/html'],
            ['accept', 'application/json'],
            ['X-Custom', 'value'],
        ],
    };

    my $ctx = PAGI::Context->new($scope, sub {}, sub {});

    is($ctx->header('host'), 'example.com', 'header lookup');
    is($ctx->header('Host'), 'example.com', 'case-insensitive');
    is($ctx->header('accept'), 'application/json', 'returns last value');
    is($ctx->header('x-custom'), 'value', 'case-insensitive custom header');
    is($ctx->header('nonexistent'), undef, 'missing header returns undef');
};

subtest 'path_params and path_param' => sub {
    my $scope = {
        type        => 'http',
        method      => 'GET',
        path        => '/users/42',
        headers     => [],
        path_params => { id => '42', format => 'json' },
    };
    my $ctx = PAGI::Context->new($scope, sub {}, sub {});

    is($ctx->path_params, { id => '42', format => 'json' }, 'path_params returns hashref');
    is($ctx->path_param('id'), '42', 'path_param returns value');
    is($ctx->path_param('format'), 'json', 'path_param second key');
};

subtest 'path_param strict mode' => sub {
    my $scope = {
        type        => 'http',
        headers     => [],
        path_params => { id => '42' },
    };
    my $ctx = PAGI::Context->new($scope, sub {}, sub {});

    like(
        dies { $ctx->path_param('missing') },
        qr/path_param 'missing' not found/,
        'strict mode dies on missing key'
    );

    is($ctx->path_param('missing', strict => 0), undef, 'non-strict returns undef');
};

subtest 'path_params defaults to empty hashref' => sub {
    my $ctx = PAGI::Context->new({ type => 'http', headers => [] }, sub {}, sub {});
    is($ctx->path_params, {}, 'defaults to empty hashref');
    is($ctx->path_param('x', strict => 0), undef, 'non-strict on missing params');
};

subtest 'path_param works on WebSocket context' => sub {
    my $scope = {
        type        => 'websocket',
        path        => '/ws/echo/lobby',
        headers     => [],
        path_params => { room => 'lobby' },
    };
    my $ctx = PAGI::Context->new($scope, sub {}, sub {});

    is($ctx->path_param('room'), 'lobby', 'path_param works on WebSocket');
};

subtest 'receive and send accessors' => sub {
    my $receive = sub { 'receive' };
    my $send = sub { 'send' };

    my $ctx = PAGI::Context->new({ type => 'http', headers => [] }, $receive, $send);

    is($ctx->receive, $receive, 'receive returns coderef');
    is($ctx->send, $send, 'send returns coderef');
};

done_testing;
