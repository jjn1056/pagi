#!/usr/bin/env perl

# =============================================================================
# Test: Error Propagation and Handling
#
# This test verifies that errors in PAGI::Server are properly:
# 1. Logged (not silently swallowed)
# 2. Result in appropriate HTTP responses (500 for request errors)
# 3. Cause server crash for lifespan startup failures
# 4. Allow graceful degradation for non-fatal errors
#
# These tests demonstrate issues with ->retain that silently swallow errors.
# =============================================================================

use strict;
use warnings;
use Test2::V0;
use IO::Async::Loop;
use IO::Socket::INET;
use Future::AsyncAwait;
use POSIX qw(WNOHANG);
use Time::HiRes qw(time sleep);
use File::Temp qw(tempfile);
use FindBin;
use lib "$FindBin::Bin/../lib";

use PAGI::Server;

plan skip_all => "Server integration tests not supported on Windows" if $^O eq 'MSWin32';

# =============================================================================
# Helper: Capture STDERR from a forked server
# =============================================================================

sub run_server_capture_stderr {
    my (%opts) = @_;
    my $app = $opts{app};
    my $timeout = $opts{timeout} // 5;
    my $on_ready = $opts{on_ready};  # Callback when server is ready

    # Create temp file for STDERR capture
    my ($stderr_fh, $stderr_file) = tempfile(UNLINK => 1);

    my $pid = fork();
    die "Fork failed: $!" unless defined $pid;

    if ($pid == 0) {
        # Child: run server with STDERR redirected
        open STDERR, '>&', $stderr_fh or die "Can't redirect STDERR: $!";

        my $loop = IO::Async::Loop->new;
        my $server = PAGI::Server->new(
            app     => $app,
            host    => '127.0.0.1',
            port    => 0,
            workers => 0,
            quiet   => 0,  # We want to see error output
        );

        $loop->add($server);

        eval {
            $server->listen->get;

            # Signal ready by writing port to stdout
            print $server->port . "\n";
            STDOUT->flush;

            $loop->run;
        };
        if ($@) {
            warn "Server error: $@";
        }
        exit(0);
    }

    # Parent: wait for port number
    my $port;
    eval {
        local $SIG{ALRM} = sub { die "Timeout waiting for server" };
        alarm($timeout);

        # Read port from child's stdout (need pipe for this)
        # For now, just sleep and try common port
        sleep(0.5);
        alarm(0);
    };

    return {
        pid         => $pid,
        stderr_file => $stderr_file,
        stderr_fh   => $stderr_fh,
    };
}

sub get_stderr_contents {
    my ($info) = @_;
    seek($info->{stderr_fh}, 0, 0);
    local $/;
    my $contents = readline($info->{stderr_fh}) // '';
    return $contents;
}

sub cleanup_server {
    my ($info, $signal) = @_;
    $signal //= 'TERM';

    if ($info->{pid}) {
        kill $signal, $info->{pid};
        my $waited = 0;
        while ($waited < 5) {
            last if waitpid($info->{pid}, WNOHANG) > 0;
            sleep(0.1);
            $waited += 0.1;
        }
        # Force kill if still running
        if (waitpid($info->{pid}, WNOHANG) == 0) {
            kill 'KILL', $info->{pid};
            waitpid($info->{pid}, 0);
        }
    }
}

# =============================================================================
# Test: Request handler exception returns 500 and is logged
# =============================================================================

subtest 'Request handler exception returns 500 and is logged' => sub {
    my $loop = IO::Async::Loop->new;

    # App that throws exception on /?throw=1
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
            await $receive->();  # Get request

            # Check if we should throw
            my $qs = $scope->{query_string} // '';
            if ($qs =~ /throw=1/) {
                die "Intentional test exception for error propagation test";
            }

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
        app     => $app,
        host    => '127.0.0.1',
        port    => 0,
        workers => 0,
        quiet   => 1,
    );

    $loop->add($server);
    $server->listen->get;

    # Run loop briefly to ensure server is ready
    $loop->loop_once(0.1);

    my $port = $server->port;

    # Capture STDERR
    my $stderr_output = '';
    {
        # Make request that triggers exception
        my $sock = IO::Socket::INET->new(
            PeerAddr => '127.0.0.1',
            PeerPort => $port,
            Proto    => 'tcp',
            Timeout  => 5,
        );

        SKIP: {
            skip "Cannot connect to server", 2 unless $sock;

            print $sock "GET /?throw=1 HTTP/1.1\r\n";
            print $sock "Host: localhost\r\n";
            print $sock "Connection: close\r\n";
            print $sock "\r\n";

            # Read response
            my $response = '';
            $sock->blocking(0);
            my $timeout = time() + 3;
            while (time() < $timeout) {
                $loop->loop_once(0.1);
                my $buf;
                my $n = sysread($sock, $buf, 4096);
                if (defined $n && $n > 0) {
                    $response .= $buf;
                }
                elsif (!defined $n && $! == POSIX::EAGAIN) {
                    # No data yet, continue
                }
                else {
                    last;  # EOF or error
                }
            }
            close $sock;

            # Verify we got a 500 response
            # CURRENT BEHAVIOR: May get connection reset or no response
            # EXPECTED BEHAVIOR: Should get HTTP 500
            my $got_500 = ($response =~ /HTTP\/1\.[01] 500/);

            ok($got_500, 'Request exception returns 500 response')
                or diag("Response was: " . substr($response, 0, 200));

            # TODO: Verify error was logged
            # CURRENT BEHAVIOR: Error is silently swallowed via ->retain
            # EXPECTED BEHAVIOR: Error should be logged to STDERR
            # For now, we mark this as a known limitation
            pass('Error logging verification (placeholder - needs STDERR capture)');
        }
    }

    $server->shutdown->get;
};

