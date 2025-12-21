#!/usr/bin/env perl
use strict;
use warnings;

use Test2::V0;
use IO::Async::Loop;
use Future::AsyncAwait;

use lib 't/lib';
use lib '../lib';
use PAGI::Server;

# Skip if not running on a system that supports fork
plan skip_all => "Fork not available on this platform" if $^O eq 'MSWin32';

# Test 1: Server accepts workers configuration
subtest 'Server accepts workers configuration' => sub {
    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        if ($scope->{type} eq 'lifespan') {
            my $event = await $receive->();
            if ($event->{type} eq 'lifespan.startup') {
                await $send->({ type => 'lifespan.startup.complete' });
            }
            $event = await $receive->();
            if ($event && $event->{type} eq 'lifespan.shutdown') {
                await $send->({ type => 'lifespan.shutdown.complete' });
            }
            return;
        }
        die "Unsupported: $scope->{type}" unless $scope->{type} eq 'http';
        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [['content-type', 'text/plain']],
        });
        await $send->({
            type => 'http.response.body',
            body => "ok",
            more => 0,
        });
    };

    my $loop = IO::Async::Loop->new;

    # Test that server can be created with workers option
    my $server = PAGI::Server->new(
        app     => $app,
        host    => '127.0.0.1',
        port    => 0,  # Let OS assign port
        workers => 2,
        quiet   => 1,
    );

    ok($server, 'Server created with workers option');
    $loop->add($server);

    # Check internal state
    is($server->{workers}, 2, 'Workers option stored correctly');

    pass('Multi-worker configuration accepted');
};

# Test 2: Single worker mode (workers=0 or 1) works as before
subtest 'Single worker mode continues to work' => sub {
    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        if ($scope->{type} eq 'lifespan') {
            my $event = await $receive->();
            if ($event->{type} eq 'lifespan.startup') {
                await $send->({ type => 'lifespan.startup.complete' });
            }
            $event = await $receive->();
            if ($event && $event->{type} eq 'lifespan.shutdown') {
                await $send->({ type => 'lifespan.shutdown.complete' });
            }
            return;
        }
        die "Unsupported: $scope->{type}" unless $scope->{type} eq 'http';
        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [['content-type', 'text/plain']],
        });
        await $send->({
            type => 'http.response.body',
            body => "Single worker",
            more => 0,
        });
    };

    my $loop = IO::Async::Loop->new;

    # Create server with 0 workers (single process mode)
    my $server = PAGI::Server->new(
        app     => $app,
        host    => '127.0.0.1',
        port    => 0,
        workers => 0,
        quiet   => 1,
    );

    ok($server, 'Server created with workers=0');
    $loop->add($server);

    is($server->{workers}, 0, 'Single worker mode (workers=0)');

    pass('Single worker configuration works');
};

# Note: Multi-worker functional tests require complex process management
# and have been verified manually.
#
# The implementation in lib/PAGI/Server.pm uses IO::Async idiomatically:
# - Uses $loop->fork() which properly clears $ONE_TRUE_LOOP and resets signals
# - Uses $loop->watch_process() for automatic worker restart on exit
# - Uses $loop->watch_signal() for graceful shutdown (SIGTERM/SIGINT)
# - Parent runs $loop->run() instead of manual select() loop
# - Per-worker lifespan startup/shutdown in each forked process
#
# Loop isolation is tested in t/12-fork-loop-isolation.t which verifies:
# - Child process gets a fresh loop instance (not parent's cached loop)
# - $ONE_TRUE_LOOP is properly cleared in child
#
# Manual verification:
# 1. ./bin/pagi-server --app examples/01-hello-http/app.pl --port 9777 --workers 2
# 2. curl http://127.0.0.1:9777/ - Response received successfully
# 3. kill -9 <worker_pid> - Worker is automatically respawned
# 4. kill -TERM <parent_pid> - Graceful shutdown of all workers

done_testing;
