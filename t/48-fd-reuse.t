#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use IO::Async::Loop;
use IO::Socket::INET;
use Future::AsyncAwait;

plan skip_all => "Unix sockets not supported on Windows" if $^O eq 'MSWin32';

use lib 'lib';
use PAGI::Server;

subtest 'PAGI_REUSE: empty env returns empty hashref' => sub {
    local $ENV{PAGI_REUSE};
    local $ENV{LISTEN_FDS};
    local $ENV{LISTEN_PID};

    my $server = PAGI::Server->new(app => sub {}, quiet => 1, port => 0);
    my $inherited = $server->_collect_inherited_fds;

    is(ref $inherited, 'HASH', 'returns hashref');
    is(scalar keys %$inherited, 0, 'empty when no env vars set');
};

subtest 'PAGI_REUSE: parses TCP entry' => sub {
    local $ENV{PAGI_REUSE} = '0.0.0.0:8080:99';
    local $ENV{LISTEN_FDS};
    local $ENV{LISTEN_PID};

    my $server = PAGI::Server->new(app => sub {}, quiet => 1, port => 0);
    my $inherited = $server->_collect_inherited_fds;

    ok(exists $inherited->{'0.0.0.0:8080'}, 'TCP key exists');
    is($inherited->{'0.0.0.0:8080'}{fd}, 99, 'fd number');
    is($inherited->{'0.0.0.0:8080'}{type}, 'tcp', 'type');
    is($inherited->{'0.0.0.0:8080'}{host}, '0.0.0.0', 'host');
    is($inherited->{'0.0.0.0:8080'}{port}, 8080, 'port');
    is($inherited->{'0.0.0.0:8080'}{source}, 'pagi_reuse', 'source');
};

subtest 'PAGI_REUSE: parses Unix entry' => sub {
    local $ENV{PAGI_REUSE} = 'unix:/tmp/pagi.sock:99';
    local $ENV{LISTEN_FDS};
    local $ENV{LISTEN_PID};

    my $server = PAGI::Server->new(app => sub {}, quiet => 1, port => 0);
    my $inherited = $server->_collect_inherited_fds;

    ok(exists $inherited->{'unix:/tmp/pagi.sock'}, 'Unix key exists');
    is($inherited->{'unix:/tmp/pagi.sock'}{fd}, 99, 'fd number');
    is($inherited->{'unix:/tmp/pagi.sock'}{type}, 'unix', 'type');
    is($inherited->{'unix:/tmp/pagi.sock'}{path}, '/tmp/pagi.sock', 'path');
};

subtest 'PAGI_REUSE: parses multiple entries' => sub {
    local $ENV{PAGI_REUSE} = '0.0.0.0:8080:5,unix:/tmp/pagi.sock:6';
    local $ENV{LISTEN_FDS};
    local $ENV{LISTEN_PID};

    my $server = PAGI::Server->new(app => sub {}, quiet => 1, port => 0);
    my $inherited = $server->_collect_inherited_fds;

    is(scalar keys %$inherited, 2, 'two entries');
    ok(exists $inherited->{'0.0.0.0:8080'}, 'TCP entry');
    ok(exists $inherited->{'unix:/tmp/pagi.sock'}, 'Unix entry');
};

subtest 'PAGI_REUSE: parses IPv6 entry' => sub {
    local $ENV{PAGI_REUSE} = '[::1]:5000:7';
    local $ENV{LISTEN_FDS};
    local $ENV{LISTEN_PID};

    my $server = PAGI::Server->new(app => sub {}, quiet => 1, port => 0);
    my $inherited = $server->_collect_inherited_fds;

    ok(exists $inherited->{'[::1]:5000'}, 'IPv6 key exists');
    is($inherited->{'[::1]:5000'}{fd}, 7, 'fd number');
};

subtest 'PAGI_REUSE: malformed entry skipped' => sub {
    local $ENV{PAGI_REUSE} = 'garbage,0.0.0.0:8080:5,::also-bad';
    local $ENV{LISTEN_FDS};
    local $ENV{LISTEN_PID};

    my $server = PAGI::Server->new(app => sub {}, quiet => 1, port => 0);
    my $inherited = $server->_collect_inherited_fds;

    is(scalar keys %$inherited, 1, 'only valid entry parsed');
    ok(exists $inherited->{'0.0.0.0:8080'}, 'valid TCP entry');
};

subtest 'LISTEN_FDS: ignored when LISTEN_PID mismatches' => sub {
    local $ENV{LISTEN_FDS} = '1';
    local $ENV{LISTEN_PID} = '99999999';
    local $ENV{LISTEN_FDNAMES} = 'test';
    local $ENV{PAGI_REUSE};

    my $server = PAGI::Server->new(app => sub {}, quiet => 1, port => 0);
    my $inherited = $server->_collect_inherited_fds;

    is(scalar keys %$inherited, 0, 'no fds when PID mismatches');
    ok(!defined $ENV{LISTEN_FDS}, 'LISTEN_FDS cleaned');
    ok(!defined $ENV{LISTEN_PID}, 'LISTEN_PID cleaned');
    ok(!defined $ENV{LISTEN_FDNAMES}, 'LISTEN_FDNAMES cleaned');
};

