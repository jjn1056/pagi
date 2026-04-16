#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use Future;

use lib 'lib';
use PAGI::Context;

# Helper: build a WebSocket context with spy send/receive
sub make_ws_ctx {
    my (%opts) = @_;

    my @sent;
    my $send = $opts{send} // sub { push @sent, $_[0]; Future->done };

    my $event_idx = 0;
    my @events = @{ $opts{events} // [{ type => 'websocket.connect' }] };
    my $receive = $opts{receive} // sub {
        my $e = $events[$event_idx++];
        return $e ? Future->done($e) : Future->done({ type => 'websocket.disconnect' });
    };

    my $scope = {
        type         => 'websocket',
        path         => $opts{path}         // '/ws',
        headers      => $opts{headers}      // [],
        query_string => $opts{query_string} // '',
        scheme       => $opts{scheme}       // 'ws',
        http_version => $opts{http_version} // '1.1',
        subprotocols => $opts{subprotocols} // [],
        path_params  => $opts{path_params}  // {},
        %{ $opts{extra_scope} // {} },
    };

    my $ctx = PAGI::Context->new($scope, $receive, $send);
    return ($ctx, \@sent);
}

# ---------------------------------------------------------------------------
# Connection lifecycle delegation
# ---------------------------------------------------------------------------

subtest 'accept delegates to ws' => sub {
    my ($ctx, $sent) = make_ws_ctx();

    (async sub { await $ctx->accept })->()->get;

    is(scalar @$sent, 1, 'one event sent');
    is($sent->[0]{type}, 'websocket.accept', 'sent websocket.accept');
};

subtest 'accept with subprotocol' => sub {
    my ($ctx, $sent) = make_ws_ctx(subprotocols => ['chat', 'json']);

    (async sub { await $ctx->accept(subprotocol => 'chat') })->()->get;

    is($sent->[0]{subprotocol}, 'chat', 'subprotocol forwarded');
};

subtest 'accept with headers' => sub {
    my ($ctx, $sent) = make_ws_ctx();

    (async sub {
        await $ctx->accept(headers => [['x-custom', 'val']]);
    })->()->get;

    is($sent->[0]{headers}, [['x-custom', 'val']], 'headers forwarded');
};

subtest 'close delegates to ws' => sub {
    my ($ctx, $sent) = make_ws_ctx();

    (async sub {
        await $ctx->accept;
        await $ctx->close;
    })->()->get;

    my @close_events = grep { $_->{type} eq 'websocket.close' } @$sent;
    is(scalar @close_events, 1, 'close event sent');
    is($close_events[0]{code}, 1000, 'default close code');
};

subtest 'close with code and reason' => sub {
    my ($ctx, $sent) = make_ws_ctx();

    (async sub {
        await $ctx->accept;
        await $ctx->close(4000, 'Custom reason');
    })->()->get;

    my @close_events = grep { $_->{type} eq 'websocket.close' } @$sent;
    is($close_events[0]{code}, 4000, 'custom close code');
    is($close_events[0]{reason}, 'Custom reason', 'custom close reason');
    is($ctx->close_code, 4000, 'close_code accessor');
    is($ctx->close_reason, 'Custom reason', 'close_reason accessor');
};

# ---------------------------------------------------------------------------
# Send method delegation
# ---------------------------------------------------------------------------

subtest 'send_text delegates' => sub {
    my ($ctx, $sent) = make_ws_ctx();

    (async sub {
        await $ctx->accept;
        await $ctx->send_text('hello');
    })->()->get;

    my @send_events = grep { $_->{type} eq 'websocket.send' } @$sent;
    is($send_events[0]{text}, 'hello', 'text forwarded');
};

subtest 'send_bytes delegates' => sub {
    my ($ctx, $sent) = make_ws_ctx();

    (async sub {
        await $ctx->accept;
        await $ctx->send_bytes("\x00\x01");
    })->()->get;

    my @send_events = grep { $_->{type} eq 'websocket.send' } @$sent;
    is($send_events[0]{bytes}, "\x00\x01", 'bytes forwarded');
};

subtest 'send_json delegates' => sub {
    my ($ctx, $sent) = make_ws_ctx();

    (async sub {
        await $ctx->accept;
        await $ctx->send_json({ msg => 'hi' });
    })->()->get;

    my @send_events = grep { $_->{type} eq 'websocket.send' } @$sent;
    like($send_events[0]{text}, qr/"msg"/, 'JSON sent');
};

subtest 'try_send_text delegates' => sub {
    my ($ctx, $sent) = make_ws_ctx();

    my $ok;
    (async sub {
        await $ctx->accept;
        $ok = await $ctx->try_send_text('safe');
    })->()->get;

    ok($ok, 'try_send_text returned true');
    my @send_events = grep { $_->{type} eq 'websocket.send' } @$sent;
    is($send_events[0]{text}, 'safe', 'text forwarded');
};

subtest 'try_send_bytes delegates' => sub {
    my ($ctx, $sent) = make_ws_ctx();

    my $ok;
    (async sub {
        await $ctx->accept;
        $ok = await $ctx->try_send_bytes("\xFF");
    })->()->get;

    ok($ok, 'try_send_bytes returned true');
};

subtest 'try_send_json delegates' => sub {
    my ($ctx, $sent) = make_ws_ctx();

    my $ok;
    (async sub {
        await $ctx->accept;
        $ok = await $ctx->try_send_json({ ok => 1 });
    })->()->get;

    ok($ok, 'try_send_json returned true');
};

subtest 'send_text_if_connected delegates' => sub {
    my ($ctx, $sent) = make_ws_ctx();

    (async sub {
        await $ctx->accept;
        await $ctx->send_text_if_connected('maybe');
    })->()->get;

    my @send_events = grep { $_->{type} eq 'websocket.send' } @$sent;
    is($send_events[0]{text}, 'maybe', 'text forwarded when connected');
};

subtest 'send_bytes_if_connected delegates' => sub {
    my ($ctx, $sent) = make_ws_ctx();

    (async sub {
        await $ctx->accept;
        await $ctx->send_bytes_if_connected("\xAB");
    })->()->get;

    my @send_events = grep { $_->{type} eq 'websocket.send' } @$sent;
    ok(scalar @send_events, 'bytes sent when connected');
};

subtest 'send_json_if_connected delegates' => sub {
    my ($ctx, $sent) = make_ws_ctx();

    (async sub {
        await $ctx->accept;
        await $ctx->send_json_if_connected({ x => 1 });
    })->()->get;

    my @send_events = grep { $_->{type} eq 'websocket.send' } @$sent;
    ok(scalar @send_events, 'json sent when connected');
};

# ---------------------------------------------------------------------------
# Receive method delegation
# ---------------------------------------------------------------------------

subtest 'receive_text delegates' => sub {
    my ($ctx, $sent) = make_ws_ctx(events => [
        { type => 'websocket.connect' },
        { type => 'websocket.receive', text => 'hello' },
        { type => 'websocket.disconnect' },
    ]);

    my $text;
    (async sub {
        await $ctx->accept;
        $text = await $ctx->receive_text;
    })->()->get;

    is($text, 'hello', 'receive_text works');
};

subtest 'receive_bytes delegates' => sub {
    my ($ctx, $sent) = make_ws_ctx(events => [
        { type => 'websocket.connect' },
        { type => 'websocket.receive', bytes => "\xDE\xAD" },
        { type => 'websocket.disconnect' },
    ]);

    my $bytes;
    (async sub {
        await $ctx->accept;
        $bytes = await $ctx->receive_bytes;
    })->()->get;

    is($bytes, "\xDE\xAD", 'receive_bytes works');
};

subtest 'receive_json delegates' => sub {
    my ($ctx, $sent) = make_ws_ctx(events => [
        { type => 'websocket.connect' },
        { type => 'websocket.receive', text => '{"key":"val"}' },
        { type => 'websocket.disconnect' },
    ]);

    my $data;
    (async sub {
        await $ctx->accept;
        $data = await $ctx->receive_json;
    })->()->get;

    is($data, { key => 'val' }, 'receive_json works');
};

# ---------------------------------------------------------------------------
# Iteration delegation
# ---------------------------------------------------------------------------

subtest 'each_message delegates' => sub {
    my ($ctx, $sent) = make_ws_ctx(events => [
        { type => 'websocket.connect' },
        { type => 'websocket.receive', text => 'a' },
        { type => 'websocket.receive', text => 'b' },
        { type => 'websocket.disconnect' },
    ]);

    my @msgs;
    (async sub {
        await $ctx->accept;
        await $ctx->each_message(async sub { push @msgs, $_[0] });
    })->()->get;

    is(scalar @msgs, 2, 'two messages received');
    is($msgs[0]{text}, 'a', 'first message');
    is($msgs[1]{text}, 'b', 'second message');
};

subtest 'each_text delegates' => sub {
    my ($ctx, $sent) = make_ws_ctx(events => [
        { type => 'websocket.connect' },
        { type => 'websocket.receive', text => 'x' },
        { type => 'websocket.receive', text => 'y' },
        { type => 'websocket.disconnect' },
    ]);

    my @texts;
    (async sub {
        await $ctx->accept;
        await $ctx->each_text(async sub { push @texts, $_[0] });
    })->()->get;

    is(\@texts, ['x', 'y'], 'each_text got all texts');
};

subtest 'each_bytes delegates' => sub {
    my ($ctx, $sent) = make_ws_ctx(events => [
        { type => 'websocket.connect' },
        { type => 'websocket.receive', bytes => 'bin1' },
        { type => 'websocket.disconnect' },
    ]);

    my @chunks;
    (async sub {
        await $ctx->accept;
        await $ctx->each_bytes(async sub { push @chunks, $_[0] });
    })->()->get;

    is(\@chunks, ['bin1'], 'each_bytes got chunk');
};

subtest 'each_json delegates' => sub {
    my ($ctx, $sent) = make_ws_ctx(events => [
        { type => 'websocket.connect' },
        { type => 'websocket.receive', text => '{"n":1}' },
        { type => 'websocket.disconnect' },
    ]);

    my @objs;
    (async sub {
        await $ctx->accept;
        await $ctx->each_json(async sub { push @objs, $_[0] });
    })->()->get;

    is($objs[0], { n => 1 }, 'each_json decoded');
};

# ---------------------------------------------------------------------------
# State inspection delegation
# ---------------------------------------------------------------------------

subtest 'is_connected uses WS state (not base class)' => sub {
    my ($ctx, $sent) = make_ws_ctx();

    # Before accept: WS state is 'connecting', base would check pagi.connection
    ok(!$ctx->is_connected, 'not connected before accept');

    (async sub { await $ctx->accept })->()->get;

    ok($ctx->is_connected, 'connected after accept');

    (async sub { await $ctx->close })->()->get;

    ok(!$ctx->is_connected, 'not connected after close');
};

subtest 'is_closed delegates' => sub {
    my ($ctx, $sent) = make_ws_ctx();

    ok(!$ctx->is_closed, 'not closed initially');

    (async sub {
        await $ctx->accept;
        await $ctx->close;
    })->()->get;

    ok($ctx->is_closed, 'closed after close()');
};

subtest 'subprotocols delegates' => sub {
    my ($ctx) = make_ws_ctx(subprotocols => ['chat', 'json']);
    is($ctx->subprotocols, ['chat', 'json'], 'subprotocols forwarded');
};

subtest 'keepalive delegates' => sub {
    my ($ctx, $sent) = make_ws_ctx();

    (async sub { await $ctx->keepalive(30, 10) })->()->get;

    my @ka = grep { $_->{type} eq 'websocket.keepalive' } @$sent;
    is(scalar @ka, 1, 'keepalive event sent');
    is($ka[0]{interval}, 30, 'interval forwarded');
    is($ka[0]{timeout}, 10, 'timeout forwarded');
};

# ---------------------------------------------------------------------------
# Query param delegation
# ---------------------------------------------------------------------------

subtest 'query delegates' => sub {
    my ($ctx) = make_ws_ctx(query_string => 'user=alice&room=general');

    is($ctx->query('user'), 'alice', 'query single param');
    is($ctx->query('room'), 'general', 'query second param');
    is($ctx->query('missing'), undef, 'query missing param');
};

subtest 'query_params delegates' => sub {
    my ($ctx) = make_ws_ctx(query_string => 'a=1&b=2');

    my $params = $ctx->query_params;
    isa_ok($params, 'Hash::MultiValue');
    is($params->get('a'), '1', 'param a');
    is($params->get('b'), '2', 'param b');
};

subtest 'raw_query delegates' => sub {
    my ($ctx) = make_ws_ctx(query_string => 'name=%C3%A9');

    my $raw = $ctx->raw_query('name');
    # Raw should be URL-decoded but not UTF-8 decoded
    ok(defined $raw, 'raw_query returns value');
};

subtest 'raw_query_params delegates' => sub {
    my ($ctx) = make_ws_ctx(query_string => 'x=1');

    my $params = $ctx->raw_query_params;
    isa_ok($params, 'Hash::MultiValue');
};

# ---------------------------------------------------------------------------
# Header extras delegation
# ---------------------------------------------------------------------------

subtest 'header_all delegates' => sub {
    my ($ctx) = make_ws_ctx(headers => [
        ['cookie', 'a=1'],
        ['cookie', 'b=2'],
        ['host', 'example.com'],
    ]);

    my @cookies = $ctx->header_all('cookie');
    is(scalar @cookies, 2, 'header_all returns all values');
    is($cookies[0], 'a=1', 'first cookie');
    is($cookies[1], 'b=2', 'second cookie');
};

subtest 'http_version delegates' => sub {
    my ($ctx) = make_ws_ctx(http_version => '2');
    is($ctx->http_version, '2', 'http_version forwarded');
};

# ---------------------------------------------------------------------------
# Context dispatcher NOT shadowed
# ---------------------------------------------------------------------------

subtest 'on() is Context dispatcher, not WS on()' => sub {
    my @events_received;
    my ($ctx) = make_ws_ctx(events => [
        { type => 'custom.event', data => 'test' },
        { type => 'websocket.disconnect' },
    ]);

    # Context on() accepts arbitrary event type strings
    $ctx->on('custom.event', sub {
        my ($c, $event) = @_;
        push @events_received, $event;
    });

    my $reason = (async sub { return await $ctx->run })->()->get;

    is(scalar @events_received, 1, 'custom event dispatched');
    is($events_received[0]{data}, 'test', 'event data correct');
    is($reason, 'disconnect', 'run terminated on disconnect');
};

subtest 'on_error() is Context dispatcher, not WS on_error()' => sub {
    my @errors;
    my ($ctx) = make_ws_ctx(
        receive => sub { Future->fail("receive broke") },
    );

    # Context on_error gets ($ctx, $error, $source)
    $ctx->on_error(sub {
        my ($c, $err, $source) = @_;
        push @errors, { err => $err, source => $source };
    });

    my $reason = (async sub { return await $ctx->run })->()->get;

    is($reason, 'error', 'run returned error reason');
    is(scalar @errors, 1, 'error callback fired');
    like($errors[0]{err}, qr/receive broke/, 'error text');
    is($errors[0]{source}, 'receive', 'source is receive');
};

subtest 'run() is Context dispatcher, not WS run()' => sub {
    my @types_seen;
    my ($ctx) = make_ws_ctx(events => [
        { type => 'websocket.receive', text => 'msg' },
        { type => 'custom.channel', data => 'x' },
        { type => 'websocket.disconnect' },
    ]);

    $ctx->on('websocket.receive', sub { push @types_seen, 'ws.recv' });
    $ctx->on('custom.channel',    sub { push @types_seen, 'custom' });

    my $reason = (async sub { return await $ctx->run })->()->get;

    is(\@types_seen, ['ws.recv', 'custom'], 'both event types dispatched');
    is($reason, 'disconnect', 'terminated on protocol disconnect');
};

# ---------------------------------------------------------------------------
# ws() accessor still works
# ---------------------------------------------------------------------------

subtest 'ws() and websocket() still return underlying object' => sub {
    my ($ctx) = make_ws_ctx();

    my $ws = $ctx->ws;
    isa_ok($ws, 'PAGI::WebSocket');

    my $ws2 = $ctx->websocket;
    ok($ws == $ws2, 'same object');

    # Direct WS operations still work
    (async sub { await $ws->accept })->()->get;
    ok($ws->is_connected, 'direct WS accept works');
};

done_testing;
