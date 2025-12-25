use strict;
use warnings;
use Test2::V0;
use IO::Async::Loop;
use Net::Async::HTTP;
use Future::AsyncAwait;
use POSIX ':sys_wait_h';

use PAGI::Server;

plan skip_all => "Server integration tests not supported on Windows" if $^O eq 'MSWin32';

# Test: Multi-worker Signal Handling
# This test verifies that multi-worker servers properly terminate on SIGINT/SIGTERM.
#
# Background: Previously, _listen_multiworker called $loop->run() internally,
# but Runner::run() also called $loop->run() after listen->get returned.
# This caused a double-loop situation where the second signal was ignored.

my $loop = IO::Async::Loop->new;

# Simple app for testing
my $app = async sub  {
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
    elsif ($scope->{type} eq 'http') {
        while (1) {
            my $event = await $receive->();
            last if $event->{type} ne 'http.request';
            last unless $event->{more};
        }
        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [['content-type', 'text/plain']],
        });
        await $send->({
            type => 'http.response.body',
            body => "OK from worker $$",
            more => 0,
        });
    }
};

subtest 'Multi-worker terminates on SIGINT' => sub {
    my $port = 5300 + int(rand(100));

    # Fork a process to run the server
    my $server_pid = fork();
    die "Fork failed: $!" unless defined $server_pid;

    if ($server_pid == 0) {
        # Child: run the server
        my $child_loop = IO::Async::Loop->new;
        my $server = PAGI::Server->new(
            app     => $app,
            host    => '127.0.0.1',
            port    => $port,
            workers => 2,
            quiet   => 1,
        );
        $child_loop->add($server);
        $server->listen->get;
        $child_loop->run;
        exit(0);
    }

    # Parent: wait for server to start, then test
    sleep(2);

    # Verify server is responding
    my $http = Net::Async::HTTP->new;
    $loop->add($http);

    my $response_ok = 0;
    eval {
        my $response = $http->GET("http://127.0.0.1:$port/")->get;
        $response_ok = ($response->code == 200);
    };
    ok($response_ok, 'Server is responding before signal');

    # Send SIGINT
    kill 'INT', $server_pid;

    # Wait for termination (with timeout)
    my $terminated = 0;
    for my $i (1..10) {  # 10 second timeout
        my $result = waitpid($server_pid, WNOHANG);
        if ($result > 0) {
            $terminated = 1;
            last;
        }
        sleep(1);
    }

    ok($terminated, 'Server terminated on SIGINT within timeout');

    # Clean up if not terminated
    unless ($terminated) {
        kill 'KILL', $server_pid;
        waitpid($server_pid, 0);
    }

    $loop->remove($http);
};

subtest 'Multi-worker terminates on SIGTERM' => sub {
    my $port = 5400 + int(rand(100));

    # Fork a process to run the server
    my $server_pid = fork();
    die "Fork failed: $!" unless defined $server_pid;

    if ($server_pid == 0) {
        # Child: run the server
        my $child_loop = IO::Async::Loop->new;
        my $server = PAGI::Server->new(
            app     => $app,
            host    => '127.0.0.1',
            port    => $port,
            workers => 2,
            quiet   => 1,
        );
        $child_loop->add($server);
        $server->listen->get;
        $child_loop->run;
        exit(0);
    }

    # Parent: wait for server to start, then test
    sleep(2);

    # Verify server is responding
    my $http = Net::Async::HTTP->new;
    $loop->add($http);

    my $response_ok = 0;
    eval {
        my $response = $http->GET("http://127.0.0.1:$port/")->get;
        $response_ok = ($response->code == 200);
    };
    ok($response_ok, 'Server is responding before signal');

    # Send SIGTERM
    kill 'TERM', $server_pid;

    # Wait for termination (with timeout)
    my $terminated = 0;
    for my $i (1..10) {  # 10 second timeout
        my $result = waitpid($server_pid, WNOHANG);
        if ($result > 0) {
            $terminated = 1;
            last;
        }
        sleep(1);
    }

    ok($terminated, 'Server terminated on SIGTERM within timeout');

    # Clean up if not terminated
    unless ($terminated) {
        kill 'KILL', $server_pid;
        waitpid($server_pid, 0);
    }

    $loop->remove($http);
};

subtest 'No zombie worker processes after shutdown' => sub {
    # This test uses lsof which is unreliable across different environments:
    # - Not installed on some systems (OpenBSD uses fstat, minimal containers lack it)
    # - Permission issues in sandboxed/container environments
    # - Different PATH configurations on CI systems
    # Skip under automated testing - signal handling is already tested by subtests 1 & 2
    if ($ENV{AUTOMATED_TESTING} || $ENV{NONINTERACTIVE_TESTING}) {
        plan skip_all => 'lsof-based test skipped under automated testing';
        return;
    }

    my $has_lsof = `which lsof 2>/dev/null`;
    chomp($has_lsof);
    if (!$has_lsof) {
        plan skip_all => 'lsof not available on this system';
        return;
    }

    my $port = 5500 + int(rand(100));

    # Fork a process to run the server
    my $server_pid = fork();
    die "Fork failed: $!" unless defined $server_pid;

    if ($server_pid == 0) {
        # Child: run the server
        my $child_loop = IO::Async::Loop->new;
        my $server = PAGI::Server->new(
            app     => $app,
            host    => '127.0.0.1',
            port    => $port,
            workers => 3,
            quiet   => 1,
        );
        $child_loop->add($server);
        $server->listen->get;
        $child_loop->run;
        exit(0);
    }

    # Parent: wait for server to start
    sleep(2);

    # Count processes listening on our port before shutdown
    my $before_procs = `lsof -ti :$port 2>/dev/null | wc -l`;
    chomp($before_procs);
    $before_procs += 0;  # Convert to number

    ok($before_procs > 0, "Processes found listening on port before shutdown (found $before_procs)");

    # Send SIGINT
    kill 'INT', $server_pid;

    # Wait for termination
    for my $i (1..10) {
        my $result = waitpid($server_pid, WNOHANG);
        last if $result > 0;
        sleep(1);
    }

    # Give a moment for worker cleanup
    sleep(1);

    # Check for zombie/orphan processes
    my $after_procs = `lsof -ti :$port 2>/dev/null | wc -l`;
    chomp($after_procs);
    $after_procs += 0;

    is($after_procs, 0, "No processes left on port after shutdown (found $after_procs)");

    # Force cleanup if needed
    if ($after_procs > 0) {
        system("lsof -ti :$port 2>/dev/null | xargs kill -9 2>/dev/null");
    }
};

done_testing;
