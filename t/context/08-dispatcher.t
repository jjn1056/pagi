#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use Future;
use Scalar::Util qw(blessed);

use lib 'lib';
use PAGI::Context;

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

sub ws_ctx {
    my @events = @_;
    my $idx = 0;
    my $receive = sub { Future->done($events[$idx++]) };
    return PAGI::Context->new(
        { type => 'websocket', path => '/ws', headers => [] },
        $receive,
        sub { Future->done },
    );
}

sub sse_ctx {
    my @events = @_;
    my $idx = 0;
    my $receive = sub { Future->done($events[$idx++]) };
    return PAGI::Context->new(
        { type => 'sse', path => '/events', headers => [] },
        $receive,
        sub { Future->done },
    );
}

# ---------------------------------------------------------------------------
# on() registration
# ---------------------------------------------------------------------------

subtest 'on() returns $self for chaining' => sub {
    my $ctx = ws_ctx({ type => 'websocket.disconnect' });
    my $ret = $ctx->on('websocket.receive' => sub {});
    ok $ret == $ctx, 'on() returns $self';

    # Full chain
    my $ret2 = $ctx->on('foo' => sub {})->on('bar' => sub {});
    ok $ret2 == $ctx, 'chained on() returns $self';
};

subtest 'on() handler receives ($ctx, $event)' => sub {
    my $event = { type => 'websocket.receive', text => 'hello' };
    my $ctx = ws_ctx($event, { type => 'websocket.disconnect' });

    my ($got_ctx, $got_event);
    $ctx->on('websocket.receive' => sub {
        ($got_ctx, $got_event) = @_;
    });

    $ctx->run->get;

    ok $got_ctx == $ctx,          'first arg is $ctx';
    is $got_event->{text}, 'hello', 'second arg is $event';
};

subtest 'multiple handlers for same type run in registration order' => sub {
    my $ctx = ws_ctx(
        { type => 'custom.event' },
        { type => 'websocket.disconnect' },
    );

    my @order;
    $ctx->on('custom.event' => sub { push @order, 1 });
    $ctx->on('custom.event' => sub { push @order, 2 });
    $ctx->on('custom.event' => sub { push @order, 3 });

    $ctx->run->get;

    is \@order, [1, 2, 3], 'handlers ran in registration order';
};

# ---------------------------------------------------------------------------
# run() return values
# ---------------------------------------------------------------------------

subtest 'run() returns disconnect on websocket.disconnect' => sub {
    my $ctx = ws_ctx({ type => 'websocket.disconnect' });
    my $reason = $ctx->run->get;
    is $reason, 'disconnect', 'reason is disconnect';
};

subtest 'run() returns disconnect on sse.disconnect' => sub {
    my $ctx = sse_ctx({ type => 'sse.disconnect' });
    my $reason = $ctx->run->get;
    is $reason, 'disconnect', 'reason is disconnect';
};

subtest 'run() returns stop when stop() called from handler' => sub {
    my $ctx = ws_ctx(
        { type => 'custom.event' },
        { type => 'websocket.disconnect' },
    );

    $ctx->on('custom.event' => sub { $_[0]->stop });

    my $reason = $ctx->run->get;
    is $reason, 'stop', 'reason is stop';
};

subtest 'run() returns error when receive fails' => sub {
    my $receive = sub { Future->fail("connection reset") };
    my $ctx = PAGI::Context->new(
        { type => 'websocket', path => '/ws', headers => [] },
        $receive,
        sub { Future->done },
    );

    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, $_[0] };

    my $reason = $ctx->run->get;
    is $reason, 'error', 'reason is error';
};

# ---------------------------------------------------------------------------
# Auto-terminate
# ---------------------------------------------------------------------------

subtest 'auto-terminate on disconnect without registered handler' => sub {
    my $ctx = ws_ctx(
        { type => 'websocket.disconnect' },
    );
    # No handler registered for disconnect — loop should still exit
    my $reason = $ctx->run->get;
    is $reason, 'disconnect', 'loop exited without registered handler';
};

subtest 'registered handler for disconnect fires before exit' => sub {
    my $fired = 0;
    my $ctx = ws_ctx({ type => 'websocket.disconnect', code => 1000 });

    $ctx->on('websocket.disconnect' => sub { $fired = 1 });

    $ctx->run->get;
    ok $fired, 'disconnect handler fired before exit';
};

subtest 'events before disconnect are dispatched first' => sub {
    my $ctx = ws_ctx(
        { type => 'chat.message', text => 'hi' },
        { type => 'chat.message', text => 'bye' },
        { type => 'websocket.disconnect' },
    );

    my @texts;
    $ctx->on('chat.message' => sub { push @texts, $_[1]{text} });

    $ctx->run->get;

    is \@texts, ['hi', 'bye'], 'all events before disconnect dispatched';
};

