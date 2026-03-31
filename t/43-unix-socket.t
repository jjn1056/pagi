#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use File::Temp qw(tmpnam);

plan skip_all => "Unix sockets not supported on Windows" if $^O eq 'MSWin32';

use lib 'lib';
use PAGI::Server;

subtest 'socket option normalizes to listeners' => sub {
    my $socket_path = tmpnam() . '.sock';

    my $server = PAGI::Server->new(
        app    => sub { },
        socket => $socket_path,
        quiet  => 1,
    );

    ok($server->{listeners}, 'listeners array exists');
    is(scalar @{$server->{listeners}}, 1, 'one listener');
    is($server->{listeners}[0]{type}, 'unix', 'type is unix');
    is($server->{listeners}[0]{path}, $socket_path, 'path matches');
    ok(!defined $server->{host}, 'host is undef');
    ok(!defined $server->{port}, 'port is undef');
};

subtest 'host/port normalizes to listeners' => sub {
    my $server = PAGI::Server->new(
        app   => sub { },
        host  => '127.0.0.1',
        port  => 9999,
        quiet => 1,
    );

    ok($server->{listeners}, 'listeners array exists');
    is(scalar @{$server->{listeners}}, 1, 'one listener');
    is($server->{listeners}[0]{type}, 'tcp', 'type is tcp');
    is($server->{listeners}[0]{host}, '127.0.0.1', 'host matches');
    is($server->{listeners}[0]{port}, 9999, 'port matches');
};

subtest 'listen array accepted directly' => sub {
    my $socket_path = tmpnam() . '.sock';

    my $server = PAGI::Server->new(
        app    => sub { },
        listen => [
            { host => '127.0.0.1', port => 8080 },
            { socket => $socket_path },
        ],
        quiet  => 1,
    );

    is(scalar @{$server->{listeners}}, 2, 'two listeners');
    is($server->{listeners}[0]{type}, 'tcp', 'first is tcp');
    is($server->{listeners}[1]{type}, 'unix', 'second is unix');
    is($server->{listeners}[1]{path}, $socket_path, 'socket path preserved');
};

subtest 'socket_mode preserved in listener spec' => sub {
    my $socket_path = tmpnam() . '.sock';

    my $server = PAGI::Server->new(
        app         => sub { },
        socket      => $socket_path,
        socket_mode => 0660,
        quiet       => 1,
    );

    is($server->{listeners}[0]{socket_mode}, 0660, 'socket_mode preserved');
};

subtest 'default host/port when nothing specified' => sub {
    my $server = PAGI::Server->new(
        app   => sub { },
        quiet => 1,
    );

    is(scalar @{$server->{listeners}}, 1, 'one listener');
    is($server->{listeners}[0]{type}, 'tcp', 'type is tcp');
    is($server->{listeners}[0]{host}, '127.0.0.1', 'default host');
    is($server->{listeners}[0]{port}, 5000, 'default port');
};

subtest 'socket + host is mutually exclusive' => sub {
    like(
        dies {
            PAGI::Server->new(
                app    => sub { },
                socket => '/tmp/test.sock',
                host   => '127.0.0.1',
                quiet  => 1,
            );
        },
        qr/Cannot specify both 'socket' and 'host'/,
        'dies when both socket and host specified'
    );
};

subtest 'socket + port is mutually exclusive' => sub {
    like(
        dies {
            PAGI::Server->new(
                app    => sub { },
                socket => '/tmp/test.sock',
                port   => 8080,
                quiet  => 1,
            );
        },
        qr/Cannot specify both 'socket' and 'port'/,
        'dies when both socket and port specified'
    );
};

subtest 'listen + host is mutually exclusive' => sub {
    like(
        dies {
            PAGI::Server->new(
                app    => sub { },
                listen => [{ host => '0.0.0.0', port => 8080 }],
                host   => '127.0.0.1',
                quiet  => 1,
            );
        },
        qr/Cannot specify both 'listen' and 'host'/,
        'dies when both listen and host specified'
    );
};

subtest 'listen empty array dies' => sub {
    like(
        dies {
            PAGI::Server->new(
                app    => sub { },
                listen => [],
                quiet  => 1,
            );
        },
        qr/non-empty arrayref/,
        'dies with empty listen array'
    );
};