# =============================================================================
# Test: Request handler Future failure returns 500 and is logged
# =============================================================================

subtest 'Request handler Future failure returns 500 and is logged' => sub {
    my $loop = IO::Async::Loop->new;

    # App that returns failed Future on /?fail=1
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
            await $receive->();

            my $qs = $scope->{query_string} // '';
            if ($qs =~ /fail=1/) {
                # Return a failed future by awaiting one
                await Future->fail("Intentional Future failure for test");
            }

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
        app     => $app,
        host    => '127.0.0.1',
        port    => 0,
        workers => 0,
        quiet   => 1,
    );

    $loop->add($server);
    $server->listen->get;
    $loop->loop_once(0.1);

    my $port = $server->port;

    my $sock = IO::Socket::INET->new(
        PeerAddr => '127.0.0.1',
        PeerPort => $port,
        Proto    => 'tcp',
        Timeout  => 5,
    );

    SKIP: {
        skip "Cannot connect to server", 2 unless $sock;

        print $sock "GET /?fail=1 HTTP/1.1\r\n";
        print $sock "Host: localhost\r\n";
        print $sock "Connection: close\r\n";
        print $sock "\r\n";

        my $response = '';
        $sock->blocking(0);
        my $timeout = time() + 3;
        while (time() < $timeout) {
            $loop->loop_once(0.1);
            my $buf;
            my $n = sysread($sock, $buf, 4096);
            if (defined $n && $n > 0) {
                $response .= $buf;
            }
            elsif (!defined $n && $! == POSIX::EAGAIN) {
                # continue
            }
            else {
                last;
            }
        }
        close $sock;

        my $got_500 = ($response =~ /HTTP\/1\.[01] 500/);

        ok($got_500, 'Future failure returns 500 response')
            or diag("Response was: " . substr($response, 0, 200));

        pass('Error logging verification (placeholder)');
    }

    $server->shutdown->get;
};

# =============================================================================
# Test: Lifespan startup failure crashes server
# =============================================================================

subtest 'Lifespan startup failure crashes server' => sub {
    # App that fails during lifespan startup
    my $app = async sub {
        my ($scope, $receive, $send) = @_;

        if ($scope->{type} eq 'lifespan') {
            my $event = await $receive->();
            if ($event->{type} eq 'lifespan.startup') {
                # Signal failure
                await $send->({
                    type    => 'lifespan.startup.failed',
                    message => 'Intentional startup failure for test',
                });
                return;
            }
        }

        # Should never get here
        if ($scope->{type} eq 'http') {
            await $receive->();
            await $send->({
                type    => 'http.response.start',
                status  => 200,
                headers => [],
            });
            await $send->({ type => 'http.response.body', body => 'Should not reach' });
        }
    };

    # Fork to test server exit
    my $pid = fork();
    die "Fork failed: $!" unless defined $pid;

    if ($pid == 0) {
        # Child: try to start server
        my $loop = IO::Async::Loop->new;
        my $server = PAGI::Server->new(
            app     => $app,
            host    => '127.0.0.1',
            port    => 0,
            workers => 0,
            quiet   => 1,
        );

        $loop->add($server);

        eval {
            $server->listen->get;
            $loop->loop_once(0.5);  # Give lifespan time to run
        };

        # If die happened (lifespan failure), exit with non-zero
        if ($@) {
            exit(1);  # Correctly indicates startup failure
        }
        exit(0);  # Server started successfully
    }

    # Parent: wait for child
    my $start = time();
    my $exited = 0;
    my $exit_code;

    while (time() - $start < 5) {
        my $kid = waitpid($pid, WNOHANG);
        if ($kid > 0) {
            $exit_code = $? >> 8;
            $exited = 1;
            last;
        }
        sleep(0.1);
    }

    unless ($exited) {
        kill 'KILL', $pid;
        waitpid($pid, 0);
        $exit_code = $? >> 8;
    }

    # CURRENT BEHAVIOR: Server may continue running despite startup failure
    # EXPECTED BEHAVIOR: Server should exit with non-zero code
    ok($exited, 'Server process exited after lifespan startup failure');

    # Exit code 1 would indicate failure was detected
    # Exit code 0 would mean server started despite failure (bug)
    isnt($exit_code, 0, 'Server exited with non-zero code on startup failure')
        or diag("Exit code was: $exit_code (expected non-zero)");
};

