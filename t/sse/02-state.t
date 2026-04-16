#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future;

use lib 'lib';
use PAGI::SSE;

subtest 'initial state is pending' => sub {
    my $sse = PAGI::SSE->new({ type => 'sse' }, sub {}, sub {});

    is($sse->connection_state, 'pending', 'initial connection_state is pending');
    ok(!$sse->is_started, 'is_started is false');
    ok(!$sse->is_closed, 'is_closed is false');
};

subtest 'state transitions' => sub {
    my $sse = PAGI::SSE->new({ type => 'sse' }, sub {}, sub {});

    $sse->_set_state('started');
    is($sse->connection_state, 'started', 'connection_state is started');
    ok($sse->is_started, 'is_started is true');
    ok(!$sse->is_closed, 'is_closed is false');

    $sse->_set_closed;
    is($sse->connection_state, 'closed', 'connection_state is closed');
    ok(!$sse->is_started, 'is_started is false after close');
    ok($sse->is_closed, 'is_closed is true');
};

subtest 'run() resolves cleanly when receive fails' => sub {
    use Future::AsyncAwait;
    my $receive = sub { Future->fail("upstream gone") };
    my $sse = PAGI::SSE->new({ type => 'sse' }, $receive, sub { Future->done });
    $sse->_set_state('started');

    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, $_[0] };

    my $f = $sse->run;
    ok !$f->is_failed, 'run() Future did not reject on receive failure';
    $f->get;

    ok scalar @warnings,                    'receive failure was warned';
    like $warnings[0], qr/upstream gone/,   'warning contains error text';
};

done_testing;
