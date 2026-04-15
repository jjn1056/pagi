#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use Future;

use lib 'lib';
use PAGI::SSE;

subtest 'on_close registers callback' => sub {
    my $sse = PAGI::SSE->new({ type => 'sse' }, sub {}, sub { Future->done });

    my $called = 0;
    $sse->on_close(sub { $called = 1 });

    ok(!$called, 'callback not called yet');
};

subtest 'run waits for disconnect and calls on_close' => sub {
    my @events = (
        { type => 'sse.disconnect' },
    );
    my $idx = 0;
    my $receive = sub { Future->done($events[$idx++]) };
    my $send = sub { Future->done };

    my $sse = PAGI::SSE->new({ type => 'sse' }, $receive, $send);
    $sse->start->get;

    my $cleanup_ran = 0;
    $sse->on_close(sub { $cleanup_ran = 1 });

    $sse->run->get;

    ok($cleanup_ran, 'on_close callback ran');
    ok($sse->is_closed, 'connection is closed');
};

subtest 'multiple on_close callbacks run in order' => sub {
    my @events = ({ type => 'sse.disconnect' });
    my $idx = 0;
    my $receive = sub { Future->done($events[$idx++]) };

    my $sse = PAGI::SSE->new({ type => 'sse' }, $receive, sub { Future->done });
    $sse->start->get;

    my @order;
    $sse->on_close(sub { push @order, 1 });
    $sse->on_close(sub { push @order, 2 });
    $sse->on_close(sub { push @order, 3 });

    $sse->run->get;

    is(\@order, [1, 2, 3], 'callbacks run in registration order');
};

subtest 'on_close works with async callbacks' => sub {
    my @events = ({ type => 'sse.disconnect' });
    my $idx = 0;
    my $receive = sub { Future->done($events[$idx++]) };

    my $sse = PAGI::SSE->new({ type => 'sse' }, $receive, sub { Future->done });
    $sse->start->get;

    my $async_ran = 0;
    $sse->on_close(async sub { $async_ran = 1 });

    $sse->run->get;

    ok($async_ran, 'async callback ran');
};

subtest 'close method sets closed state' => sub {
    my $sse = PAGI::SSE->new({ type => 'sse' }, sub {}, sub { Future->done });
    $sse->start->get;

    my $cleanup_ran = 0;
    $sse->on_close(sub { $cleanup_ran = 1 });

    $sse->close;

    ok($sse->is_closed, 'is_closed is true');
    ok($cleanup_ran, 'on_close ran on explicit close');
};

subtest 'callback arrays cleared after close (breaks cycles)' => sub {
    my @events = ({ type => 'sse.disconnect' });
    my $idx = 0;
    my $receive = sub { Future->done($events[$idx++]) };
    my $sse = PAGI::SSE->new({ type => 'sse' }, $receive, sub { Future->done });
    $sse->start->get;

    $sse->on_close(sub { 1 });
    $sse->on_error(sub { 1 });

    $sse->run->get;   # disconnect → fires + should clear callbacks

    is scalar @{$sse->{_on_close}}, 0, '_on_close array cleared after close';
    is scalar @{$sse->{_on_error}}, 0, '_on_error array cleared after close';
};

subtest 'SSE GCd after close when callback captured object' => sub {
    use Scalar::Util qw(weaken);
    my @events = ({ type => 'sse.disconnect' });
    my $idx = 0;
    my $receive = sub { Future->done($events[$idx++]) };

    my $weak;
    {
        my $sse = PAGI::SSE->new({ type => 'sse' }, $receive, sub { Future->done });
        weaken($weak = $sse);
        $sse->start->get;

        # Callback captures $sse — would leak without clearing
        $sse->on_close(sub { my $x = $sse });

        $sse->run->get;   # fires callbacks, clears array
    }   # lexical $sse drops here

    is $weak, undef, 'SSE GCd after close cleared callback cycle';
};

subtest 'on() dispatches to on_close' => sub {
    my @events = ({ type => 'sse.disconnect' });
    my $idx = 0;
    my $receive = sub { Future->done($events[$idx++]) };

    my $sse = PAGI::SSE->new({ type => 'sse' }, $receive, sub { Future->done });
    $sse->start->get;

    my $called = 0;
    $sse->on(close => sub { $called = 1 });

    $sse->run->get;

    ok $called, 'on(close) dispatched to on_close';
};

subtest 'on() dispatches to on_error' => sub {
    my $send = sub { Future->fail("boom") };
    my $sse = PAGI::SSE->new({ type => 'sse' }, sub {}, $send);
    $sse->_set_state('started');

    my $err_received;
    $sse->on(error => sub { $err_received = $_[1] });

    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, $_[0] };

    $sse->try_send("hello")->get;

    like $err_received, qr/boom/, 'on(error) dispatched to on_error';
};

subtest 'on() returns $self for chaining' => sub {
    my $sse = PAGI::SSE->new({ type => 'sse' }, sub {}, sub { Future->done });

    my $result = $sse->on(close => sub { });
    ok $result == $sse, 'on() returns $self';
};

subtest 'on() dies on unknown event' => sub {
    my $sse = PAGI::SSE->new({ type => 'sse' }, sub {}, sub { Future->done });

    like dies { $sse->on(unknown => sub { }) },
        qr/Unknown event type/i,
        'on() dies for unknown event name';
};

done_testing;