# ---------------------------------------------------------------------------
# stop()
# ---------------------------------------------------------------------------

subtest 'stop() does not fire handlers for subsequent events' => sub {
    my $ctx = ws_ctx(
        { type => 'first' },
        { type => 'second' },
        { type => 'websocket.disconnect' },
    );

    my @fired;
    $ctx->on('first'  => sub { push @fired, 'first'; $_[0]->stop });
    $ctx->on('second' => sub { push @fired, 'second' });

    $ctx->run->get;

    is \@fired, ['first'], 'second event not dispatched after stop()';
};

# ---------------------------------------------------------------------------
# on_error
# ---------------------------------------------------------------------------

subtest 'on_error fires on receive failure with source=receive' => sub {
    my $receive = sub { Future->fail("socket gone") };
    my $ctx = PAGI::Context->new(
        { type => 'websocket', path => '/ws', headers => [] },
        $receive,
        sub { Future->done },
    );

    my ($got_ctx, $got_err, $got_src);
    $ctx->on_error(sub { ($got_ctx, $got_err, $got_src) = @_ });

    $ctx->run->get;

    ok $got_ctx == $ctx,              'on_error received $ctx';
    like $got_err, qr/socket gone/,   'on_error received error';
    is $got_src, 'receive',           'source is receive';
};

subtest 'on_error fires on handler exception with source=handler' => sub {
    my $ctx = ws_ctx(
        { type => 'boom.event' },
        { type => 'websocket.disconnect' },
    );

    my ($got_err, $got_src);
    $ctx->on_error(sub { (undef, $got_err, $got_src) = @_ });
    $ctx->on('boom.event' => sub { die "handler exploded\n" });

    $ctx->run->get;

    like $got_err, qr/handler exploded/, 'on_error received handler error';
    is $got_src, 'handler',              'source is handler';
};

subtest 'on_error returns $self for chaining' => sub {
    my $ctx = ws_ctx({ type => 'websocket.disconnect' });
    my $ret = $ctx->on_error(sub {});
    ok $ret == $ctx, 'on_error returns $self';
};

subtest 'multiple on_error callbacks run in order' => sub {
    my $receive = sub { Future->fail("oops") };
    my $ctx = PAGI::Context->new(
        { type => 'websocket', path => '/ws', headers => [] },
        $receive, sub { Future->done },
    );

    my @order;
    $ctx->on_error(sub { push @order, 1 });
    $ctx->on_error(sub { push @order, 2 });

    $ctx->run->get;

    is \@order, [1, 2], 'on_error callbacks ran in order';
};

subtest 'on_error falls back to warn when not registered (receive)' => sub {
    my $receive = sub { Future->fail("unhandled failure") };
    my $ctx = PAGI::Context->new(
        { type => 'websocket', path => '/ws', headers => [] },
        $receive, sub { Future->done },
    );

    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, $_[0] };

    $ctx->run->get;

    ok scalar @warnings,                  'fallback warn fired';
    like $warnings[0], qr/unhandled failure/, 'warn contains error text';
};

subtest 'on_error falls back to warn when not registered (handler)' => sub {
    my $ctx = ws_ctx(
        { type => 'exploding' },
        { type => 'websocket.disconnect' },
    );

    $ctx->on('exploding' => sub { die "kaboom\n" });

    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, $_[0] };

    $ctx->run->get;

    ok scalar @warnings,           'fallback warn fired';
    like $warnings[0], qr/kaboom/, 'warn contains error text';
};

subtest 'exception in on_error callback does not prevent others' => sub {
    my $receive = sub { Future->fail("fail") };
    my $ctx = PAGI::Context->new(
        { type => 'websocket', path => '/ws', headers => [] },
        $receive, sub { Future->done },
    );

    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, $_[0] };

    my $second_ran = 0;
    $ctx->on_error(sub { die "on_error exploded\n" });
    $ctx->on_error(sub { $second_ran = 1 });

    $ctx->run->get;

    ok $second_ran,                          'second on_error ran';
    ok scalar @warnings,                     'first on_error exception was warned';
};

subtest 'handler exception does not stop the loop' => sub {
    my $ctx = ws_ctx(
        { type => 'first' },
        { type => 'second' },
        { type => 'websocket.disconnect' },
    );

    my @fired;
    $ctx->on('first'  => sub { push @fired, 'first'; die "oops\n" });
    $ctx->on('second' => sub { push @fired, 'second' });

    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, $_[0] };

    $ctx->run->get;

    is \@fired, ['first', 'second'], 'loop continued after handler exception';
};

# ---------------------------------------------------------------------------
# Async handlers
# ---------------------------------------------------------------------------

