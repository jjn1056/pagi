#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future;

use lib 'lib';
use PAGI::SSE;
use PAGI::Stash;

subtest 'constructor requires scope, receive, send' => sub {
    like(
        dies { PAGI::SSE->new },
        qr/requires scope/,
        'dies without scope'
    );

    like(
        dies { PAGI::SSE->new({}) },
        qr/requires receive/,
        'dies without receive'
    );

    like(
        dies { PAGI::SSE->new({}, sub {}) },
        qr/requires send/,
        'dies without send'
    );
};

subtest 'constructor validates scope type' => sub {
    like(
        dies { PAGI::SSE->new({ type => 'http' }, sub {}, sub {}) },
        qr/requires scope type 'sse'/,
        'dies with wrong scope type'
    );

    my $sse = PAGI::SSE->new({ type => 'sse' }, sub {}, sub {});
    isa_ok($sse, 'PAGI::SSE');
};

subtest 'basic accessors' => sub {
    my $scope = {
        type         => 'sse',
        path         => '/events',
        query_string => 'token=abc',
        scheme       => 'https',
        headers      => [
            ['last-event-id', '42'],
            ['authorization', 'Bearer xyz'],
        ],
    };
    my $receive = sub { Future->done };
    my $send = sub { Future->done };

    my $sse = PAGI::SSE->new($scope, $receive, $send);

    is($sse->path, '/events', 'path accessor');
    is($sse->query_string, 'token=abc', 'query_string accessor');
    is($sse->scheme, 'https', 'scheme accessor');
    ok($sse->scope == $scope, 'scope accessor returns same hashref');
    my $stash = PAGI::Stash->new($sse);
    ref_ok($stash->data, 'HASH', 'stash returns hashref');
};

subtest 'header accessors' => sub {
    my $scope = {
        type    => 'sse',
        headers => [
            ['last-event-id', '42'],
            ['cookie', 'a=1'],
            ['cookie', 'b=2'],
        ],
    };

    my $sse = PAGI::SSE->new($scope, sub {}, sub {});

    is($sse->header('last-event-id'), '42', 'single header lookup');
    is($sse->header('Last-Event-ID'), '42', 'header lookup case-insensitive');
    is($sse->header('x-missing'), undef, 'missing header returns undef');

    my @cookies = $sse->header_all('cookie');
    is(\@cookies, ['a=1', 'b=2'], 'header_all returns all values');
};

done_testing;
