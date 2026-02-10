#!/usr/bin/env perl
use strict;
use warnings;

use Test2::V0;
use IO::Async::Loop;
use IO::Async::Stream;
use Future::AsyncAwait;
use IO::Socket::UNIX;
use File::Temp ();
use POSIX ':sys_wait_h';

use FindBin;
use lib "$FindBin::Bin/../lib";
use PAGI::Server;

plan skip_all => "Unix sockets not available on Windows" if $^O eq 'MSWin32';

# Helper: generate a unique temporary socket path
sub tmp_socket_path {
    my $tmp = File::Temp->new(TEMPLATE => 'pagi-test-XXXXX', SUFFIX => '.sock', TMPDIR => 1);
    my $path = $tmp->filename;
    # Remove the temp file — we just need the unique path
    unlink $path;
    return $path;
}

# Simple PAGI app for testing
my $app = async sub {
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
        body => "hello from unix socket",
        more => 0,
    });
};

# Helper: send an HTTP request over a Unix socket using the event loop
async sub http_get_unix {
    my ($loop, $socket_path) = @_;

    my $sock = IO::Socket::UNIX->new(Peer => $socket_path)
        or die "Cannot connect to Unix socket $socket_path: $!";

    my $response = '';
    my $done = $loop->new_future;

    my $stream = IO::Async::Stream->new(
        handle    => $sock,
        on_read   => sub {
            my ($self, $buffref, $eof) = @_;
            $response .= $$buffref;
            $$buffref = '';
            if ($eof) {
                $done->done($response) unless $done->is_ready;
            }
            return 0;
        },
        on_read_eof => sub {
            $done->done($response) unless $done->is_ready;
        },
    );

    $loop->add($stream);
    $stream->write("GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");

    # Timeout safety
    my $timeout = $loop->timeout_future(after => 5);
    my $result = await Future->wait_any($done, $timeout);

    $loop->remove($stream);
    return $response;
}

# Test 1: Socket option is accepted, host/port cleared, accessor works
subtest 'Socket option accepted and accessor works' => sub {
    my $socket_path = tmp_socket_path();
    my $server = PAGI::Server->new(
        app    => $app,
        socket => $socket_path,
        quiet  => 1,
    );

    is($server->socket_path, $socket_path, 'socket_path accessor returns configured path');
    is($server->{host}, undef, 'host is cleared when socket is set');
    is($server->{port}, undef, 'port is cleared when socket is set');
    ok($server, 'Server created with socket option');
};

# Test 2: Socket + host is mutually exclusive
subtest 'Socket and host are mutually exclusive' => sub {
    my $socket_path = tmp_socket_path();
    like(
        dies {
            PAGI::Server->new(
                app    => $app,
                socket => $socket_path,
                host   => '127.0.0.1',
                quiet  => 1,
            );
        },
        qr/socket.*host|host.*socket/i,
        'Dies when both socket and host are specified',
    );
};

# Test 3: Socket + port is mutually exclusive
subtest 'Socket and port are mutually exclusive' => sub {
    my $socket_path = tmp_socket_path();
    like(
        dies {
            PAGI::Server->new(
                app    => $app,
                socket => $socket_path,
                port   => 5000,
                quiet  => 1,
            );
        },
        qr/socket.*port|port.*socket/i,
        'Dies when both socket and port are specified',
    );
};

# Test 4: Single-worker listens and responds on Unix socket
subtest 'Single-worker listens and responds on Unix socket' => sub {
    my $socket_path = tmp_socket_path();
    my $loop = IO::Async::Loop->new;

    my $server = PAGI::Server->new(
        app        => $app,
        socket     => $socket_path,
        quiet      => 1,
        access_log => undef,
    );

    $loop->add($server);
    $server->listen->get;

    ok($server->is_running, 'Server is running');
    ok(-S $socket_path, 'Socket file exists');

    # Send HTTP request via event-loop-driven client
    my $response = http_get_unix($loop, $socket_path)->get;

    like($response, qr/HTTP\/1\.1 200/, 'Got 200 response');
    like($response, qr/hello from unix socket/, 'Got expected body');

    $server->shutdown->get;
    ok(!$server->is_running, 'Server stopped');

    $loop->remove($server);
};

# Test 5: Socket file cleaned up on shutdown
subtest 'Socket file cleaned up on shutdown' => sub {
    my $socket_path = tmp_socket_path();
    my $loop = IO::Async::Loop->new;

    my $server = PAGI::Server->new(
        app    => $app,
        socket => $socket_path,
        quiet  => 1,
    );

    $loop->add($server);
    $server->listen->get;

    ok(-S $socket_path, 'Socket file exists while running');

    $server->shutdown->get;

    ok(! -e $socket_path, 'Socket file removed after shutdown');

    $loop->remove($server);
};

# Test 6: Stale socket file is removed on startup
subtest 'Stale socket file removed on startup' => sub {
    my $socket_path = tmp_socket_path();
    my $loop = IO::Async::Loop->new;

    # Create a stale socket file
    my $stale = IO::Socket::UNIX->new(
        Local  => $socket_path,
        Listen => 1,
    ) or die "Cannot create stale socket: $!";
    close $stale;  # Close it to make it stale
    ok(-S $socket_path, 'Stale socket file exists');

    my $server = PAGI::Server->new(
        app    => $app,
        socket => $socket_path,
        quiet  => 1,
    );

    $loop->add($server);

    # Should succeed despite stale socket
    $server->listen->get;
    ok($server->is_running, 'Server started despite stale socket');
    ok(-S $socket_path, 'New socket file exists');

    $server->shutdown->get;
    $loop->remove($server);
};

# Test 7: Multi-worker listens and responds on Unix socket
subtest 'Multi-worker listens and responds on Unix socket' => sub {
    my $socket_path = tmp_socket_path();

    my $server_pid = fork();
    die "Fork failed: $!" unless defined $server_pid;

    if ($server_pid == 0) {
        # Child: run multi-worker server
        my $child_loop = IO::Async::Loop->new;
        my $server = PAGI::Server->new(
            app        => $app,
            socket     => $socket_path,
            workers    => 2,
            quiet      => 1,
            access_log => undef,
        );
        $child_loop->add($server);
        $server->listen->get;
        $child_loop->run;
        exit(0);
    }

    # Parent: wait for server to start
    my $started = 0;
    for my $i (1..30) {
        if (-S $socket_path) {
            $started = 1;
            last;
        }
        select(undef, undef, undef, 0.1);  # sleep 100ms
    }
    ok($started, 'Socket file appeared (server started)');

    if ($started) {
        # Connect and verify response
        my $sock = IO::Socket::UNIX->new(Peer => $socket_path);
        ok($sock, 'Connected to Unix socket');

        if ($sock) {
            $sock->print("GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
            my $response = '';
            while (my $line = <$sock>) {
                $response .= $line;
            }
            close $sock;

            like($response, qr/HTTP\/1\.1 200/, 'Got 200 response from multi-worker');
            like($response, qr/hello from unix socket/, 'Got expected body from multi-worker');
        }
    }

    # Signal shutdown and wait
    kill 'TERM', $server_pid;
    my $terminated = 0;
    for my $i (1..10) {
        my $result = waitpid($server_pid, POSIX::WNOHANG());
        if ($result > 0) {
            $terminated = 1;
            last;
        }
        sleep 1;
    }
    ok($terminated, 'Server terminated after SIGTERM');

    # Socket should be cleaned up
    ok(! -e $socket_path, 'Socket file cleaned up after multi-worker shutdown');
};

done_testing;
