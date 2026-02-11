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

# App that blocks forever during lifespan.shutdown (simulates stuck worker)
my $stuck_shutdown_app = async sub {
    my ($scope, $receive, $send) = @_;
    if ($scope->{type} eq 'lifespan') {
        while (1) {
            my $event = await $receive->();
            if ($event->{type} eq 'lifespan.startup') {
                await $send->({ type => 'lifespan.startup.complete' });
            }
            elsif ($event->{type} eq 'lifespan.shutdown') {
                # Block forever - simulate a stuck worker that won't shut down
                sleep(1000);
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
            body => "OK",
            more => 0,
        });
    }
};

# ============================================================================
# Bug 1: Shutdown SIGKILL Escalation
# ============================================================================

subtest 'Stuck workers get SIGKILL during shutdown' => sub {
    my $port = 5700 + int(rand(100));

    my $server_pid = fork();
    die "Fork failed: $!" unless defined $server_pid;

    if ($server_pid == 0) {
        my $child_loop = IO::Async::Loop->new;
        my $server = PAGI::Server->new(
            app              => $stuck_shutdown_app,
            host             => '127.0.0.1',
            port             => $port,
            workers          => 2,
            quiet            => 1,
            shutdown_timeout => 2,  # Short timeout for testing
        );
        $child_loop->add($server);
        $server->listen->get;
        $child_loop->run;
        exit(0);
    }

    # Wait for server to start
    ok(_wait_for_port($port), 'Server started and accepting connections');

    # Send SIGTERM to parent
    kill 'TERM', $server_pid;

    # Parent should exit within shutdown_timeout (2s) + scheduling slack
    # Total budget: 8s (2s timeout + 6s generous slack for CI/load)
    my ($terminated, $elapsed) = _wait_for_exit($server_pid, 8);

    ok($terminated, 'Server with stuck workers terminated within timeout');
    # The parent should wait ~shutdown_timeout then SIGKILL, so > 1.5s but < 8s
    ok($elapsed >= 1.5, "Shutdown took at least ~shutdown_timeout (${elapsed}s)");

    unless ($terminated) {
        kill 'KILL', $server_pid;
        waitpid($server_pid, 0);
    }
};

subtest 'Normal shutdown completes quickly (no escalation delay)' => sub {
    my $port = 5800 + int(rand(100));

    my $server_pid = fork();
    die "Fork failed: $!" unless defined $server_pid;

    if ($server_pid == 0) {
        my $child_loop = IO::Async::Loop->new;
        my $server = PAGI::Server->new(
            app              => $normal_app,
            host             => '127.0.0.1',
            port             => $port,
            workers          => 2,
            quiet            => 1,
            shutdown_timeout => 10,  # Long timeout - should NOT matter
        );
        $child_loop->add($server);
        $server->listen->get;
        $child_loop->run;
        exit(0);
    }

    ok(_wait_for_port($port), 'Server started and accepting connections');

    kill 'TERM', $server_pid;

    # Normal shutdown should complete well before shutdown_timeout (10s)
    my ($terminated, $elapsed) = _wait_for_exit($server_pid, 5);

    ok($terminated, 'Well-behaved server terminated quickly');
    ok($elapsed < 5, "Normal shutdown completed in ${elapsed}s (well before 10s timeout)");

    unless ($terminated) {
        kill 'KILL', $server_pid;
        waitpid($server_pid, 0);
    }
};

subtest 'Graceful restart kills stuck worker and replaces it' => sub {
    my $port = 5900 + int(rand(100));

    my $server_pid = fork();
    die "Fork failed: $!" unless defined $server_pid;

    if ($server_pid == 0) {
        my $child_loop = IO::Async::Loop->new;
        my $server = PAGI::Server->new(
            app              => $stuck_shutdown_app,
            host             => '127.0.0.1',
            port             => $port,
            workers          => 2,
            quiet            => 1,
            shutdown_timeout => 2,  # Short timeout for SIGKILL escalation
        );
        $child_loop->add($server);
        $server->listen->get;
        $child_loop->run;
        exit(0);
    }

    ok(_wait_for_port($port), 'Server started and accepting connections');

    # Send SIGHUP for graceful restart
    kill 'HUP', $server_pid;

    # Wait for workers to be killed (shutdown_timeout=2s) and respawned
    # Budget: 2s kill timeout + 3s respawn + slack = 8s
    sleep(5);

    # Server should still be alive and serving after restart
    my $responding = 0;
    eval {
        my $loop = IO::Async::Loop->new;
        my $http = Net::Async::HTTP->new;
        $loop->add($http);
        my $response = $http->GET("http://127.0.0.1:$port/")->get;
        $responding = ($response->code == 200);
        $loop->remove($http);
    };
    ok($responding, 'Server still responds after graceful restart with stuck workers');

    # Clean up: terminate the server
    kill 'TERM', $server_pid;
    my ($terminated, $elapsed) = _wait_for_exit($server_pid, 8);

    unless ($terminated) {
        kill 'KILL', $server_pid;
        waitpid($server_pid, 0);
    }
};

