#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use Future;
use JSON::PP;

use lib 'lib';
use PAGI::WebSocket;

# Helper to create connected WebSocket
sub create_ws {
    my ($send_cb) = @_;
    my @sent;
    $send_cb //= sub { push @sent, $_[0]; Future->done };

    my $scope = { type => 'websocket', headers => [] };
    my $receive = sub { Future->done({ type => 'websocket.connect' }) };

    my $ws = PAGI::WebSocket->new($scope, $receive, $send_cb);
    $ws->accept->get;

    return ($ws, \@sent);
}

subtest 'send_text sends text frame' => sub {
    my ($ws, $sent) = create_ws();
    @$sent = ();

    $ws->send_text('Hello, World!')->get;

    is(scalar @$sent, 1, 'one event sent');
    is($sent->[0]{type}, 'websocket.send', 'correct event type');
    is($sent->[0]{text}, 'Hello, World!', 'text content');
    ok(!exists $sent->[0]{bytes}, 'no bytes key');
};

subtest 'send_bytes sends binary frame' => sub {
    my ($ws, $sent) = create_ws();
    @$sent = ();

    my $binary = "\x00\x01\x02\xFF";
    $ws->send_bytes($binary)->get;

    is(scalar @$sent, 1, 'one event sent');
    is($sent->[0]{type}, 'websocket.send', 'correct event type');
    is($sent->[0]{bytes}, $binary, 'bytes content');
    ok(!exists $sent->[0]{text}, 'no text key');
};

subtest 'send_json encodes and sends as text' => sub {
    my ($ws, $sent) = create_ws();
    @$sent = ();

    my $data = { action => 'greet', name => 'Alice', count => 42 };
    $ws->send_json($data)->get;

    is(scalar @$sent, 1, 'one event sent');
    is($sent->[0]{type}, 'websocket.send', 'correct event type');

    my $decoded = decode_json($sent->[0]{text});
    is($decoded, $data, 'JSON decoded correctly');
};

subtest 'send_json handles arrays' => sub {
    my ($ws, $sent) = create_ws();
    @$sent = ();

    my $data = [1, 2, 3, 'four'];
    $ws->send_json($data)->get;

    my $decoded = decode_json($sent->[0]{text});
    is($decoded, $data, 'array encoded correctly');
};

subtest 'send_json handles nested structures' => sub {
    my ($ws, $sent) = create_ws();
    @$sent = ();

    my $data = {
        users => [
            { id => 1, name => 'Alice' },
            { id => 2, name => 'Bob' },
        ],
        meta => { total => 2 },
    };
    $ws->send_json($data)->get;

    my $decoded = decode_json($sent->[0]{text});
    is($decoded, $data, 'nested structure encoded correctly');
};

subtest 'send methods fail when closed' => sub {
    my ($ws, $sent) = create_ws();
    $ws->close->get;

    like(
        dies { $ws->send_text('test')->get },
        qr/closed/i,
        'send_text dies when closed'
    );

    like(
        dies { $ws->send_bytes('test')->get },
        qr/closed/i,
        'send_bytes dies when closed'
    );

    like(
        dies { $ws->send_json({ test => 1 })->get },
        qr/closed/i,
        'send_json dies when closed'
    );
};

done_testing;
