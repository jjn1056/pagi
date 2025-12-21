#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;

use lib 'lib';
use PAGI::WebSocket;

subtest 'initial state is connecting' => sub {
    my $scope = { type => 'websocket', headers => [] };
    my $ws = PAGI::WebSocket->new($scope, sub {}, sub {});

    ok(!$ws->is_connected, 'not connected initially');
    ok(!$ws->is_closed, 'not closed initially');
    is($ws->state, 'connecting', 'state is connecting');
    is($ws->close_code, undef, 'close_code is undef');
    is($ws->close_reason, undef, 'close_reason is undef');
};

subtest 'state transitions' => sub {
    my $scope = { type => 'websocket', headers => [] };
    my $ws = PAGI::WebSocket->new($scope, sub {}, sub {});

    # Simulate internal state change (normally done by accept)
    $ws->_set_state('connected');
    ok($ws->is_connected, 'is_connected after transition');
    ok(!$ws->is_closed, 'not closed after connect');
    is($ws->state, 'connected', 'state is connected');

    # Simulate close
    $ws->_set_closed(1000, 'Normal closure');
    ok(!$ws->is_connected, 'not connected after close');
    ok($ws->is_closed, 'is_closed after close');
    is($ws->state, 'closed', 'state is closed');
    is($ws->close_code, 1000, 'close_code is set');
    is($ws->close_reason, 'Normal closure', 'close_reason is set');
};

subtest 'close_code defaults' => sub {
    my $scope = { type => 'websocket', headers => [] };
    my $ws = PAGI::WebSocket->new($scope, sub {}, sub {});

    $ws->_set_closed();  # No args
    is($ws->close_code, 1005, 'close_code defaults to 1005 (no status)');
    is($ws->close_reason, '', 'close_reason defaults to empty string');
};

done_testing;
