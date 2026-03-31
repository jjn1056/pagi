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

done_testing;
