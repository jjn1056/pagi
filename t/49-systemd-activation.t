#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use IO::Async::Loop;
use IO::Async::Stream;
use IO::Socket::INET;
use Future::AsyncAwait;
use POSIX ();

plan skip_all => "Unix sockets not supported on Windows" if $^O eq 'MSWin32';

use lib 'lib';
use PAGI::Server;

subtest 'systemd: reuses LISTEN_FDS TCP socket' => sub {
    my $loop = IO::Async::Loop->new;

    # Create a listening socket (simulating systemd)
    my $sd_socket = IO::Socket::INET->new(
        LocalAddr => '127.0.0.1',
        LocalPort => 0,
        Proto     => 'tcp',
        Listen    => 128,
        ReuseAddr => 1,
    ) or die "Cannot create socket: $!";

    my $port = $sd_socket->sockport;
    my $orig_fd = fileno($sd_socket);

    # systemd always passes fds starting at 3
    my $target_fd = 3;
    my $saved_fd;

    if ($orig_fd != $target_fd) {
        # Save whatever is at fd 3 (may be a pipe used by the test harness)
        $saved_fd = POSIX::dup($target_fd);

        POSIX::dup2($orig_fd, $target_fd)
            or plan skip_all => "Cannot dup2 to fd 3: $!";
    }

    local $ENV{LISTEN_FDS} = '1';
    local $ENV{LISTEN_PID} = $$;
    local $ENV{PAGI_REUSE};

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
            body => 'systemd activated',
            more => 0,
        });
    };

    my $server = PAGI::Server->new(
        app   => $app,
        host  => '127.0.0.1',
        port  => $port,
        quiet => 1,
    );

    $loop->add($server);
    $server->listen->get;

    # Verify inherited
    ok($server->listeners->[0]{_inherited}, 'marked inherited');

    # Verify env cleaned
    ok(!defined $ENV{LISTEN_FDS}, 'LISTEN_FDS cleaned');
    ok(!defined $ENV{LISTEN_PID}, 'LISTEN_PID cleaned');

    # Make request using IO::Async::Stream to avoid blocking
    my $resp_future = $loop->new_future;
    my $response = '';

    my $client_sock = IO::Socket::INET->new(
        PeerAddr => '127.0.0.1',
        PeerPort => $port,
        Proto    => 'tcp',
        Blocking => 0,
    ) or die "Cannot connect: $!";

    my $client_stream = IO::Async::Stream->new(
        handle  => $client_sock,
        on_read => sub {
            my ($self, $buffref, $eof) = @_;
            $response .= $$buffref;
            $$buffref = '';
            if ($eof) {
                $resp_future->done($response);
            }
            return 0;
        },
    );
    $loop->add($client_stream);
    $client_stream->write("GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");

    $response = $resp_future->get;

    like($response, qr/200 OK/, 'got 200 from systemd socket');
    like($response, qr/systemd activated/, 'got response body');

    # Stream may already be auto-removed on EOF
    $loop->remove($client_stream) if $client_stream->parent;
    $server->shutdown->get;
    $loop->remove($server);

    # Close our socket at target_fd and restore whatever was there before
    if ($orig_fd != $target_fd) {
        POSIX::close($target_fd);
        if (defined $saved_fd && $saved_fd >= 0) {
            POSIX::dup2($saved_fd, $target_fd);
            POSIX::close($saved_fd);
        }
    }
    close($sd_socket);
};

subtest 'systemd: LISTEN_PID mismatch skips fds' => sub {
    local $ENV{LISTEN_FDS} = '1';
    local $ENV{LISTEN_PID} = '99999999';
    local $ENV{PAGI_REUSE};

    my $server = PAGI::Server->new(app => sub {}, quiet => 1, port => 0);
    my $inherited = $server->_collect_inherited_fds;

    is(scalar keys %$inherited, 0, 'no fds with PID mismatch');
};

done_testing;
