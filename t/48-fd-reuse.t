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

done_testing;
