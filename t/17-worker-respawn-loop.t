#!/usr/bin/env perl

# =============================================================================
# Test: Worker Respawn Loop Prevention (Issue 2.3)
#
# This test exposes issue 2.3 from SERVER_ISSUES.md:
# Workers that fail during startup are respawned indefinitely, causing
# resource exhaustion and log spam.
#
# Expected behavior (after fix):
# - Workers that fail startup should NOT be respawned infinitely
# - Server should limit respawns or stop after repeated startup failures
#
# Current behavior (before fix):
# - All worker exits trigger respawn regardless of exit code
# - Startup failure causes infinite respawn loop
# =============================================================================

use strict;
use warnings;
use Test2::V0;
use IO::Async::Loop;
use IO::Async::Timer::Countdown;
use Future::AsyncAwait;
use File::Temp qw(tempfile);
use Time::HiRes qw(time sleep);
use POSIX qw(WNOHANG);
use FindBin;
use lib "$FindBin::Bin/../lib";

use PAGI::Server;

# =============================================================================
# Test: Count actual respawns with a failing app
# =============================================================================

subtest 'Startup failure should not cause excessive respawns' => sub {
    # Create a temp file to count worker startup attempts
    my ($fh, $counter_file) = tempfile(UNLINK => 1);
    close $fh;

    # Write initial count
    _write_count($counter_file, 0);

    # App that increments counter then fails during lifespan startup
    my $failing_app = async sub  {
        my ($scope, $receive, $send) = @_;
        if ($scope->{type} eq 'lifespan') {
            # Increment the counter file (each worker startup attempt)
            my $count = _read_count($counter_file);
            _write_count($counter_file, $count + 1);

            # Now fail startup
            my $event = await $receive->();
            if ($event->{type} eq 'lifespan.startup') {
                await $send->({
                    type    => 'lifespan.startup.failed',
                    message => 'Intentional startup failure for testing',
                });
            }
            return;
        }
    };

    my $loop = IO::Async::Loop->new;

    my $server = PAGI::Server->new(
        app     => $failing_app,
        host    => '127.0.0.1',
        port    => 0,
        workers => 2,       # Start with 2 workers
        quiet   => 1,
    );

    $loop->add($server);

    # Let server run for 1 second, then force stop
    my $test_duration = 1;

    # Start server
    $server->listen;

    # Set up a timer to stop after test_duration
    my $timer = IO::Async::Timer::Countdown->new(
        delay     => $test_duration,
        on_expire => sub {
            # Force stop - don't use shutdown() as it might not stop respawns
            $server->{running} = 0;
            $server->{shutting_down} = 1;
            for my $pid (keys %{$server->{worker_pids} // {}}) {
                kill 'KILL', $pid;  # Force kill
            }
            $loop->stop;
        },
    );
    $loop->add($timer);
    $timer->start;

    # Run the loop
    eval {
        local $SIG{ALRM} = sub { die "timeout\n" };
        alarm($test_duration + 3);
        $loop->run;
        alarm(0);
    };

    # Clean up any stragglers
    for my $pid (keys %{$server->{worker_pids} // {}}) {
        kill 'KILL', $pid;
        waitpid($pid, POSIX::WNOHANG);
    }
    # Reap any zombies
    while (waitpid(-1, POSIX::WNOHANG) > 0) { }

    # Check how many times workers tried to start
    my $spawn_count = _read_count($counter_file);

    # With 2 workers and no respawn loop, we'd expect ~2 attempts
    # With a respawn loop running for 2 seconds, we'd see MANY more
    # (workers fail almost instantly, so could be 50+ respawns)

    my $max_acceptable_spawns = 10;  # Allow some respawns, but not infinite

    diag("Worker startup attempts in ${test_duration}s: $spawn_count");

    # THIS TEST SHOULD FAIL WITH CURRENT BUGGY CODE
    # After fix, spawn_count should be <= max_acceptable_spawns
    cmp_ok($spawn_count, '<=', $max_acceptable_spawns,
        "Startup failures should not cause excessive respawns (got $spawn_count, max $max_acceptable_spawns)");
};

# Helper to read count from file
sub _read_count {
    my ($file) = @_;

    open my $fh, '<', $file or return 0;
    my $count = <$fh> // 0;
    close $fh;
    chomp $count;
    return $count + 0;
}

# Helper to write count to file (with locking for safety)
sub _write_count {
    my ($file, $count) = @_;

    open my $fh, '>', $file or die "Cannot write $file: $!";
    flock($fh, 2);  # LOCK_EX
    print $fh "$count\n";
    close $fh;
}

done_testing;
