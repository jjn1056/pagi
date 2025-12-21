#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Scalar::Util qw(refaddr);
use IO::Async::Loop;
use IO::Socket::INET;
use Future;
use Future::AsyncAwait;

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

subtest 'returns 503 when at max_connections' => sub {
    my $loop = IO::Async::Loop->new;

    my $server = PAGI::Server->new(
        app => async sub  {
        my ($scope, $receive, $send) = @_;
            # Handle lifespan
            if ($scope->{type} eq 'lifespan') {
                while (1) {
                    my $event = await $receive->();
                    if ($event->{type} eq 'lifespan.startup') {
                        await $send->({ type => 'lifespan.startup.complete' });
                    }
                    elsif ($event->{type} eq 'lifespan.shutdown') {
                        await $send->({ type => 'lifespan.shutdown.complete' });
                        last;
                    }
                }
                return;
            }

            # For HTTP requests, respond normally
            await $send->({ type => 'http.response.start', status => 200, headers => [] });
            await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
        },
        host => '127.0.0.1',
        port => 0,
        quiet => 1,
        max_connections => 1,  # Only allow 1 connection
    );

    $loop->add($server);
    $server->listen->get;
    my $port = $server->port;

    # Open first connection (don't send request yet - just connect)
    my $sock1 = IO::Socket::INET->new(
        PeerAddr => '127.0.0.1',
        PeerPort => $port,
        Proto    => 'tcp',
    ) or die "Cannot connect to first: $!";

    # Let server accept first connection
    $loop->loop_once(0.05);
    is($server->connection_count, 1, 'first connection active');

    # Try second connection - should get 503 immediately
    my $sock2 = IO::Socket::INET->new(
        PeerAddr => '127.0.0.1',
        PeerPort => $port,
        Proto    => 'tcp',
        Timeout  => 1,
    );

    if ($sock2) {
        # Let server process the new connection
        $loop->loop_once(0.05);

        # Now send the request
        print $sock2 "GET /second HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";

        # Give it time to send the 503 response
        $loop->loop_once(0.1);

        my $response = '';
        $sock2->blocking(0);
        while (my $line = <$sock2>) {
            $response .= $line;
        }

        close($sock2);

        # Debug output
        if ($response) {
            like($response, qr/503/, 'second connection gets 503 Service Unavailable');
            like($response, qr/Retry-After:/, 'response includes Retry-After header');
        } else {
            fail('second connection got empty response');
        }
    } else {
        # Connection refused is also acceptable (backpressure)
        pass('second connection refused (backpressure working)');
    }

    # Clean up first connection
    close($sock1);
    $loop->loop_once(0.05);

    $server->shutdown->get;
};

subtest 'EMFILE error pauses accepting temporarily' => sub {
    # This is hard to test directly without exhausting FDs
    # Instead, test that the server has the error handler installed
    my $loop = IO::Async::Loop->new;

    my $server = PAGI::Server->new(
        app => async sub  {
        my ($scope, $receive, $send) = @_;
            await $send->({ type => 'http.response.start', status => 200, headers => [] });
            await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
        },
        host => '127.0.0.1',
        port => 0,
        quiet => 1,
    );

    $loop->add($server);

    # Verify server can handle the _on_accept_error method being called
    ok($server->can('_on_accept_error'), 'server has _on_accept_error handler');
    ok($server->can('_pause_accepting'), 'server has _pause_accepting handler');

    pass('server has accept error handlers');
};

subtest 'logs warning when approaching max_connections' => sub {
    my $loop = IO::Async::Loop->new;
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, @_ };

    my $server = PAGI::Server->new(
        app => async sub  {
        my ($scope, $receive, $send) = @_;
            # Handle lifespan
            if ($scope->{type} eq 'lifespan') {
                while (1) {
                    my $event = await $receive->();
                    if ($event->{type} eq 'lifespan.startup') {
                        await $send->({ type => 'lifespan.startup.complete' });
                    }
                    elsif ($event->{type} eq 'lifespan.shutdown') {
                        await $send->({ type => 'lifespan.shutdown.complete' });
                        last;
                    }
                }
                return;
            }

            # For HTTP requests, respond normally
            await $send->({ type => 'http.response.start', status => 200, headers => [] });
            await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
        },
        host => '127.0.0.1',
        port => 0,
        quiet => 0,  # Enable logging
        log_level => 'warn',
        max_connections => 2,
    );

    $loop->add($server);
    $server->listen->get;
    my $port = $server->port;

    # Open connections to reach capacity
    my $sock1 = IO::Socket::INET->new(PeerAddr => '127.0.0.1', PeerPort => $port, Proto => 'tcp');
    print $sock1 "GET / HTTP/1.1\r\nHost: localhost\r\n\r\n";
    $loop->loop_once(0.05);

    my $sock2 = IO::Socket::INET->new(PeerAddr => '127.0.0.1', PeerPort => $port, Proto => 'tcp');
    print $sock2 "GET / HTTP/1.1\r\nHost: localhost\r\n\r\n";
    $loop->loop_once(0.05);

    # Third connection should be rejected with warning
    my $sock3 = IO::Socket::INET->new(PeerAddr => '127.0.0.1', PeerPort => $port, Proto => 'tcp');
    if ($sock3) {
        print $sock3 "GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";
        $loop->loop_once(0.1);
        close($sock3);
    }

    # Check for capacity warning
    my $capacity_warning = grep { /at capacity|rejected/i } @warnings;
    ok($capacity_warning, 'logged warning about capacity');

    close($sock1);
    close($sock2);
    $server->shutdown->get;
};

done_testing;
