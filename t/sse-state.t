use strict;
use warnings;
use Test2::V0;

require PAGI::SSE;

subtest 'state accessor reads from scope' => sub {
    my $scope = {
        type    => 'sse',
        path    => '/events',
        headers => [],
        state => { db => 'test-connection' },
    };

    my $sse = PAGI::SSE->new($scope, sub { }, sub { });

    is(ref($sse->state), 'HASH', 'state returns hashref');
    is($sse->state->{db}, 'test-connection', 'state contains db');
};

subtest 'state returns empty hash if not set' => sub {
    my $scope = {
        type    => 'sse',
        path    => '/events',
        headers => [],
    };

    my $sse = PAGI::SSE->new($scope, sub { }, sub { });

    is(ref($sse->state), 'HASH', 'state returns hashref when not injected');
    is(scalar keys %{$sse->state}, 0, 'state is empty when not injected');
};

subtest 'connection_state for internal state' => sub {
    my $scope = {
        type    => 'sse',
        path    => '/events',
        headers => [],
    };

    my $sse = PAGI::SSE->new($scope, sub { }, sub { });

    is($sse->connection_state, 'pending', 'connection_state returns internal state');
};

done_testing;
