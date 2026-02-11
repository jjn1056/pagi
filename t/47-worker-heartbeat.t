use strict;
use warnings;
use Test2::V0;
use IO::Async::Loop;
use IO::Socket::INET;
use Net::Async::HTTP;
use Future::AsyncAwait;
use POSIX ':sys_wait_h';
use Time::HiRes qw(time sleep);

use PAGI::Server;

plan skip_all => "Server integration tests not supported on Windows" if $^O eq 'MSWin32';

# Helper: wait for a port to become reachable
sub _wait_for_port {
    my ($port, $timeout) = @_;
    $timeout //= 5;
    my $deadline = time() + $timeout;
    while (time() < $deadline) {
        my $sock = IO::Socket::INET->new(
            PeerAddr => '127.0.0.1',
            PeerPort => $port,
            Proto    => 'tcp',
            Timeout  => 0.5,
        );
        if ($sock) {
            close($sock);
            return 1;
        }
        sleep(0.2);
    }
    return 0;
}

# Helper: wait for process to exit, with timeout
sub _wait_for_exit {
    my ($pid, $timeout) = @_;
    $timeout //= 10;
    my $start = time();
    while (time() - $start < $timeout) {
        my $result = waitpid($pid, WNOHANG);
        return (1, time() - $start) if $result > 0;
        sleep(0.2);
    }
    return (0, time() - $start);
}