subtest 'listen spec: socket + host in same spec dies' => sub {
    like(
        dies {
            PAGI::Server->new(
                app    => sub { },
                listen => [{ socket => '/tmp/t.sock', host => '0.0.0.0' }],
                quiet  => 1,
            );
        },
        qr/Cannot specify both 'socket' and 'host' in a listen spec/,
        'dies with socket+host in same listen spec'
    );
};

subtest 'listen spec: TCP requires host and port' => sub {
    like(
        dies {
            PAGI::Server->new(
                app    => sub { },
                listen => [{ host => '0.0.0.0' }],
                quiet  => 1,
            );
        },
        qr/TCP listen spec requires both 'host' and 'port'/,
        'dies when port missing from TCP spec'
    );
};

subtest 'socket_path accessor' => sub {
    my $socket_path = tmpnam() . '.sock';

    my $server = PAGI::Server->new(
        app    => sub { },
        socket => $socket_path,
        quiet  => 1,
    );

    is($server->socket_path, $socket_path, 'socket_path returns path');

    my $tcp_server = PAGI::Server->new(
        app   => sub { },
        port  => 0,
        quiet => 1,
    );

    is($tcp_server->socket_path, undef, 'socket_path undef for TCP server');
};

subtest 'listeners accessor' => sub {
    my $socket_path = tmpnam() . '.sock';

    my $server = PAGI::Server->new(
        app    => sub { },
        listen => [
            { host => '127.0.0.1', port => 8080 },
            { socket => $socket_path },
        ],
        quiet  => 1,
    );

    my $listeners = $server->listeners;
    is(scalar @$listeners, 2, 'two listeners');
    is($listeners->[0]{type}, 'tcp', 'first is tcp');
    is($listeners->[1]{type}, 'unix', 'second is unix');
};

subtest 'scope correctness for Unix socket connection' => sub {
    use IO::Async::Loop;
    use IO::Socket::UNIX;
    use Future::AsyncAwait;

    my $loop = IO::Async::Loop->new;
    my $socket_path = tmpnam() . '.sock';

    my $captured_scope;
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
        $captured_scope = $scope;
        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [['content-type', 'text/plain']],
        });
        await $send->({
            type => 'http.response.body',
            body => 'OK',
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

    ok(-S $socket_path, 'Socket file exists');

    # Make request via Unix socket in a fork
    my $response = '';
    if (my $pid = fork()) {
        my $timer_f = $loop->delay_future(after => 2);
        $timer_f->get;
        waitpid($pid, 0);

        my $resp_file = "/tmp/pagi_test_scope_$$";
        if (-e $resp_file) {
            open my $fh, '<', $resp_file;
            local $/;
            $response = <$fh>;
            close $fh;
            unlink $resp_file;
        }
    } else {
        select(undef, undef, undef, 0.3);
        my $client = IO::Socket::UNIX->new(Peer => $socket_path);
        if ($client) {
            print $client "GET /test HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";
            my $resp = '';
            while (<$client>) { $resp .= $_; }
            close $client;

            open my $fh, '>', "/tmp/pagi_test_scope_" . getppid();
            print $fh $resp;
            close $fh;
        }
        exit 0;
    }

    like($response, qr/200 OK/, 'Got 200 response over Unix socket');

    # Verify scope
    ok(defined $captured_scope, 'scope was captured');
    ok(!exists $captured_scope->{client}, 'client absent from scope');
    is($captured_scope->{server}[0], $socket_path, 'server[0] is socket path');
    is($captured_scope->{server}[1], undef, 'server[1] is undef');

    $server->shutdown->get;
    $loop->remove($server);

    ok(!-e $socket_path, 'Socket cleaned up after shutdown');
};

subtest 'port returns undef for unix-only server' => sub {
    my $socket_path = tmpnam() . '.sock';

    my $server = PAGI::Server->new(
        app    => sub { },
        socket => $socket_path,
        quiet  => 1,
    );

    is($server->port, undef, 'port undef for unix-only server');
};

done_testing;
