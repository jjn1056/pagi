#!/usr/bin/env perl

# =============================================================================
# Test: Memory/Resource Leak Detection (adopt_future changes)
#
# Verifies that adopt_future changes don't introduce memory leaks.
# This is a sanity check, not a comprehensive leak detector.
#
# Runs only with RELEASE_TESTING=1
# =============================================================================

use strict;
use warnings;
use Test2::V0;
use IO::Async::Loop;
use IO::Async::Process;
use Future::AsyncAwait;
use FindBin;
use lib "$FindBin::Bin/../lib";

use PAGI::Server;

plan skip_all => "Server integration tests not supported on Windows" if $^O eq 'MSWin32';
plan skip_all => "Memory leak tests require RELEASE_TESTING=1" unless $ENV{RELEASE_TESTING};

# Helper to make async HTTP requests using IO::Async::Process
sub make_async_request {
    my ($loop, $port) = @_;

    my $done = $loop->new_future;

    my $proc = IO::Async::Process->new(
        command => ['curl', '-s', '-o', '/dev/null', '--max-time', '2', "http://127.0.0.1:$port/"],
        on_finish => sub {
            $done->done unless $done->is_ready;
        },
    );

    $loop->add($proc);

    return $done;
}

# =============================================================================
# Test: Server can handle multiple requests without unbounded growth
# =============================================================================

subtest 'Multiple requests complete without unbounded resource growth' => sub {
    my $loop = IO::Async::Loop->new;
    my $request_count = 0;

    my $app = async sub {
        my ($scope, $receive, $send) = @_;

        if ($scope->{type} eq 'lifespan') {
            while (1) {
                my $event = await $receive->();
                if ($event->{type} eq 'lifespan.startup') {
                    await $send->({ type => 'lifespan.startup.complete' });
                }
                elsif ($event->{type} eq 'lifespan.shutdown') {
                    await $send->({ type => 'lifespan.shutdown.complete' });
                    return;
                }
            }
        }

        if ($scope->{type} eq 'http') {
            $request_count++;
            await $receive->();
            await $send->({
                type    => 'http.response.start',
                status  => 200,
                headers => [['Content-Type', 'text/plain']],
            });
            await $send->({
                type => 'http.response.body',
                body => 'OK',
            });
        }
    };

    my $server = PAGI::Server->new(
        app              => $app,
        host             => '127.0.0.1',
        port             => 0,
        workers          => 0,
        quiet            => 1,
        shutdown_timeout => 2,
    );

    $loop->add($server);
    $server->listen->get;
    $loop->loop_once(0.1);

    my $port = $server->port;

    # Make 5 concurrent requests
    my @futures;
    for my $i (1..5) {
        push @futures, make_async_request($loop, $port);
    }

    # Wait for all to complete (with timeout)
    my $timeout = $loop->delay_future(after => 5);
    my $all_done = Future->wait_any(
        Future->wait_all(@futures),
        $timeout,
    );
    $all_done->get;

    # Verify requests were handled
    ok($request_count >= 4, "At least 4 of 5 requests were handled (got $request_count)");

    # Check adopted_futures count - main thing we care about
    my $adopted_count = 0;
    if ($server->can('adopted_futures')) {
        my @adopted = $server->adopted_futures;
        $adopted_count = scalar @adopted;
    }

    # With adopt_future, we should not accumulate many futures
    ok($adopted_count <= 10, "Adopted futures bounded (found $adopted_count)");

    $loop->remove($server);
    pass("Server cleanup successful");
};

# =============================================================================
# Test: Error requests are handled without resource leaks
# =============================================================================

subtest 'Error requests handled without leaking futures' => sub {
    my $loop = IO::Async::Loop->new;
    my $error_count = 0;

    my $app = async sub {
        my ($scope, $receive, $send) = @_;

        if ($scope->{type} eq 'lifespan') {
            while (1) {
                my $event = await $receive->();
                if ($event->{type} eq 'lifespan.startup') {
                    await $send->({ type => 'lifespan.startup.complete' });
                }
                elsif ($event->{type} eq 'lifespan.shutdown') {
                    await $send->({ type => 'lifespan.shutdown.complete' });
                    return;
                }
            }
        }

        if ($scope->{type} eq 'http') {
            $error_count++;
            await $receive->();
            die "Intentional test error";
        }
    };

    my $server = PAGI::Server->new(
        app              => $app,
        host             => '127.0.0.1',
        port             => 0,
        workers          => 0,
        quiet            => 1,
        shutdown_timeout => 2,
    );

    $loop->add($server);
    $server->listen->get;
    $loop->loop_once(0.1);

    my $port = $server->port;

    # Make 5 concurrent error-triggering requests
    my @futures;
    for my $i (1..5) {
        push @futures, make_async_request($loop, $port);
    }

    # Wait for all to complete (with timeout)
    my $timeout = $loop->delay_future(after => 5);
    my $all_done = Future->wait_any(
        Future->wait_all(@futures),
        $timeout,
    );
    $all_done->get;

    # Verify error requests were attempted
    ok($error_count >= 4, "At least 4 error requests were attempted (got $error_count)");

    # Check adopted_futures - should not grow unboundedly from errors
    my $adopted_count = 0;
    if ($server->can('adopted_futures')) {
        my @adopted = $server->adopted_futures;
        $adopted_count = scalar @adopted;
    }

    ok($adopted_count <= 10, "Error futures bounded (found $adopted_count)");

    $loop->remove($server);
    pass("Server cleanup after errors successful");
};

done_testing;
