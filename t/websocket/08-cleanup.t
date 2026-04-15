#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use Future;

use lib 'lib';
use PAGI::WebSocket;

subtest 'on_close callback runs on disconnect' => sub {
    my @events = (
        { type => 'websocket.connect' },
        { type => 'websocket.disconnect', code => 1000, reason => 'Bye' },
    );
    my $idx = 0;
    my $receive = sub { Future->done($events[$idx++]) };
    my $send = sub { Future->done };

    my $scope = { type => 'websocket', headers => [] };
    my $ws = PAGI::WebSocket->new($scope, $receive, $send);
    $ws->accept->get;

    my ($called_code, $called_reason);
    $ws->on_close(async sub {
        my ($code, $reason) = @_;
        $called_code = $code;
        $called_reason = $reason;
    });

    # Trigger disconnect
    $ws->receive->get;

    is($called_code, 1000, 'on_close received code');
    is($called_reason, 'Bye', 'on_close received reason');
};

subtest 'on_close runs after each_* loops' => sub {
    my @events = (
        { type => 'websocket.connect' },
        { type => 'websocket.receive', text => 'msg' },
        { type => 'websocket.disconnect', code => 1001 },
    );
    my $idx = 0;
    my $receive = sub { Future->done($events[$idx++]) };
    my $send = sub { Future->done };

    my $scope = { type => 'websocket', headers => [] };
    my $ws = PAGI::WebSocket->new($scope, $receive, $send);
    $ws->accept->get;

    my $cleanup_ran = 0;
    $ws->on_close(async sub { $cleanup_ran = 1 });

    $ws->each_text(async sub {})->get;

    ok($cleanup_ran, 'on_close ran after each_text');
};

subtest 'multiple on_close callbacks run in order' => sub {
    my @events = (
        { type => 'websocket.connect' },
        { type => 'websocket.disconnect', code => 1000 },
    );
    my $idx = 0;
    my $receive = sub { Future->done($events[$idx++]) };
    my $send = sub { Future->done };

    my $scope = { type => 'websocket', headers => [] };
    my $ws = PAGI::WebSocket->new($scope, $receive, $send);
    $ws->accept->get;

    my @order;
    $ws->on_close(async sub { push @order, 1 });
    $ws->on_close(async sub { push @order, 2 });
    $ws->on_close(async sub { push @order, 3 });

    $ws->receive->get;

    is(\@order, [1, 2, 3], 'callbacks run in registration order');
};

subtest 'on_close runs on explicit close()' => sub {
    my @events = (
        { type => 'websocket.connect' },
    );
    my $idx = 0;
    my $receive = sub { Future->done($events[$idx++]) };
    my $send = sub { Future->done };

    my $scope = { type => 'websocket', headers => [] };
    my $ws = PAGI::WebSocket->new($scope, $receive, $send);
    $ws->accept->get;

    my $cleanup_ran = 0;
    $ws->on_close(async sub { $cleanup_ran = 1 });

    $ws->close(1000, 'Goodbye')->get;

    ok($cleanup_ran, 'on_close ran on explicit close');
};

subtest 'on_close only runs once' => sub {
    my @events = (
        { type => 'websocket.connect' },
        { type => 'websocket.disconnect', code => 1000 },
    );
    my $idx = 0;
    my $receive = sub { Future->done($events[$idx++]) };
    my $send = sub { Future->done };

    my $scope = { type => 'websocket', headers => [] };
    my $ws = PAGI::WebSocket->new($scope, $receive, $send);
    $ws->accept->get;

    my $call_count = 0;
    $ws->on_close(async sub { $call_count++ });

    $ws->receive->get;    # triggers disconnect
    $ws->receive->get;    # already closed
    $ws->close->get;      # already closed

    is($call_count, 1, 'on_close only called once');
};

subtest 'on_close exception does not prevent other callbacks' => sub {
    my @events = (
        { type => 'websocket.connect' },
        { type => 'websocket.disconnect', code => 1000 },
    );
    my $idx = 0;
    my $receive = sub { Future->done($events[$idx++]) };
    my $send = sub { Future->done };

    my $scope = { type => 'websocket', headers => [] };
    my $ws = PAGI::WebSocket->new($scope, $receive, $send);
    $ws->accept->get;

    my $second_ran = 0;
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, $_[0] };

    $ws->on_close(async sub { die "First callback error" });
    $ws->on_close(async sub { $second_ran = 1 });

    # Should not die, should run second callback
    $ws->receive->get;

    ok($second_ran, 'second callback ran despite first dying');
    ok scalar @warnings, 'exception in on_close callback was warned';
    like $warnings[0], qr/First callback error/, 'warning contains error text';
};

