#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use Future;

use lib 'lib';
use PAGI::WebSocket;

subtest 'accept sends websocket.accept event' => sub {
    my @sent;
    my $scope = { type => 'websocket', headers => [] };
    my $receive = sub { Future->done({ type => 'websocket.connect' }) };
    my $send = sub { push @sent, $_[0]; Future->done };

    my $ws = PAGI::WebSocket->new($scope, $receive, $send);

    my $result = $ws->accept->get;

    is(scalar @sent, 1, 'one event sent');
    is($sent[0]{type}, 'websocket.accept', 'sent websocket.accept');
    ok($ws->is_connected, 'state is connected after accept');
};

subtest 'accept with subprotocol' => sub {
    my @sent;
    my $scope = { type => 'websocket', headers => [], subprotocols => ['chat', 'json'] };
    my $receive = sub { Future->done({ type => 'websocket.connect' }) };
    my $send = sub { push @sent, $_[0]; Future->done };

    my $ws = PAGI::WebSocket->new($scope, $receive, $send);

    $ws->accept(subprotocol => 'chat')->get;

    is($sent[0]{subprotocol}, 'chat', 'subprotocol included in accept');
};

subtest 'accept with headers' => sub {
    my @sent;
    my $scope = { type => 'websocket', headers => [] };
    my $receive = sub { Future->done({ type => 'websocket.connect' }) };
    my $send = sub { push @sent, $_[0]; Future->done };

    my $ws = PAGI::WebSocket->new($scope, $receive, $send);

    $ws->accept(headers => [['x-custom', 'value']])->get;

    is($sent[0]{headers}, [['x-custom', 'value']], 'headers included in accept');
};

subtest 'close sends websocket.close event' => sub {
    my @sent;
    my $scope = { type => 'websocket', headers => [] };
    my $receive = sub { Future->done({ type => 'websocket.connect' }) };
    my $send = sub { push @sent, $_[0]; Future->done };

    my $ws = PAGI::WebSocket->new($scope, $receive, $send);
    $ws->accept->get;
    @sent = ();

    $ws->close->get;

    is(scalar @sent, 1, 'one event sent');
    is($sent[0]{type}, 'websocket.close', 'sent websocket.close');
    is($sent[0]{code}, 1000, 'default close code is 1000');
    ok($ws->is_closed, 'state is closed after close');
};

subtest 'close with code and reason' => sub {
    my @sent;
    my $scope = { type => 'websocket', headers => [] };
    my $receive = sub { Future->done({ type => 'websocket.connect' }) };
    my $send = sub { push @sent, $_[0]; Future->done };

    my $ws = PAGI::WebSocket->new($scope, $receive, $send);
    $ws->accept->get;
    @sent = ();

    $ws->close(4000, 'Custom reason')->get;

    is($sent[0]{code}, 4000, 'custom close code');
    is($sent[0]{reason}, 'Custom reason', 'custom close reason');
    is($ws->close_code, 4000, 'close_code accessor updated');
    is($ws->close_reason, 'Custom reason', 'close_reason accessor updated');
};

subtest 'close is idempotent' => sub {
    my $send_count = 0;
    my $scope = { type => 'websocket', headers => [] };
    my $receive = sub { Future->done({ type => 'websocket.connect' }) };
    my $send = sub { $send_count++; Future->done };

    my $ws = PAGI::WebSocket->new($scope, $receive, $send);
    $ws->accept->get;
    $send_count = 0;

    $ws->close->get;
    $ws->close->get;
    $ws->close->get;

    is($send_count, 1, 'close only sends once');
};

subtest 'run() resolves cleanly when receive fails' => sub {
    my $scope = { type => 'websocket', headers => [] };
    my $receive = sub { Future->fail("connection reset by peer") };
    my $ws = PAGI::WebSocket->new($scope, $receive, sub { Future->done });
    $ws->_set_state('connected');

    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, $_[0] };

    # Must resolve (not reject) — caller should not need to handle a failed Future
    my $f = $ws->run;
    ok !$f->is_failed, 'run() Future did not reject on receive failure';
    $f->get;

    ok scalar @warnings,                              'receive failure was warned';
    like $warnings[0], qr/connection reset by peer/,  'warning contains error text';
};

done_testing;
