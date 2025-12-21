#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use Future;

use lib 'lib';
use PAGI::WebSocket;

# Helper to create connected WebSocket
sub create_ws {
    my (%opts) = @_;
    my @sent;
    my $should_fail = $opts{fail};

    my $send = sub {
        my $event = $_[0];
        push @sent, $event;
        # Only fail on websocket.send, not on accept
        if ($should_fail && $event->{type} eq 'websocket.send') {
            return Future->fail('Connection lost');
        }
        return Future->done;
    };

    my $scope = { type => 'websocket', headers => [] };
    my $receive = sub { Future->done({ type => 'websocket.connect' }) };

    my $ws = PAGI::WebSocket->new($scope, $receive, $send);
    $ws->accept->get;

    return ($ws, \@sent);
}

subtest 'try_send_text returns true on success' => sub {
    my ($ws, $sent) = create_ws();
    @$sent = ();

    my $result = $ws->try_send_text('Hello')->get;

    ok($result, 'returns true on success');
    is($sent->[0]{text}, 'Hello', 'message sent');
};

subtest 'try_send_text returns false on failure' => sub {
    my ($ws, $sent) = create_ws(fail => 1);
    @$sent = ();

    my $result = $ws->try_send_text('Hello')->get;

    ok(!$result, 'returns false on failure');
    ok($ws->is_closed, 'marks connection as closed');
    is($ws->close_code, 1006, 'sets close code to 1006 (abnormal closure)');
    is($ws->close_reason, 'Connection lost', 'sets close reason');
};

subtest 'try_send_text returns false when already closed' => sub {
    my ($ws, $sent) = create_ws();
    $ws->close->get;
    @$sent = ();

    my $result = $ws->try_send_text('Hello')->get;

    ok(!$result, 'returns false when closed');
    is(scalar @$sent, 0, 'no message sent');
};

subtest 'try_send_bytes works like try_send_text' => sub {
    my ($ws, $sent) = create_ws();
    @$sent = ();

    my $result = $ws->try_send_bytes("\x00\x01")->get;

    ok($result, 'returns true on success');
    is($sent->[0]{bytes}, "\x00\x01", 'bytes sent');
};

subtest 'try_send_bytes returns false on failure' => sub {
    my ($ws, $sent) = create_ws(fail => 1);
    @$sent = ();

    my $result = $ws->try_send_bytes("\x00")->get;

    ok(!$result, 'returns false on failure');
    ok($ws->is_closed, 'marks connection as closed');
};

subtest 'try_send_bytes returns false when already closed' => sub {
    my ($ws, $sent) = create_ws();
    $ws->close->get;
    @$sent = ();

    my $result = $ws->try_send_bytes("\x00")->get;

    ok(!$result, 'returns false when closed');
    is(scalar @$sent, 0, 'no message sent');
};

subtest 'try_send_json works like try_send_text' => sub {
    my ($ws, $sent) = create_ws();
    @$sent = ();

    my $result = $ws->try_send_json({ msg => 'hi' })->get;

    ok($result, 'returns true on success');
    like($sent->[0]{text}, qr/"msg"/, 'JSON sent');
};

subtest 'try_send_json returns false on failure' => sub {
    my ($ws, $sent) = create_ws(fail => 1);
    @$sent = ();

    my $result = $ws->try_send_json({ msg => 'hi' })->get;

    ok(!$result, 'returns false on failure');
    ok($ws->is_closed, 'marks connection as closed');
};

subtest 'try_send_json returns false when already closed' => sub {
    my ($ws, $sent) = create_ws();
    $ws->close->get;
    @$sent = ();

    my $result = $ws->try_send_json({ msg => 'hi' })->get;

    ok(!$result, 'returns false when closed');
    is(scalar @$sent, 0, 'no message sent');
};

subtest 'send_text_if_connected is silent when closed' => sub {
    my ($ws, $sent) = create_ws();
    $ws->close->get;
    @$sent = ();

    # Should not die, should not send
    $ws->send_text_if_connected('Hello')->get;

    is(scalar @$sent, 0, 'no message sent');
};

subtest 'send_text_if_connected sends when connected' => sub {
    my ($ws, $sent) = create_ws();
    @$sent = ();

    $ws->send_text_if_connected('Hello')->get;

    is(scalar @$sent, 1, 'message sent');
    is($sent->[0]{text}, 'Hello', 'correct text sent');
};

subtest 'send_bytes_if_connected is silent when closed' => sub {
    my ($ws, $sent) = create_ws();
    $ws->close->get;
    @$sent = ();

    $ws->send_bytes_if_connected("\x00")->get;

    is(scalar @$sent, 0, 'no message sent');
};

subtest 'send_bytes_if_connected sends when connected' => sub {
    my ($ws, $sent) = create_ws();
    @$sent = ();

    $ws->send_bytes_if_connected("\x00\x01")->get;

    is(scalar @$sent, 1, 'message sent');
    is($sent->[0]{bytes}, "\x00\x01", 'correct bytes sent');
};

subtest 'send_json_if_connected is silent when closed' => sub {
    my ($ws, $sent) = create_ws();
    $ws->close->get;
    @$sent = ();

    $ws->send_json_if_connected({ test => 1 })->get;

    is(scalar @$sent, 0, 'no message sent');
};

subtest 'send_json_if_connected sends when connected' => sub {
    my ($ws, $sent) = create_ws();
    @$sent = ();

    $ws->send_json_if_connected({ test => 1 })->get;

    is(scalar @$sent, 1, 'message sent');
};

done_testing;
