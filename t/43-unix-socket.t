#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use File::Temp qw(tmpnam);
use Config;
use IO::Async::Loop;
use IO::Socket::UNIX;
use Future::AsyncAwait;

plan skip_all => "Unix sockets not supported on Windows" if $^O eq 'MSWin32';

use lib 'lib';
use PAGI::Server;

subtest 'socket option is accepted' => sub {
    my $socket_path = tmpnam() . '.sock';

    my $server = PAGI::Server->new(
        app    => sub { },
        socket => $socket_path,
        quiet  => 1,
    );

    is($server->{socket}, $socket_path, 'socket path is stored');
    ok(!defined $server->{host}, 'host is undef when socket is set');
    ok(!defined $server->{port}, 'port is undef when socket is set');

    unlink $socket_path if -e $socket_path;
};

subtest 'socket and host/port are mutually exclusive' => sub {
    like(
        dies {
            PAGI::Server->new(
                app    => sub { },
                socket => '/tmp/test.sock',
                host   => '127.0.0.1',
                quiet  => 1,
            );
        },
        qr/cannot.*both.*socket.*host/i,
        'dies when both socket and host are specified'
    );

    like(
        dies {
            PAGI::Server->new(
                app    => sub { },
                socket => '/tmp/test.sock',
                port   => 8080,
                quiet  => 1,
            );
        },
        qr/cannot.*both.*socket.*port/i,
        'dies when both socket and port are specified'
    );
};

subtest 'server listens on Unix socket (single worker)' => sub {
    my $loop = IO::Async::Loop->new;
    my $socket_path = tmpnam() . '.sock';

    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        if ($scope->{type} eq 'lifespan') {
            while (1) {
                my $event = await $receive->();
                if ($event->{type} eq 'lifespan.startup') {
                    await $send->({ type => 'lifespan.startup.complete' });
                } elsif ($event->{type} eq 'lifespan.shutdown') {
                    await $send->({ type => 'lifespan.shutdown.complete' });
                    last;
                }
            }
            return;
        }
        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [['content-type', 'text/plain']],
        });
        await $send->({
            type => 'http.response.body',
            body => 'Hello Unix Socket',
            more => 0,
        });
    };

    my $server = PAGI::Server->new(
        app    => $app,
        socket => $socket_path,
        quiet  => 1,
    );

    $loop->add($server);
    $server->listen->get;

    ok($server->is_running, 'Server is running');
    ok(-S $socket_path, 'Socket file exists');

    # Fork a child to make request (event loop must run in parent)
    my $response = '';
    if (my $pid = fork()) {
        # Parent - run the loop to handle the request
        my $timer_f = $loop->delay_future(after => 2);
        $timer_f->get;
        waitpid($pid, 0);

        # Read response from temp file
        my $resp_file = "/tmp/pagi_test_response_$$";
        if (-e $resp_file) {
            open my $fh, '<', $resp_file;
            local $/;
            $response = <$fh>;
            close $fh;
            unlink $resp_file;
        }
    } else {
        # Child - make request
        select(undef, undef, undef, 0.2);  # Brief delay

        my $client = IO::Socket::UNIX->new(Peer => $socket_path);
        if ($client) {
            print $client "GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";
            my $resp = '';
            while (<$client>) { $resp .= $_; }
            close $client;

            # Write response to temp file for parent
            open my $fh, '>', "/tmp/pagi_test_response_" . getppid();
            print $fh $resp;
            close $fh;
        }
        exit 0;
    }

    like($response, qr/200 OK/, 'Got 200 response');
    like($response, qr/Hello Unix Socket/, 'Got expected body');

    $server->shutdown->get;
    $loop->remove($server);

    ok(!-e $socket_path, 'Socket file cleaned up after shutdown');
};

subtest 'server listens on Unix socket (multi-worker)' => sub {
    use POSIX ':sys_wait_h';

    my $socket_path = tmpnam() . '.sock';
    my $resp_file = "/tmp/pagi_mw_test_response_$$";

    # Fork server process
    my $server_pid = fork();
    die "Fork failed: $!" unless defined $server_pid;

    if ($server_pid == 0) {
        # Child: run the server
        my $app = async sub {
            my ($scope, $receive, $send) = @_;
            if ($scope->{type} eq 'lifespan') {
                while (1) {
                    my $event = await $receive->();
                    if ($event->{type} eq 'lifespan.startup') {
                        await $send->({ type => 'lifespan.startup.complete' });
                    } elsif ($event->{type} eq 'lifespan.shutdown') {
                        await $send->({ type => 'lifespan.shutdown.complete' });
                        last;
                    }
                }
                return;
            }
            await $send->({
                type    => 'http.response.start',
                status  => 200,
                headers => [['content-type', 'text/plain']],
            });
            await $send->({
                type => 'http.response.body',
                body => 'Hello Multi-Worker Unix Socket',
                more => 0,
            });
        };

        my $child_loop = IO::Async::Loop->new;
        my $server = PAGI::Server->new(
            app     => $app,
            socket  => $socket_path,
            workers => 2,
            quiet   => 1,
        );
        $child_loop->add($server);
        $server->listen->get;
        $child_loop->run;
        exit(0);
    }

    # Parent: wait for server to start, then test
    sleep(1);

    # Verify socket file exists
    ok(-S $socket_path, 'Socket file exists');

    # Make a request to the server
    my $response = '';
    my $client = IO::Socket::UNIX->new(Peer => $socket_path);
    if ($client) {
        print $client "GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";
        while (<$client>) { $response .= $_; }
        close $client;
    }

    like($response, qr/200 OK/, 'Got 200 response');
    like($response, qr/Hello Multi-Worker Unix Socket/, 'Got expected body');

    # Send SIGTERM to shut down the server
    kill 'TERM', $server_pid;

    # Wait for termination (with timeout)
    my $terminated = 0;
    for my $i (1..5) {
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

    # Socket should be cleaned up
    ok(!-e $socket_path, 'Socket file cleaned up after shutdown');

    # Clean up any leftover temp files
    unlink $resp_file if -e $resp_file;
};

done_testing;
