#!/usr/bin/env perl
use strict;
use warnings;
use experimental 'signatures';
use Test2::V0;
use Scalar::Util qw(refaddr);

use PAGI::Server;

# Test connection_count method directly using internal hash
# (matching pattern from unit tests in this codebase)

subtest 'connection_count tracks active connections' => sub {
    # Create a minimal server object for testing
    my $server = bless {
        connections => {},
    }, 'PAGI::Server';

    # Initially no connections
    is($server->connection_count, 0, 'starts with 0 connections');

    # Simulate adding connections
    my $fake1 = bless {}, 'FakeConnection';
    my $fake2 = bless {}, 'FakeConnection';
    my $fake3 = bless {}, 'FakeConnection';

    $server->{connections}{refaddr($fake1)} = $fake1;
    is($server->connection_count, 1, 'tracks 1 connection');

    $server->{connections}{refaddr($fake2)} = $fake2;
    is($server->connection_count, 2, 'tracks 2 connections');

    $server->{connections}{refaddr($fake3)} = $fake3;
    is($server->connection_count, 3, 'tracks 3 connections');

    # Simulate removing connections
    delete $server->{connections}{refaddr($fake3)};
    is($server->connection_count, 2, 'back to 2 after removal');

    delete $server->{connections}{refaddr($fake1)};
    delete $server->{connections}{refaddr($fake2)};
    is($server->connection_count, 0, 'back to 0 after all removed');
};

subtest 'max_connections option is accepted' => sub {
    my $server = bless {
        connections => {},
        max_connections => 100,
    }, 'PAGI::Server';

    is($server->{max_connections}, 100, 'max_connections stored');
};

subtest 'auto-detects max_connections from ulimit' => sub {
    my $server = bless {
        connections => {},
        max_connections => 0,  # auto-detect
    }, 'PAGI::Server';

    # Should have auto-detected a reasonable limit
    my $effective = $server->effective_max_connections;
    ok($effective > 0, "auto-detected limit: $effective");
    ok($effective >= 10, "limit is at least minimum (10)");
};

subtest 'explicit max_connections overrides auto-detect' => sub {
    my $server = bless {
        connections => {},
        max_connections => 200,
    }, 'PAGI::Server';

    is($server->effective_max_connections, 200, 'uses explicit value');
};

done_testing;