subtest 'async handlers are awaited' => sub {
    my $ctx = ws_ctx(
        { type => 'async.event' },
        { type => 'websocket.disconnect' },
    );

    my @fired;
    $ctx->on('async.event' => async sub { push @fired, 'async-ran' });

    $ctx->run->get;

    is \@fired, ['async-ran'], 'async handler was awaited';
};

subtest 'async on_error callbacks are awaited' => sub {
    my $receive = sub { Future->fail("async fail") };
    my $ctx = PAGI::Context->new(
        { type => 'websocket', path => '/ws', headers => [] },
        $receive, sub { Future->done },
    );

    my @fired;
    $ctx->on_error(async sub { push @fired, 'async-error-ran' });

    $ctx->run->get;

    is \@fired, ['async-error-ran'], 'async on_error was awaited';
};

subtest 'async on_error exception does not prevent other callbacks' => sub {
    my $receive = sub { Future->fail("fail") };
    my $ctx = PAGI::Context->new(
        { type => 'websocket', path => '/ws', headers => [] },
        $receive, sub { Future->done },
    );

    my @fired;
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, $_[0] };

    $ctx->on_error(async sub { die "async on_error exploded\n" });
    $ctx->on_error(sub { push @fired, 'second' });

    $ctx->run->get;

    is \@fired, ['second'],                       'second on_error ran';
    ok scalar @warnings,                          'async exception was warned';
    like $warnings[0], qr/async on_error exploded/, 'warning contains error text';
};

# ---------------------------------------------------------------------------
# Re-entrancy guard
# ---------------------------------------------------------------------------

subtest 'run() croaks if called while already running' => sub {
    # We can't easily test this with a truly concurrent second call in
    # synchronous test mode, so we set the flag directly and verify.
    my $ctx = ws_ctx({ type => 'websocket.disconnect' });
    $ctx->{_running} = 1;

    like dies { $ctx->run->get }, qr/already running/i, 'second run() croaks';

    $ctx->{_running} = 0;    # clean up
};

# ---------------------------------------------------------------------------
# Snapshot safety
# ---------------------------------------------------------------------------

subtest 'on() called from within handler does not affect current iteration' => sub {
    my $ctx = ws_ctx(
        { type => 'first' },
        { type => 'websocket.disconnect' },
    );

    my @fired;
    $ctx->on('first' => sub {
        push @fired, 'original';
        # Register a new handler mid-dispatch — must NOT fire this iteration
        $_[0]->on('first' => sub { push @fired, 'late-added' });
    });

    $ctx->run->get;

    is \@fired, ['original'], 'late-added handler did not fire in same iteration';
};

# ---------------------------------------------------------------------------
# Unhandled events
# ---------------------------------------------------------------------------

subtest 'unhandled event types silently ignored' => sub {
    my $ctx = ws_ctx(
        { type => 'nobody.cares' },
        { type => 'websocket.disconnect' },
    );

    # No warning, no die — should complete cleanly
    my $reason = $ctx->run->get;
    is $reason, 'disconnect', 'loop completed normally with unhandled event';
};

subtest 'PAGI_DEBUG warns on unhandled non-terminal events' => sub {
    local $ENV{PAGI_DEBUG} = 1;

    my $ctx = ws_ctx(
        { type => 'unhandled.type' },
        { type => 'websocket.disconnect' },
    );

    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, $_[0] };

    $ctx->run->get;

    ok scalar @warnings,                          'debug warn fired';
    like $warnings[0], qr/unhandled.type/, 'warn names the event type';
};

subtest 'PAGI_DEBUG does not warn for terminal event without handler' => sub {
    local $ENV{PAGI_DEBUG} = 1;

    my $ctx = ws_ctx({ type => 'websocket.disconnect' });

    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, $_[0] };

    $ctx->run->get;

    ok !scalar @warnings, 'no warning for unhandled terminal event';
};

# ---------------------------------------------------------------------------
# Callback clearing (cycle-breaking)
# ---------------------------------------------------------------------------

subtest 'handler table cleared after loop exits' => sub {
    my $ctx = ws_ctx({ type => 'websocket.disconnect' });
    $ctx->on('foo' => sub { 1 });
    $ctx->on_error(sub { 1 });

    $ctx->run->get;

    is scalar keys %{ $ctx->{_handlers} },  0, '_handlers cleared';
    is scalar @{ $ctx->{_on_error} },        0, '_on_error cleared';
};

subtest 'context GCd after run() when handler captured object' => sub {
    use Scalar::Util qw(weaken);

    my $weak;
    {
        my $ctx = ws_ctx({ type => 'websocket.disconnect' });
        weaken($weak = $ctx);

        # Callback captures $ctx — would leak without clearing
        $ctx->on('websocket.disconnect' => sub { my $x = $ctx });

        $ctx->run->get;
    }

    is $weak, undef, 'context GCd after run() cleared callback cycle';
};

done_testing;
