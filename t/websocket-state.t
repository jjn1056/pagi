use strict;
use warnings;
use Test2::V0;

require PAGI::WebSocket;

subtest 'state accessor reads from scope' => sub {
    my $scope = {
        type    => 'websocket',
        path    => '/ws',
        headers => [],
        state => { db => 'test-connection' },
    };

    my $ws = PAGI::WebSocket->new($scope, sub { }, sub { });

    is(ref($ws->state), 'HASH', 'state returns hashref');
    is($ws->state->{db}, 'test-connection', 'state contains db');
};

subtest 'state returns empty hash if not set' => sub {
    my $scope = {
        type    => 'websocket',
        path    => '/ws',
        headers => [],
    };

    my $ws = PAGI::WebSocket->new($scope, sub { }, sub { });

    is(ref($ws->state), 'HASH', 'state returns hashref');
    is($ws->state, {}, 'state is empty when not injected');
};

subtest 'state is separate from stash' => sub {
    my $scope = {
        type    => 'websocket',
        path    => '/ws',
        headers => [],
        state => { db => 'connection' },
    };

    my $ws = PAGI::WebSocket->new($scope, sub { }, sub { });

    $ws->stash->{room} = 'lobby';

    is($ws->state->{db}, 'connection', 'state has app data');
    is($ws->stash->{room}, 'lobby', 'stash has connection data');
    ok(!exists $ws->state->{room}, 'state does not have stash data');
};

subtest 'connection_state for internal state' => sub {
    my $scope = {
        type    => 'websocket',
        path    => '/ws',
        headers => [],
    };

    my $ws = PAGI::WebSocket->new($scope, sub { }, sub { });

    is($ws->connection_state, 'connecting', 'connection_state returns internal state');
};

done_testing;
