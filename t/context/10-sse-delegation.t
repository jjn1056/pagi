#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use Future;

use lib 'lib';
use PAGI::Context;

# Helper: build an SSE context with spy send/receive
sub make_sse_ctx {
    my (%opts) = @_;

    my @sent;
    my $send = $opts{send} // sub { push @sent, $_[0]; Future->done };

    my $event_idx = 0;
    my @events = @{ $opts{events} // [] };
    my $receive = $opts{receive} // sub {
        my $e = $events[$event_idx++];
        return $e ? Future->done($e) : Future->done({ type => 'sse.disconnect' });
    };

    my $scope = {
        type         => 'sse',
        path         => $opts{path}         // '/events',
        headers      => $opts{headers}      // [],
        query_string => $opts{query_string} // '',
        scheme       => $opts{scheme}       // 'http',
        http_version => $opts{http_version} // '1.1',
        path_params  => $opts{path_params}  // {},
        %{ $opts{extra_scope} // {} },
    };

    my $ctx = PAGI::Context->new($scope, $receive, $send);
    return ($ctx, \@sent);
}

# ---------------------------------------------------------------------------
# Connection lifecycle delegation
# ---------------------------------------------------------------------------

subtest 'start delegates to sse' => sub {
    my ($ctx, $sent) = make_sse_ctx();

    (async sub { await $ctx->start })->()->get;

    is(scalar @$sent, 1, 'one event sent');
    is($sent->[0]{type}, 'sse.start', 'sent sse.start');
    is($sent->[0]{status}, 200, 'default status 200');
};

subtest 'start with options' => sub {
    my ($ctx, $sent) = make_sse_ctx();

    (async sub {
        await $ctx->start(status => 201, headers => [['x-custom', 'v']]);
    })->()->get;

    is($sent->[0]{status}, 201, 'custom status forwarded');
    is($sent->[0]{headers}, [['x-custom', 'v']], 'headers forwarded');
};

subtest 'close delegates' => sub {
    my ($ctx, $sent) = make_sse_ctx();

    (async sub { await $ctx->start })->()->get;
    $ctx->close;

    ok($ctx->is_closed, 'closed after close()');
};

# ---------------------------------------------------------------------------
# Send method delegation
# ---------------------------------------------------------------------------

subtest 'send delegates' => sub {
    my ($ctx, $sent) = make_sse_ctx();

    (async sub { await $ctx->send('hello') })->()->get;

    # start + send
    my @data_events = grep { $_->{type} eq 'sse.send' } @$sent;
    is(scalar @data_events, 1, 'one data event');
    is($data_events[0]{data}, 'hello', 'data forwarded');
};

subtest 'send_json delegates' => sub {
    my ($ctx, $sent) = make_sse_ctx();

    (async sub { await $ctx->send_json({ msg => 'hi' }) })->()->get;

    my @data_events = grep { $_->{type} eq 'sse.send' } @$sent;
    like($data_events[0]{data}, qr/"msg"/, 'JSON sent');
};

subtest 'send_event delegates' => sub {
    my ($ctx, $sent) = make_sse_ctx();

    (async sub {
        await $ctx->send_event(
            data  => { x => 1 },
            event => 'update',
            id    => '42',
            retry => 3000,
        );
    })->()->get;

    my @data_events = grep { $_->{type} eq 'sse.send' } @$sent;
    is($data_events[0]{event}, 'update', 'event type forwarded');
    is($data_events[0]{id}, '42', 'id forwarded');
    is($data_events[0]{retry}, 3000, 'retry forwarded');
};

subtest 'send_comment delegates' => sub {
    my ($ctx, $sent) = make_sse_ctx();

    (async sub {
        await $ctx->start;
        await $ctx->send_comment('ping');
    })->()->get;

    my @comments = grep { $_->{type} eq 'sse.comment' } @$sent;
    is(scalar @comments, 1, 'comment sent');
    is($comments[0]{comment}, 'ping', 'comment text forwarded');
};

subtest 'try_send delegates' => sub {
    my ($ctx, $sent) = make_sse_ctx();

    my $ok;
    (async sub {
        await $ctx->start;
        $ok = await $ctx->try_send('safe');
    })->()->get;

    ok($ok, 'try_send returned true');
};

subtest 'try_send_json delegates' => sub {
    my ($ctx, $sent) = make_sse_ctx();

    my $ok;
    (async sub {
        await $ctx->start;
        $ok = await $ctx->try_send_json({ ok => 1 });
    })->()->get;

    ok($ok, 'try_send_json returned true');
};

subtest 'try_send_comment delegates' => sub {
    my ($ctx, $sent) = make_sse_ctx();

    my $ok;
    (async sub {
        await $ctx->start;
        $ok = await $ctx->try_send_comment('keepalive');
    })->()->get;

    ok($ok, 'try_send_comment returned true');
};

subtest 'try_send_event delegates' => sub {
    my ($ctx, $sent) = make_sse_ctx();

    my $ok;
    (async sub {
        await $ctx->start;
        $ok = await $ctx->try_send_event(data => 'test', event => 'ping');
    })->()->get;

    ok($ok, 'try_send_event returned true');
};

# ---------------------------------------------------------------------------
# State inspection delegation
# ---------------------------------------------------------------------------

subtest 'is_started delegates' => sub {
    my ($ctx) = make_sse_ctx();

    ok(!$ctx->is_started, 'not started initially');

    (async sub { await $ctx->start })->()->get;

    ok($ctx->is_started, 'started after start()');
};

subtest 'is_closed delegates' => sub {
    my ($ctx) = make_sse_ctx();

    ok(!$ctx->is_closed, 'not closed initially');

    (async sub { await $ctx->start })->()->get;
    $ctx->close;

    ok($ctx->is_closed, 'closed after close()');
};

subtest 'last_event_id delegates' => sub {
    my ($ctx) = make_sse_ctx(headers => [['last-event-id', 'evt-99']]);

    is($ctx->last_event_id, 'evt-99', 'last_event_id from header');
};

subtest 'keepalive delegates' => sub {
    my ($ctx, $sent) = make_sse_ctx();

    (async sub { await $ctx->keepalive(25, 'ping') })->()->get;

    my @ka = grep { $_->{type} eq 'sse.keepalive' } @$sent;
    is(scalar @ka, 1, 'keepalive event sent');
    is($ka[0]{interval}, 25, 'interval forwarded');
    is($ka[0]{comment}, 'ping', 'comment forwarded');
};

# ---------------------------------------------------------------------------
# Query param delegation
# ---------------------------------------------------------------------------

subtest 'query_param delegates' => sub {
    my ($ctx) = make_sse_ctx(query_string => 'channel=news&format=json');

    is($ctx->query_param('channel'), 'news', 'query_param works');
    is($ctx->query_param('format'), 'json', 'second param');
    is($ctx->query_param('missing'), undef, 'missing returns undef');
};

subtest 'query_params delegates' => sub {
    my ($ctx) = make_sse_ctx(query_string => 'a=1&b=2');

    my $params = $ctx->query_params;
    isa_ok($params, 'Hash::MultiValue');
    is($params->get('a'), '1', 'param a');
};

subtest 'raw_query_param delegates' => sub {
    my ($ctx) = make_sse_ctx(query_string => 'name=%C3%A9');

    my $raw = $ctx->raw_query_param('name');
    ok(defined $raw, 'raw_query_param returns value');
};

subtest 'raw_query_params delegates' => sub {
    my ($ctx) = make_sse_ctx(query_string => 'x=1');

    my $params = $ctx->raw_query_params;
    isa_ok($params, 'Hash::MultiValue');
};

# ---------------------------------------------------------------------------
# Header extras / protocol metadata delegation
# ---------------------------------------------------------------------------

subtest 'header_all delegates' => sub {
    my ($ctx) = make_sse_ctx(headers => [
        ['accept', 'text/event-stream'],
        ['accept', 'text/html'],
    ]);

    my @accepts = $ctx->header_all('accept');
    is(scalar @accepts, 2, 'header_all returns all values');
};

subtest 'http_version delegates' => sub {
    my ($ctx) = make_sse_ctx(http_version => '2');
    is($ctx->http_version, '2', 'http_version forwarded');
};

# ---------------------------------------------------------------------------
# Iteration delegation
# ---------------------------------------------------------------------------

subtest 'each delegates' => sub {
    my ($ctx, $sent) = make_sse_ctx();
    my @items = ({ n => 1 }, { n => 2 });

    (async sub {
        await $ctx->each(\@items, async sub {
            my ($item) = @_;
            await $ctx->send_json($item);
        });
    })->()->get;

    my @data_events = grep { $_->{type} eq 'sse.send' } @$sent;
    is(scalar @data_events, 2, 'two events sent from each');
};

# ---------------------------------------------------------------------------
# Context dispatcher NOT shadowed
# ---------------------------------------------------------------------------

subtest 'on() is Context dispatcher, not SSE on()' => sub {
    my @events_received;
    my ($ctx) = make_sse_ctx(events => [
        { type => 'custom.notification', payload => 'alert' },
        { type => 'sse.disconnect' },
    ]);

    $ctx->on('custom.notification', sub {
        my ($c, $event) = @_;
        push @events_received, $event;
    });

    my $reason = (async sub { return await $ctx->run })->()->get;

    is(scalar @events_received, 1, 'custom event dispatched');
    is($events_received[0]{payload}, 'alert', 'event data correct');
    is($reason, 'disconnect', 'run terminated on disconnect');
};

subtest 'on_error() is Context dispatcher, not SSE on_error()' => sub {
    my @errors;
    my ($ctx) = make_sse_ctx(
        receive => sub { Future->fail("stream died") },
    );

    $ctx->on_error(sub {
        my ($c, $err, $source) = @_;
        push @errors, { err => $err, source => $source };
    });

    my $reason = (async sub { return await $ctx->run })->()->get;

    is($reason, 'error', 'run returned error reason');
    like($errors[0]{err}, qr/stream died/, 'error text');
    is($errors[0]{source}, 'receive', 'source is receive');
};

subtest 'run() is Context dispatcher, not SSE run()' => sub {
    my @types_seen;
    my ($ctx) = make_sse_ctx(events => [
        { type => 'metrics.update', value => 42 },
        { type => 'sse.disconnect' },
    ]);

    $ctx->on('metrics.update', sub { push @types_seen, 'metrics' });

    my $reason = (async sub { return await $ctx->run })->()->get;

    is(\@types_seen, ['metrics'], 'custom event type dispatched');
    is($reason, 'disconnect', 'terminated on protocol disconnect');
};

# ---------------------------------------------------------------------------
# sse() accessor still works
# ---------------------------------------------------------------------------

subtest 'sse() still returns underlying object' => sub {
    my ($ctx) = make_sse_ctx();

    my $sse = $ctx->sse;
    isa_ok($sse, 'PAGI::SSE');

    (async sub { await $sse->start })->()->get;
    ok($sse->is_started, 'direct SSE start works');
};

done_testing;
