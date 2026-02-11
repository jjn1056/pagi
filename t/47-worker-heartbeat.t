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

# ============================================================================
# Configuration Acceptance Tests
# ============================================================================

subtest 'heartbeat_timeout defaults to 30' => sub {
    my $loop = IO::Async::Loop->new;
    my $server = PAGI::Server->new(
        app     => $normal_app,
        host    => '127.0.0.1',
        port    => 0,
        workers => 2,
        quiet   => 1,
    );
    $loop->add($server);

    is($server->{heartbeat_timeout}, 30, 'Default heartbeat_timeout is 30');

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

done_testing;
