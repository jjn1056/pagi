#!/usr/bin/env perl

# =============================================================================
# Test: Graceful Shutdown for Active Requests (Issue 2.4)
#
# This test exposes issue 2.4 from SERVER_ISSUES.md:
# During shutdown, active requests are aborted instead of being allowed
# to complete gracefully.
#
# Expected behavior (after fix):
# - Shutdown stops accepting NEW connections
# - Active requests are allowed to complete (with timeout)
# - Only after grace period are remaining connections force-closed
#
# Current behavior (before fix):
# - Shutdown calls $loop->stop immediately after lifespan hooks
# - Active requests are aborted mid-flight
# - Clients see connection reset errors
# =============================================================================

use strict;
use warnings;
use experimental 'signatures';
use Test2::V0;
use IO::Async::Loop;
use IO::Async::Timer::Countdown;
use IO::Socket::INET;
use Future::AsyncAwait;
use POSIX qw(WNOHANG);
use Time::HiRes qw(time sleep);
use FindBin;
use lib "$FindBin::Bin/../lib";

use PAGI::Server;

# =============================================================================
# Test: Active request should complete during graceful shutdown
# =============================================================================

subtest 'Active request should complete during shutdown' => sub {
    # App that handles requests with configurable delay
    # Query param ?delay=N causes N second delay before response
    my $slow_app = async sub ($scope, $receive, $send) {
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

        if ($scope->{type} eq 'http') {
            await $receive->();  # http.request

            # Parse delay from query string
            my $qs = $scope->{query_string} // '';
            my ($delay) = $qs =~ /delay=(\d+)/;
            $delay //= 0;

            # Simulate slow processing
            if ($delay > 0) {
                await IO::Async::Loop->new->delay_future(after => $delay);
            }

            await $send->({
                type    => 'http.response.start',
                status  => 200,
                headers => [['Content-Type', 'text/plain']],
            });

            await $send->({
                type => 'http.response.body',
                body => "completed after ${delay}s delay",
            });
        }
    };

    my $loop = IO::Async::Loop->new;

    my $server = PAGI::Server->new(
        app     => $slow_app,
        host    => '127.0.0.1',
        port    => 0,
        workers => 1,  # Single worker for simplicity
        quiet   => 1,
    );

    $loop->add($server);
    $server->listen;

    # Wait for server to be ready
    sleep(0.5);

    my $port = $server->port;

    # Fork a client process that makes a slow request
    my $client_pid = fork();
    if (!defined $client_pid) {
        fail("Fork failed: $!");
        return;
    }

    if ($client_pid == 0) {
        # Child: make a request with 2 second delay
        my $sock = IO::Socket::INET->new(
            PeerAddr => '127.0.0.1',
            PeerPort => $port,
            Proto    => 'tcp',
            Timeout  => 10,
        );

        if (!$sock) {
            warn "Client: Cannot connect: $!\n";
            exit(1);
        }

        # Send request for 2-second delayed response
        print $sock "GET /?delay=2 HTTP/1.1\r\n";
        print $sock "Host: 127.0.0.1:$port\r\n";
        print $sock "Connection: close\r\n";
        print $sock "\r\n";

        # Read response (blocking)
        my $response = '';
        while (my $line = <$sock>) {
            $response .= $line;
        }
        close $sock;

        # Check if we got a complete response
        if ($response =~ /HTTP\/1\.[01] 200/ && $response =~ /completed after/) {
            exit(0);  # Success
        } else {
            warn "Client: Incomplete response: $response\n";
            exit(1);  # Failed
        }
    }

    # Parent: wait a moment for request to start, then trigger shutdown
    sleep(0.5);  # Let request start processing

    # Trigger graceful shutdown
    $server->{running} = 0;
    $server->{shutting_down} = 1;

    # Send SIGTERM to workers
    for my $pid (keys %{$server->{worker_pids} // {}}) {
        kill 'TERM', $pid;
    }

    # Wait for client to complete (with timeout)
    my $client_timeout = 5;  # Should complete in ~2s if graceful
    my $start = time();
    my $client_status;

    while (time() - $start < $client_timeout) {
        my $kid = waitpid($client_pid, WNOHANG);
        if ($kid > 0) {
            $client_status = $? >> 8;
            last;
        }
        sleep(0.1);
    }

    # Clean up workers
    for my $pid (keys %{$server->{worker_pids} // {}}) {
        kill 'KILL', $pid;
        waitpid($pid, 0);
    }

    # Kill client if still running
    if (!defined $client_status) {
        kill 'KILL', $client_pid;
        waitpid($client_pid, 0);
        fail('Client timed out - request was likely aborted');
        return;
    }

    # THIS TEST SHOULD FAIL WITH CURRENT CODE
    # After fix, client should exit with 0 (success)
    is($client_status, 0,
        'Active request should complete successfully during graceful shutdown');

    if ($client_status != 0) {
        diag("VULNERABILITY: Active request was aborted during shutdown");
        diag("Client exit status: $client_status");
    }
};

# =============================================================================
# Test: Single-worker graceful shutdown
# =============================================================================

subtest 'Single-worker mode graceful shutdown' => sub {
    # Test with workers => 0 (single-worker mode) which is simpler
    # In single-worker mode, we can test shutdown behavior directly

    my $slow_app = async sub ($scope, $receive, $send) {
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

        if ($scope->{type} eq 'http') {
            await $receive->();

            # Simulate 1 second of work
            await IO::Async::Loop->new->delay_future(after => 1);

            await $send->({
                type    => 'http.response.start',
                status  => 200,
                headers => [['Content-Type', 'text/plain']],
            });
            await $send->({
                type => 'http.response.body',
                body => 'completed',
            });
        }
    };

    my $loop = IO::Async::Loop->new;

    my $server = PAGI::Server->new(
        app     => $slow_app,
        host    => '127.0.0.1',
        port    => 0,
        workers => 0,  # Single-worker mode
        quiet   => 1,
    );

    $loop->add($server);

    # Start server in background
    my $listen_f = $server->listen;
    $loop->loop_once(0.1) until $server->port;

    my $port = $server->port;

    # Start a slow request in background (non-blocking connect)
    my $client_done = 0;
    my $client_response = '';

    my $sock = IO::Socket::INET->new(
        PeerAddr => '127.0.0.1',
        PeerPort => $port,
        Proto    => 'tcp',
        Blocking => 0,
        Timeout  => 5,
    );

    SKIP: {
        skip "Cannot connect to server", 1 unless $sock;

        # Send request using syswrite to avoid buffering issues
        $sock->autoflush(1);
        my $req = "GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";
        syswrite($sock, $req);
        $sock->blocking(0);

        # Let request start processing - run loop multiple times to ensure
        # the request is received, parsed, and handling has started
        $loop->loop_once(0.1) for 1..5;

        # Now trigger shutdown while request is in progress
        # In current code, this should abort the request
        # After fix, request should complete

        $server->shutdown->retain;

        # Give the server time to process
        my $timeout = time() + 3;
        while (time() < $timeout) {
            $loop->loop_once(0.1);

            # Try to read response
            my $buf;
            my $n = sysread($sock, $buf, 4096);
            if (defined $n && $n > 0) {
                $client_response .= $buf;
            }

            last if $client_response =~ /completed/;
        }

        close $sock;

        # Check if request completed
        my $completed = ($client_response =~ /completed/);

        ok($completed, 'Request should complete during graceful shutdown');

        if (!$completed) {
            diag("Response received: " . substr($client_response, 0, 200));
            diag("ISSUE: Request was aborted during shutdown");
        }
    }
};

# =============================================================================
# Test: Verify current behavior - document what happens without fix
# =============================================================================

subtest 'Document current shutdown behavior' => sub {
    # This test documents the current (buggy) behavior without necessarily
    # failing. It helps us understand what we're fixing.

    my $request_started = 0;
    my $request_completed = 0;

    # These counters would need shared memory or files in real multi-process
    # For now, just document the expected flow

    pass('Current flow: SIGTERM → shutdown() → $loop->stop → exit');
    pass('Missing: Wait for active connections before stopping loop');
    pass('Result: Requests in progress are aborted');
};

done_testing;
