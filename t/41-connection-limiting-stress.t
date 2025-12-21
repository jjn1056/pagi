#!/usr/bin/env perl
use strict;
use warnings;
use v5.32;
use Test2::V0;

# This test requires 'hey' to be installed and is skipped by default
# Run with: STRESS_TEST=1 prove -l t/41-connection-limiting-stress.t

plan skip_all => 'Set STRESS_TEST=1 to run stress tests' unless $ENV{STRESS_TEST};
plan skip_all => 'hey not installed' unless `which hey 2>/dev/null`;
plan skip_all => 'Fork tests not supported on Windows' if $^O eq 'MSWin32';

use IO::Async::Loop;
use PAGI::Server;
use Future::AsyncAwait;

subtest 'server survives high concurrency with low max_connections' => sub {
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
        max_connections => 50,  # Low limit to force 503s
    );

    $loop->add($server);
    $server->listen->get;
    my $port = $server->port;

    # Run hey in background
    my $pid = fork();
    die "Fork failed: $!" unless defined $pid;

    if ($pid == 0) {
        exec('hey', '-z', '5s', '-c', '100', "http://127.0.0.1:$port/");
        die "exec failed: $!";  # Should never reach here
    }

    # Let hey run for 5 seconds while we process
    my $end_time = time() + 6;
    while (time() < $end_time) {
        $loop->loop_once(0.1);
    }

    # Wait for hey to finish
    waitpid($pid, 0);
    my $exit_status = $? >> 8;
    # Note: hey returns 0 even when some requests get 503, which is expected

    # Server should still be alive
    ok($server->is_running, 'server survived stress test');

    $server->shutdown->get;
    pass('server shutdown cleanly after stress');
};

done_testing;
