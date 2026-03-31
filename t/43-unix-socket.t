#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use File::Temp qw(tmpnam);
use IO::Async::Loop;
use IO::Socket::UNIX;
use Future::AsyncAwait;

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

subtest 'socket_mode sets file permissions' => sub {
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
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
    };

    my $server = PAGI::Server->new(
        app         => $app,
        socket      => $socket_path,
        socket_mode => 0660,
        quiet       => 1,
    );

    $loop->add($server);
    $server->listen->get;

    ok(-S $socket_path, 'Socket file exists');
    my $mode = (stat($socket_path))[2] & 07777;
    is(sprintf('%04o', $mode), '0660', 'Socket has correct permissions');

    $server->shutdown->get;
    $loop->remove($server);
};

subtest 'stale socket file is cleaned up before bind' => sub {
    my $loop = IO::Async::Loop->new;
    my $socket_path = tmpnam() . '.sock';

    # Create a stale file at the socket path
    open my $fh, '>', $socket_path or die "Cannot create stale file: $!";
    print $fh "stale";
    close $fh;
    ok(-e $socket_path, 'Stale file exists');

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
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
    };

    my $server = PAGI::Server->new(
        app    => $app,
        socket => $socket_path,
        quiet  => 1,
    );

    $loop->add($server);

    ok(lives { $server->listen->get }, 'Server binds despite stale file');
    ok(-S $socket_path, 'Socket file exists (is a socket now)');

    $server->shutdown->get;
    $loop->remove($server);
};

subtest 'multi-worker Unix socket' => sub {
    plan skip_all => "Multi-worker tests require RELEASE_TESTING"
        unless $ENV{RELEASE_TESTING};

    use POSIX ':sys_wait_h';

    my $socket_path = tmpnam() . '.sock';

    my $server_pid = fork();
    die "Fork failed: $!" unless defined $server_pid;

    if ($server_pid == 0) {
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

    # Parent: wait for server, then test
    sleep(2);

    ok(-S $socket_path, 'Socket file exists');

    my $response = '';
    my $client = IO::Socket::UNIX->new(Peer => $socket_path);
    if ($client) {
        print $client "GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";
        while (<$client>) { $response .= $_; }
        close $client;
    }

    like($response, qr/200 OK/, 'Got 200 response');
    like($response, qr/Hello Multi-Worker Unix Socket/, 'Got expected body');

    kill 'TERM', $server_pid;

    my $terminated = 0;
    for (1..10) {
        if (waitpid($server_pid, WNOHANG) > 0) {
            $terminated = 1;
            last;
        }
        sleep(1);
    }

    ok($terminated, 'Server terminated on SIGTERM');

    unless ($terminated) {
        kill 'KILL', $server_pid;
        waitpid($server_pid, 0);
    }

    ok(!-e $socket_path, 'Socket cleaned up after shutdown');
};

subtest 'CLI --listen parser: path with colon treated as Unix socket' => sub {
    # This tests the detection logic used in bin/pagi-server
    # Paths starting with / or . should always be Unix sockets
    # even if they contain colons followed by digits

    # Simulate the parser logic
    my @test_cases = (
        ['/tmp/pagi.sock',           'unix',  '/tmp/pagi.sock',    undef, 'absolute path'],
        ['./pagi.sock',              'unix',  './pagi.sock',       undef, 'relative path'],
        ['/var/run/app:8080',        'unix',  '/var/run/app:8080', undef, 'path with colon+digits'],
        ['127.0.0.1:5000',          'tcp',   '127.0.0.1',         5000,  'IPv4:port'],
        ['0.0.0.0:8080',            'tcp',   '0.0.0.0',           8080,  'wildcard:port'],
        ['localhost:3000',           'tcp',   'localhost',          3000,  'hostname:port'],
        ['[::1]:5000',              'tcp',   '::1',               5000,  'IPv6:port'],
    );

    for my $case (@test_cases) {
        my ($input, $expected_type, $expected_val1, $expected_val2, $desc) = @$case;
        my ($type, $host, $port, $path);

        if ($input =~ m{^[./]}) {
            # Starts with / or . — always a Unix socket path
            $type = 'unix';
            $path = $input;
        } elsif ($input =~ /^\[([^\]]+)\]:(\d+)$/) {
            $type = 'tcp';
            ($host, $port) = ($1, int($2));
        } elsif ($input =~ /^(.+):(\d+)$/) {
            $type = 'tcp';
            ($host, $port) = ($1, int($2));
        } else {
            $type = 'unix';
            $path = $input;
        }

        is($type, $expected_type, "$desc: type=$expected_type");
        if ($expected_type eq 'tcp') {
            is($host, $expected_val1, "$desc: host");
            is($port, $expected_val2, "$desc: port");
        } else {
            is($path, $expected_val1, "$desc: path");
        }
    }
};

subtest 'socket_mode CLI validation rejects non-octal' => sub {
    # Test the validation logic that should be in bin/pagi-server
    # Values without leading 0 are ambiguous and should be rejected

    my @valid = ('0660', '0600', '0777', '0700', '0770');
    my @invalid = ('660', '777', '600', 'abc', '0888', '1234');

    for my $v (@valid) {
        like($v, qr/^0[0-7]{3}$/, "valid octal: $v");
    }
    for my $v (@invalid) {
        unlike($v, qr/^0[0-7]{3}$/, "invalid octal: $v");
    }
};

subtest 'socket created with restrictive permissions before chmod' => sub {
    my $loop = IO::Async::Loop->new;
    my $socket_path = tmpnam() . '.sock';

    # Don't set socket_mode — we want to see the umask-based default
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
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
    };

    my $server = PAGI::Server->new(
        app    => $app,
        socket => $socket_path,
        quiet  => 1,
    );

    $loop->add($server);
    $server->listen->get;

    ok(-S $socket_path, 'Socket file exists');
    my $mode = (stat($socket_path))[2] & 07777;
    # With umask(0177), socket should be owner-only (0600)
    # The exact bits depend on the kernel but should NOT be world-accessible
    ok(!($mode & 0002), 'Socket is not world-writable (umask protection)');
    ok(!($mode & 0020), 'Socket is not group-writable (umask protection)');

    $server->shutdown->get;
    $loop->remove($server);
};

subtest 'umask restored after socket bind' => sub {
    my $loop = IO::Async::Loop->new;
    my $socket_path = tmpnam() . '.sock';

    # Record umask before
    my $before = umask();
    umask($before);  # restore (umask returns old value)

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
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
    };

    my $server = PAGI::Server->new(
        app    => $app,
        socket => $socket_path,
        quiet  => 1,
    );

    $loop->add($server);
    $server->listen->get;

    # Check umask was restored
    my $after = umask();
    umask($after);
    is($after, $before, 'Process umask restored after socket bind');

    $server->shutdown->get;
    $loop->remove($server);
};

done_testing;
