#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;

use lib 'lib';
use PAGI::WebSocket;

subtest 'constructor accepts scope, receive, send' => sub {
    my $scope = {
        type         => 'websocket',
        path         => '/ws',
        query_string => 'token=abc',
        headers      => [
            ['host', 'example.com'],
            ['sec-websocket-protocol', 'chat, echo'],
        ],
        subprotocols => ['chat', 'echo'],
        client       => ['127.0.0.1', 54321],
    };
    my $receive = sub { };
    my $send = sub { };

    my $ws = PAGI::WebSocket->new($scope, $receive, $send);

    ok($ws, 'constructor returns object');
    isa_ok($ws, 'PAGI::WebSocket');

    # Verify internal state
    is($ws->{_state}, 'connecting', 'initial state is connecting');
    is($ws->{_close_code}, undef, 'close_code starts undefined');
    is($ws->{_close_reason}, undef, 'close_reason starts undefined');
    is($ws->{_on_close}, [], 'on_close callbacks start empty');
    is($ws->{scope}, $scope, 'scope is stored');
    is($ws->{receive}, $receive, 'receive is stored');
    is($ws->{send}, $send, 'send is stored');
};

subtest 'dies on non-websocket scope type' => sub {
    my $scope = { type => 'http', headers => [] };
    my $receive = sub { };
    my $send = sub { };

    like(
        dies { PAGI::WebSocket->new($scope, $receive, $send) },
        qr/websocket/i,
        'dies with message about websocket'
    );
};

subtest 'dies without required parameters' => sub {
    like(
        dies { PAGI::WebSocket->new() },
        qr/scope/i,
        'dies without scope'
    );

    my $scope = { type => 'websocket', headers => [] };
    like(
        dies { PAGI::WebSocket->new($scope) },
        qr/receive/i,
        'dies without receive'
    );

    my $receive = sub { };
    like(
        dies { PAGI::WebSocket->new($scope, $receive) },
        qr/send/i,
        'dies without send'
    );
};

subtest 'dies on invalid parameter types' => sub {
    like(
        dies { PAGI::WebSocket->new("not_a_hash", sub {}, sub {}) },
        qr/hashref/i,
        'dies when scope is not a hashref'
    );

    my $scope = { type => 'websocket', headers => [] };
    like(
        dies { PAGI::WebSocket->new($scope, "not_a_coderef", sub {}) },
        qr/receive.*coderef/i,
        'dies when receive is not a coderef'
    );

    like(
        dies { PAGI::WebSocket->new($scope, sub {}, "not_a_coderef") },
        qr/send.*coderef/i,
        'dies when send is not a coderef'
    );
};

subtest 'scope property accessors' => sub {
    my $scope = {
        type         => 'websocket',
        path         => '/chat/room1',
        raw_path     => '/chat/room1',
        query_string => 'token=abc&user=bob',
        scheme       => 'wss',
        http_version => '1.1',
        headers      => [
            ['host', 'example.com'],
            ['origin', 'https://example.com'],
        ],
        subprotocols => ['chat', 'json'],
        client       => ['192.168.1.1', 54321],
        server       => ['example.com', 443],
    };
    my $receive = sub { };
    my $send = sub { };

    my $ws = PAGI::WebSocket->new($scope, $receive, $send);

    is($ws->path, '/chat/room1', 'path accessor');
    is($ws->raw_path, '/chat/room1', 'raw_path accessor');
    is($ws->query_string, 'token=abc&user=bob', 'query_string accessor');
    is($ws->scheme, 'wss', 'scheme accessor');
    is($ws->http_version, '1.1', 'http_version accessor');
    is($ws->subprotocols, ['chat', 'json'], 'subprotocols accessor');
    is($ws->client, ['192.168.1.1', 54321], 'client accessor');
    is($ws->server, ['example.com', 443], 'server accessor');
    is($ws->scope, $scope, 'scope returns raw scope');
};

subtest 'header accessors' => sub {
    my $scope = {
        type    => 'websocket',
        headers => [
            ['host', 'example.com'],
            ['origin', 'https://example.com'],
            ['cookie', 'session=abc123'],
            ['x-custom', 'value1'],
            ['x-custom', 'value2'],
        ],
    };
    my $receive = sub { };
    my $send = sub { };

    my $ws = PAGI::WebSocket->new($scope, $receive, $send);

    is($ws->header('host'), 'example.com', 'single header');
    is($ws->header('Host'), 'example.com', 'case-insensitive');
    is($ws->header('x-custom'), 'value2', 'returns last value for duplicates');
    is($ws->header('nonexistent'), undef, 'returns undef for missing');

    my @customs = $ws->header_all('x-custom');
    is(\@customs, ['value1', 'value2'], 'header_all returns all values');

    isa_ok($ws->headers, ['Hash::MultiValue'], 'headers returns Hash::MultiValue');
};

subtest 'defaults for optional scope keys' => sub {
    my $scope = {
        type    => 'websocket',
        path    => '/ws',
        headers => [],
    };
    my $receive = sub { };
    my $send = sub { };

    my $ws = PAGI::WebSocket->new($scope, $receive, $send);

    is($ws->raw_path, '/ws', 'raw_path defaults to path');
    is($ws->query_string, '', 'query_string defaults to empty');
    is($ws->scheme, 'ws', 'scheme defaults to ws');
    is($ws->http_version, '1.1', 'http_version defaults to 1.1');
    is($ws->subprotocols, [], 'subprotocols defaults to empty array');
};

done_testing;
