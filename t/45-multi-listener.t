#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use File::Temp qw(tmpnam);
use IO::Async::Loop;
use IO::Socket::UNIX;
use IO::Socket::INET;
use Future::AsyncAwait;

plan skip_all => "Unix sockets not supported on Windows" if $^O eq 'MSWin32';

use lib 'lib';
use PAGI::Server;

subtest 'TCP + Unix socket simultaneously (single worker)' => sub {
    my $loop = IO::Async::Loop->new;
    my $socket_path = tmpnam() . '.sock';

    my @captured_scopes;
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
        push @captured_scopes, $scope;
        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [['content-type', 'text/plain']],
        });
        await $send->({
            type => 'http.response.body',
            body => 'Hello',
            more => 0,
        });
    };

    my $server = PAGI::Server->new(
        app    => $app,
        listen => [
            { host => '127.0.0.1', port => 0 },
            { socket => $socket_path },
        ],
        quiet  => 1,
    );

    $loop->add($server);
    $server->listen->get;

    my $port = $server->port;
    ok($port > 0, "TCP listener bound to port $port");
    ok(-S $socket_path, "Unix socket exists at $socket_path");

    # Test TCP connection via fork (blocking I/O in child, event loop in parent)
    my $tcp_resp = '';
    my $tcp_resp_file = "/tmp/pagi_multi_tcp_$$";
    if (my $pid = fork()) {
        $loop->delay_future(after => 1)->get;
        waitpid($pid, 0);
        if (-e $tcp_resp_file) {
            open my $fh, '<', $tcp_resp_file;
            local $/;
            $tcp_resp = <$fh>;
            close $fh;
            unlink $tcp_resp_file;
        }
    } else {
        select(undef, undef, undef, 0.2);
        my $client = IO::Socket::INET->new(
            PeerAddr => '127.0.0.1',
            PeerPort => $port,
            Proto    => 'tcp',
        );
        if ($client) {
            print $client "GET /tcp HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";
            my $resp = '';
            while (<$client>) { $resp .= $_; }
            close $client;
            open my $fh, '>', $tcp_resp_file;
            print $fh $resp;
            close $fh;
        }
        exit 0;
    }
    like($tcp_resp, qr/200 OK/, 'TCP: got 200 response');

    # Test Unix socket connection via fork
    my $unix_resp = '';
    my $unix_resp_file = "/tmp/pagi_multi_unix_$$";
    if (my $pid = fork()) {
        $loop->delay_future(after => 1)->get;
        waitpid($pid, 0);
        if (-e $unix_resp_file) {
            open my $fh, '<', $unix_resp_file;
            local $/;
            $unix_resp = <$fh>;
            close $fh;
            unlink $unix_resp_file;
        }
    } else {
        select(undef, undef, undef, 0.2);
        my $client = IO::Socket::UNIX->new(Peer => $socket_path);
        if ($client) {
            print $client "GET /unix HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";
            my $resp = '';
            while (<$client>) { $resp .= $_; }
            close $client;
            open my $fh, '>', $unix_resp_file;
            print $fh $resp;
            close $fh;
        }
        exit 0;
    }
    like($unix_resp, qr/200 OK/, 'Unix: got 200 response');

    # Verify scope differences
    is(scalar @captured_scopes, 2, 'Two scopes captured');

    my ($tcp_scope) = grep { exists $_->{client} } @captured_scopes;
    my ($unix_scope) = grep { !exists $_->{client} } @captured_scopes;

    ok(defined $tcp_scope, 'TCP scope has client');
    ok(defined $unix_scope, 'Unix scope lacks client');

    if ($tcp_scope) {
        like($tcp_scope->{server}[0], qr/127\.0\.0\.1/, 'TCP server[0] is IP');
        ok(defined $tcp_scope->{server}[1], 'TCP server[1] is port');
    }
    if ($unix_scope) {
        is($unix_scope->{server}[0], $socket_path, 'Unix server[0] is socket path');
        is($unix_scope->{server}[1], undef, 'Unix server[1] is undef');
    }

    $server->shutdown->get;
    $loop->remove($server);

    ok(!-e $socket_path, 'Unix socket cleaned up after shutdown');
};

done_testing;