# ============================================================================
# Bug 2: Worker Parameter Pass-Through
# ============================================================================

subtest 'request_timeout passes to workers' => sub {
    my $port = 6000 + int(rand(100));

    # App that receives the request but never sends a response (stalls
    # without blocking the event loop, so the stall timer can fire)
    my $stalling_app = async sub {
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
            # Stall forever by awaiting a Future that never resolves.
            # This suspends the async function without blocking the event
            # loop, allowing the request stall timer to fire.
            await Future->new;
        }
    };

    my $server_pid = fork();
    die "Fork failed: $!" unless defined $server_pid;

    if ($server_pid == 0) {
        my $child_loop = IO::Async::Loop->new;
        my $server = PAGI::Server->new(
            app              => $stalling_app,
            host             => '127.0.0.1',
            port             => $port,
            workers          => 2,
            quiet            => 1,
            request_timeout  => 2,   # Workers should enforce this
            shutdown_timeout => 3,
        );
        $child_loop->add($server);
        $server->listen->get;
        $child_loop->run;
        exit(0);
    }

    ok(_wait_for_port($port), 'Server started');

    # Send a complete HTTP request. The app receives it but never responds.
    # The request_timeout stall timer should fire after 2s and close the
    # connection. Without request_timeout, it would hang for 60s (timeout).
    my $sock = IO::Socket::INET->new(
        PeerAddr => '127.0.0.1',
        PeerPort => $port,
        Proto    => 'tcp',
        Timeout  => 1,
    );
    ok($sock, 'Connected to server');

    # Send complete request
    print $sock "GET / HTTP/1.1\r\nHost: localhost\r\n\r\n";

    # Wait for the server to close the connection (request_timeout should fire)
    my $closed = 0;
    my $start = time();
    while (time() - $start < 5) {
        my $buf;
        my $bytes = sysread($sock, $buf, 1024);
        if (!defined $bytes || $bytes == 0) {
            $closed = 1;
            last;
        }
        sleep(0.2);
    }
    my $elapsed = time() - $start;
    close($sock);

    ok($closed, 'Server closed stalled connection');
    ok($elapsed < 4, "Connection closed in ${elapsed}s (request_timeout=2 active in worker)");

    # Clean up server
    kill 'TERM', $server_pid;
    my ($terminated) = _wait_for_exit($server_pid, 8);
    unless ($terminated) {
        kill 'KILL', $server_pid;
        waitpid($server_pid, 0);
    }
};

subtest 'shutdown_timeout passes to workers' => sub {
    my $port = 6100 + int(rand(100));

    # App that blocks during HTTP handling when it sees /slow path
    my $slow_app = async sub {
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
            # If path is /slow, block for a long time
            if ($scope->{path} eq '/slow') {
                sleep(60);
            }
            await $send->({
                type    => 'http.response.start',
                status  => 200,
                headers => [['content-type', 'text/plain']],
            });
            await $send->({
                type => 'http.response.body',
                body => "OK",
                more => 0,
            });
        }
    };

    my $server_pid = fork();
    die "Fork failed: $!" unless defined $server_pid;

    if ($server_pid == 0) {
        my $child_loop = IO::Async::Loop->new;
        my $server = PAGI::Server->new(
            app              => $slow_app,
            host             => '127.0.0.1',
            port             => $port,
            workers          => 1,
            quiet            => 1,
            shutdown_timeout => 2,  # Workers should use this, not default 30s
        );
        $child_loop->add($server);
        $server->listen->get;
        $child_loop->run;
        exit(0);
    }

    ok(_wait_for_port($port), 'Server started');

    # Start a slow request in the background (will block a worker)
    my $req_pid = fork();
    die "Fork failed: $!" unless defined $req_pid;
    if ($req_pid == 0) {
        my $sock = IO::Socket::INET->new(
            PeerAddr => '127.0.0.1',
            PeerPort => $port,
            Proto    => 'tcp',
            Timeout  => 1,
        );
        if ($sock) {
            print $sock "GET /slow HTTP/1.1\r\nHost: localhost\r\n\r\n";
            # Hold connection open
            sleep(60);
        }
        exit(0);
    }

    # Give the request time to reach the worker
    sleep(1);

    # Send SIGTERM to server - shutdown should complete within
    # shutdown_timeout (2s) + SIGKILL escalation (2s) + slack
    kill 'TERM', $server_pid;

    my ($terminated, $elapsed) = _wait_for_exit($server_pid, 10);

    ok($terminated, 'Server with slow request terminated');
    # With shutdown_timeout=2, the worker drain should timeout at 2s,
    # then the worker exits, then parent exits. Should be < 8s total.
    ok($elapsed < 8, "Shutdown completed in ${elapsed}s (shutdown_timeout=2 passed to worker)");

    # Clean up
    kill 'KILL', $req_pid if $req_pid;
    waitpid($req_pid, WNOHANG);
    unless ($terminated) {
        kill 'KILL', $server_pid;
        waitpid($server_pid, 0);
    }
};

done_testing;
