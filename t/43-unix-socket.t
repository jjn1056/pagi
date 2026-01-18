#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use File::Temp qw(tmpnam);
use Config;

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

done_testing;