subtest 'on_close works with sync callbacks' => sub {
    my @events = (
        { type => 'websocket.connect' },
        { type => 'websocket.disconnect', code => 1000, reason => 'Normal' },
    );
    my $idx = 0;
    my $receive = sub { Future->done($events[$idx++]) };
    my $send = sub { Future->done };

    my $scope = { type => 'websocket', headers => [] };
    my $ws = PAGI::WebSocket->new($scope, $receive, $send);
    $ws->accept->get;

    my ($sync_code, $sync_reason);
    my $async_ran = 0;

    # Mix of sync and async callbacks
    $ws->on_close(sub {
        my ($code, $reason) = @_;
        $sync_code = $code;
        $sync_reason = $reason;
    });
    $ws->on_close(async sub { $async_ran = 1 });

    $ws->receive->get;

    is($sync_code, 1000, 'sync callback received code');
    is($sync_reason, 'Normal', 'sync callback received reason');
    ok($async_ran, 'async callback also ran');
};

subtest 'async on_error callback is awaited' => sub {
    my @events = (
        { type => 'websocket.connect' },
        { type => 'websocket.receive', text => 'hello' },
        { type => 'websocket.disconnect', code => 1000 },
    );
    my $idx = 0;
    my $receive = sub { Future->done($events[$idx++]) };
    my $send    = sub { Future->done };
    my $scope   = { type => 'websocket', headers => [] };

    my $ws = PAGI::WebSocket->new($scope, $receive, $send);
    $ws->accept->get;

    my @fired;
    $ws->on_error(async sub { push @fired, 'async-error' });
    $ws->on_message(sub { die "message handler error\n" });

    $ws->run->get;

    is \@fired, ['async-error'], 'async on_error callback was awaited';
};

subtest 'async on_error exception does not prevent other callbacks' => sub {
    my @events = (
        { type => 'websocket.connect' },
        { type => 'websocket.receive', text => 'hello' },
        { type => 'websocket.disconnect', code => 1000 },
    );
    my $idx = 0;
    my $receive = sub { Future->done($events[$idx++]) };
    my $send    = sub { Future->done };
    my $scope   = { type => 'websocket', headers => [] };

    my $ws = PAGI::WebSocket->new($scope, $receive, $send);
    $ws->accept->get;

    my @fired;
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, $_[0] };

    # async die produces a failed Future — only caught if _trigger_error awaits
    $ws->on_error(async sub { die "async error handler exploded\n" });
    $ws->on_error(sub { push @fired, 'second' });
    $ws->on_message(sub { die "message error\n" });

    $ws->run->get;

    is \@fired, ['second'], 'second on_error ran despite async first dying';
    ok scalar @warnings, 'async exception in on_error callback was warned';
    like $warnings[0], qr/async error handler exploded/, 'warning contains error text';
};

subtest 'callback arrays cleared after close (breaks cycles)' => sub {
    my @events = (
        { type => 'websocket.connect' },
        { type => 'websocket.disconnect', code => 1000 },
    );
    my $idx = 0;
    my $receive = sub { Future->done($events[$idx++]) };
    my $send    = sub { Future->done };
    my $scope   = { type => 'websocket', headers => [] };

    my $ws = PAGI::WebSocket->new($scope, $receive, $send);
    $ws->accept->get;

    $ws->on_close(sub   { 1 });
    $ws->on_error(sub   { 1 });
    $ws->on_message(sub { 1 });

    $ws->receive->get;   # disconnect → fires + should clear callbacks

    is scalar @{$ws->{_on_close}},   0, '_on_close array cleared after close';
    is scalar @{$ws->{_on_error}},   0, '_on_error array cleared after close';
    is scalar @{$ws->{_on_message}}, 0, '_on_message array cleared after close';
};

subtest 'WebSocket GCd after close when callback captured object' => sub {
    use Scalar::Util qw(weaken);
    my @events = (
        { type => 'websocket.connect' },
        { type => 'websocket.disconnect', code => 1000 },
    );
    my $idx   = 0;
    my $receive = sub { Future->done($events[$idx++]) };
    my $send    = sub { Future->done };
    my $scope   = { type => 'websocket', headers => [] };

    my $weak;
    {
        my $ws = PAGI::WebSocket->new($scope, $receive, $send);
        weaken($weak = $ws);
        $ws->accept->get;

        # Callback captures $ws — would leak without clearing
        $ws->on_close(sub { my $x = $ws });

        $ws->receive->get;   # fires callbacks, clears array
    }   # lexical $ws drops here

    is $weak, undef, 'WebSocket GCd after close cleared callback cycle';
};

done_testing;