# =============================================================================
# Test: Lifespan shutdown failure is logged but shutdown completes
# =============================================================================

subtest 'Lifespan shutdown failure is logged but shutdown completes' => sub {
    my $loop = IO::Async::Loop->new;

    # App that fails during lifespan shutdown
    my $app = async sub {
        my ($scope, $receive, $send) = @_;

        if ($scope->{type} eq 'lifespan') {
            while (1) {
                my $event = await $receive->();
                if ($event->{type} eq 'lifespan.startup') {
                    await $send->({ type => 'lifespan.startup.complete' });
                }
                elsif ($event->{type} eq 'lifespan.shutdown') {
                    # Fail during shutdown
                    die "Intentional shutdown failure for test";
                }
            }
        }

        if ($scope->{type} eq 'http') {
            await $receive->();
            await $send->({
                type    => 'http.response.start',
                status  => 200,
                headers => [['Content-Type', 'text/plain']],
            });
            await $send->({ type => 'http.response.body', body => 'OK' });
        }
    };

    my $server = PAGI::Server->new(
        app              => $app,
        host             => '127.0.0.1',
        port             => 0,
        workers          => 0,
        quiet            => 1,
        shutdown_timeout => 2,  # Short timeout for test
    );

    $loop->add($server);
    $server->listen->get;
    $loop->loop_once(0.1);

    # Trigger shutdown - should complete despite error (via timeout)
    my $shutdown_completed = 0;
    my $shutdown_error;

    eval {
        local $SIG{ALRM} = sub { die "Test timeout" };
        alarm(10);

        my $shutdown_f = $server->shutdown;

        # Run loop until shutdown completes or times out
        my $timeout = time() + 5;
        while (time() < $timeout && !$shutdown_f->is_ready) {
            $loop->loop_once(0.1);
        }

        if ($shutdown_f->is_ready) {
            $shutdown_completed = 1;
            if ($shutdown_f->is_failed) {
                $shutdown_error = ($shutdown_f->failure)[0];
            }
        }

        alarm(0);
    };

    ok($shutdown_completed, 'Shutdown completed despite lifespan shutdown error');

    # TODO: Verify error was logged
    # CURRENT BEHAVIOR: Error may be silently swallowed
    # EXPECTED BEHAVIOR: Error should be logged
    pass('Shutdown error logging verification (placeholder)');
};

# =============================================================================
# Test: Server continues after request error (doesn't crash)
# =============================================================================

subtest 'Server continues after request error' => sub {
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

            # First request throws, second should succeed
            if ($request_count == 1) {
                die "First request intentionally fails";
            }

            await $send->({
                type    => 'http.response.start',
                status  => 200,
                headers => [['Content-Type', 'text/plain']],
            });
            await $send->({
                type => 'http.response.body',
                body => "Request $request_count OK",
            });
        }
    };

    my $server = PAGI::Server->new(
        app     => $app,
        host    => '127.0.0.1',
        port    => 0,
        workers => 0,
        quiet   => 1,
    );

    $loop->add($server);
    $server->listen->get;
    $loop->loop_once(0.1);

    my $port = $server->port;

    # First request - will fail
    {
        my $sock = IO::Socket::INET->new(
            PeerAddr => '127.0.0.1',
            PeerPort => $port,
            Proto    => 'tcp',
            Timeout  => 5,
        );
        if ($sock) {
            print $sock "GET /first HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";
            my $response = '';
            $sock->blocking(0);
            my $timeout = time() + 2;
            while (time() < $timeout) {
                $loop->loop_once(0.1);
                my $buf;
                sysread($sock, $buf, 4096) and $response .= $buf;
            }
            close $sock;
        }
    }

    # Brief pause
    $loop->loop_once(0.2);

    # Second request - should succeed (server still running)
    my $second_ok = 0;
    {
        my $sock = IO::Socket::INET->new(
            PeerAddr => '127.0.0.1',
            PeerPort => $port,
            Proto    => 'tcp',
            Timeout  => 5,
        );

        SKIP: {
            skip "Cannot connect for second request", 1 unless $sock;

            print $sock "GET /second HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";
            my $response = '';
            $sock->blocking(0);
            my $timeout = time() + 2;
            while (time() < $timeout) {
                $loop->loop_once(0.1);
                my $buf;
                my $n = sysread($sock, $buf, 4096);
                $response .= $buf if defined $n && $n > 0;
                last if $response =~ /Request 2 OK/;
            }
            close $sock;

            $second_ok = ($response =~ /HTTP\/1\.[01] 200/ && $response =~ /Request 2 OK/);
            ok($second_ok, 'Server continues to handle requests after error')
                or diag("Second response: " . substr($response, 0, 200));
        }
    }

    $server->shutdown->get;
};

done_testing;