# Normal well-behaved app
my $normal_app = async sub {
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

# App that blocks the event loop on GET /block
my $blocking_app = async sub {
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

        if ($scope->{path} eq '/block') {
            # Block the event loop entirely — heartbeat stops
            sleep(1000);
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

# ============================================================================
# Configuration Acceptance Tests
# ============================================================================

subtest 'heartbeat_timeout defaults to 50' => sub {
    my $loop = IO::Async::Loop->new;
    my $server = PAGI::Server->new(
        app     => $normal_app,
        host    => '127.0.0.1',
        port    => 0,
        workers => 2,
        quiet   => 1,
    );
    $loop->add($server);

    is($server->{heartbeat_timeout}, 50, 'Default heartbeat_timeout is 50');

    $loop->remove($server);
};

subtest 'heartbeat_timeout is configurable' => sub {
    my $loop = IO::Async::Loop->new;
    my $server = PAGI::Server->new(
        app                => $normal_app,
        host               => '127.0.0.1',
        port               => 0,
        workers            => 2,
        heartbeat_timeout  => 10,
        quiet              => 1,
    );
    $loop->add($server);

    is($server->{heartbeat_timeout}, 10, 'heartbeat_timeout is configurable');

    $loop->remove($server);
};

subtest 'heartbeat_timeout=0 disables' => sub {
    my $loop = IO::Async::Loop->new;
    my $server = PAGI::Server->new(
        app                => $normal_app,
        host               => '127.0.0.1',
        port               => 0,
        workers            => 2,
        heartbeat_timeout  => 0,
        quiet              => 1,
    );
    $loop->add($server);

    is($server->{heartbeat_timeout}, 0, 'heartbeat_timeout=0 disables heartbeat');

    $loop->remove($server);
};

# ============================================================================
# Normal Workers Survive Heartbeat Monitoring
# ============================================================================

subtest 'Normal workers survive heartbeat monitoring' => sub {
    my $port = 6100 + int(rand(100));

    my $server_pid = fork();
    die "Fork failed: $!" unless defined $server_pid;

    if ($server_pid == 0) {
        my $child_loop = IO::Async::Loop->new;
        my $server = PAGI::Server->new(
            app               => $normal_app,
            host              => '127.0.0.1',
            port              => $port,
            workers           => 2,
            heartbeat_timeout => 3,
            quiet             => 1,
        );
        $child_loop->add($server);
        $server->listen->get;
        $child_loop->run;
        exit(0);
    }

    ok(_wait_for_port($port), 'Server started and accepting connections');

    # Send 5 requests over ~5 seconds (1/sec) — all should succeed
    my $all_ok = 1;
    for my $i (1..5) {
        eval {
            my $loop = IO::Async::Loop->new;
            my $http = Net::Async::HTTP->new;
            $loop->add($http);
            my $response = $http->GET("http://127.0.0.1:$port/")->get;
            $all_ok = 0 unless $response->code == 200;
            $loop->remove($http);
        };
        if ($@) {
            $all_ok = 0;
            last;
        }
        sleep(1) if $i < 5;
    }

    ok($all_ok, 'All 5 requests succeeded — healthy workers not killed by heartbeat');

    # Clean up
    kill 'TERM', $server_pid;
    my ($terminated, $elapsed) = _wait_for_exit($server_pid, 5);
    unless ($terminated) {
        kill 'KILL', $server_pid;
        waitpid($server_pid, 0);
    }
};

subtest 'heartbeat_timeout=0 workers still functional' => sub {
    my $port = 6200 + int(rand(100));

    my $server_pid = fork();
    die "Fork failed: $!" unless defined $server_pid;

    if ($server_pid == 0) {
        my $child_loop = IO::Async::Loop->new;
        my $server = PAGI::Server->new(
            app               => $normal_app,
            host              => '127.0.0.1',
            port              => $port,
            workers           => 2,
            heartbeat_timeout => 0,
            quiet             => 1,
        );
        $child_loop->add($server);
        $server->listen->get;
        $child_loop->run;
        exit(0);
    }

    ok(_wait_for_port($port), 'Server started with heartbeat disabled');

    my $responding = 0;
    eval {
        my $loop = IO::Async::Loop->new;
        my $http = Net::Async::HTTP->new;
        $loop->add($http);
        my $response = $http->GET("http://127.0.0.1:$port/")->get;
        $responding = ($response->code == 200);
        $loop->remove($http);
    };
    ok($responding, 'Server with heartbeat_timeout=0 handles requests normally');

    # Clean up
    kill 'TERM', $server_pid;
    my ($terminated, $elapsed) = _wait_for_exit($server_pid, 5);
    unless ($terminated) {
        kill 'KILL', $server_pid;
        waitpid($server_pid, 0);
    }
};

# ============================================================================
# Stuck Worker Detection
# ============================================================================

subtest 'Stuck worker killed by heartbeat and respawned' => sub {
    my $port = 6300 + int(rand(100));

    my $server_pid = fork();
    die "Fork failed: $!" unless defined $server_pid;

    if ($server_pid == 0) {
        my $child_loop = IO::Async::Loop->new;
        my $server = PAGI::Server->new(
            app               => $blocking_app,
            host              => '127.0.0.1',
            port              => $port,
            workers           => 1,  # Single worker — must be killed and respawned
            heartbeat_timeout => 3,
            quiet             => 1,
        );
        $child_loop->add($server);
        $server->listen->get;
        $child_loop->run;
        exit(0);
    }

    ok(_wait_for_port($port), 'Server started and accepting connections');

    # Verify server works before blocking it
    my $pre_ok = 0;
    eval {
        my $loop = IO::Async::Loop->new;
        my $http = Net::Async::HTTP->new(timeout => 3);
        $loop->add($http);
        my $response = $http->GET("http://127.0.0.1:$port/")->get;
        $pre_ok = ($response->code == 200);
        $loop->remove($http);
    };
    ok($pre_ok, 'Server responds before blocking');

    # Fire-and-forget: send GET /block via raw TCP to jam the only worker
    my $raw = IO::Socket::INET->new(
        PeerAddr => '127.0.0.1',
        PeerPort => $port,
        Proto    => 'tcp',
        Timeout  => 2,
    );
    if ($raw) {
        print $raw "GET /block HTTP/1.1\r\nHost: localhost\r\n\r\n";
        # Don't close — keep connection open so worker stays blocked
    }

    # Wait for heartbeat timeout (3s) + check interval (1.5s) + respawn + slack
    sleep(7);

    # Close the raw socket now (after worker was killed)
    close($raw) if $raw;

    # The respawned worker should handle this request
    my $responding = 0;
    eval {
        my $loop = IO::Async::Loop->new;
        my $http = Net::Async::HTTP->new(timeout => 5);
        $loop->add($http);
        my $response = $http->GET("http://127.0.0.1:$port/")->get;
        $responding = ($response->code == 200);
        $loop->remove($http);
    };
    ok($responding, 'Server responds after stuck worker was killed and respawned');

    # Clean up
    kill 'TERM', $server_pid;
    my ($terminated, $elapsed) = _wait_for_exit($server_pid, 8);
    unless ($terminated) {
        kill 'KILL', $server_pid;
        waitpid($server_pid, 0);
    }
};

# ============================================================================
# Shutdown Cleanup
# ============================================================================

subtest 'Clean shutdown with heartbeat enabled' => sub {
    my $port = 6400 + int(rand(100));

    my $server_pid = fork();
    die "Fork failed: $!" unless defined $server_pid;

    if ($server_pid == 0) {
        my $child_loop = IO::Async::Loop->new;
        my $server = PAGI::Server->new(
            app               => $normal_app,
            host              => '127.0.0.1',
            port              => $port,
            workers           => 2,
            heartbeat_timeout => 3,
            quiet             => 1,
        );
        $child_loop->add($server);
        $server->listen->get;
        $child_loop->run;
        exit(0);
    }

    ok(_wait_for_port($port), 'Server started with heartbeat enabled');

    # Send SIGTERM for graceful shutdown
    kill 'TERM', $server_pid;

    # Server should exit quickly (< 5s) without heartbeat timer interference
    my ($terminated, $elapsed) = _wait_for_exit($server_pid, 5);

    ok($terminated, 'Server with heartbeat exited cleanly on SIGTERM');
    ok($elapsed < 5, "Shutdown completed in ${elapsed}s (no heartbeat interference)");

    unless ($terminated) {
        kill 'KILL', $server_pid;
        waitpid($server_pid, 0);
    }
};

done_testing;