subtest 'fd reuse: server reuses inherited TCP socket from PAGI_REUSE' => sub {
    my $loop = IO::Async::Loop->new;

    # Create a real listening socket to simulate an inherited fd
    my $pre_socket = IO::Socket::INET->new(
        LocalAddr => '127.0.0.1',
        LocalPort => 0,
        Proto     => 'tcp',
        Listen    => 128,
        ReuseAddr => 1,
    ) or die "Cannot create socket: $!";

    my $port = $pre_socket->sockport;
    my $fd = fileno($pre_socket);

    local $ENV{PAGI_REUSE} = "127.0.0.1:$port:$fd";
    local $ENV{LISTEN_FDS};
    local $ENV{LISTEN_PID};

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
            body => 'reused',
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

    # Verify inherited flag
    ok($server->listeners->[0]{_inherited}, 'listener marked inherited');

    # Verify request works through reused socket using async IO
    my $resp = '';
    my $done_f = $loop->new_future;
    my $client_sock = IO::Socket::INET->new(
        PeerAddr => '127.0.0.1',
        PeerPort => $port,
        Proto    => 'tcp',
    ) or die "Cannot connect: $!";

    require IO::Async::Stream;
    my $client_stream = IO::Async::Stream->new(
        handle  => $client_sock,
        on_read => sub {
            my ($self, $buffref, $eof) = @_;
            $resp .= $$buffref;
            $$buffref = '';
            if ($eof) {
                $done_f->done unless $done_f->is_ready;
            }
            return 0;
        },
        on_read_eof => sub {
            $done_f->done unless $done_f->is_ready;
        },
    );
    $loop->add($client_stream);
    $client_stream->write("GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");

    # Wait for response with timeout
    my $timeout_f = $loop->delay_future(after => 5);
    Future->wait_any($done_f, $timeout_f)->get;
    eval { $loop->remove($client_stream) };

    like($resp, qr/200 OK/, 'got 200 from reused socket');
    like($resp, qr/reused/, 'got response body');

    $server->shutdown->get;
    $loop->remove($server);
};

subtest 'PAGI_REUSE: registered after new socket creation' => sub {
    my $loop = IO::Async::Loop->new;
    local $ENV{PAGI_REUSE};
    local $ENV{LISTEN_FDS};
    local $ENV{LISTEN_PID};

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
        app   => $app,
        host  => '127.0.0.1',
        port  => 0,
        quiet => 1,
    );

    $loop->add($server);
    $server->listen->get;

    my $port = $server->port;
    ok(defined $ENV{PAGI_REUSE}, 'PAGI_REUSE set after listen');
    like($ENV{PAGI_REUSE}, qr/127\.0\.0\.1:$port:\d+/,
        'PAGI_REUSE contains addr:port:fd');

    $server->shutdown->get;
    $loop->remove($server);

    ok(!$ENV{PAGI_REUSE} || $ENV{PAGI_REUSE} !~ /127\.0\.0\.1:$port/,
        'PAGI_REUSE entry removed after shutdown');
};

subtest 'PAGI_REUSE: Unix socket registered' => sub {
    use File::Temp qw(tmpnam);
    use IO::Socket::UNIX;

    my $loop = IO::Async::Loop->new;
    my $socket_path = tmpnam() . '.sock';
    local $ENV{PAGI_REUSE};
    local $ENV{LISTEN_FDS};
    local $ENV{LISTEN_PID};

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

    ok(defined $ENV{PAGI_REUSE}, 'PAGI_REUSE set for Unix socket');
    like($ENV{PAGI_REUSE}, qr/unix:\Q$socket_path\E:\d+/,
        'contains unix:path:fd');

    $server->shutdown->get;
    $loop->remove($server);
};

subtest 'inherited Unix socket NOT unlinked on shutdown' => sub {
    use File::Temp qw(tmpnam);
    use IO::Socket::UNIX;

    my $loop = IO::Async::Loop->new;
    my $socket_path = tmpnam() . '.sock';

    # Create a real Unix listening socket
    my $pre_socket = IO::Socket::UNIX->new(
        Local  => $socket_path,
        Type   => Socket::SOCK_STREAM(),
        Listen => 128,
    ) or die "Cannot create Unix socket: $!";

    my $fd = fileno($pre_socket);

    local $ENV{PAGI_REUSE} = "unix:$socket_path:$fd";
    local $ENV{LISTEN_FDS};
    local $ENV{LISTEN_PID};

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

    ok($server->listeners->[0]{_inherited}, 'marked as inherited');

    $server->shutdown->get;
    $loop->remove($server);

    # Key assertion: inherited Unix socket file should NOT be unlinked
    ok(-e $socket_path, 'inherited Unix socket file preserved after shutdown');

    # Clean up manually
    close($pre_socket);
    unlink $socket_path;
};

done_testing;
