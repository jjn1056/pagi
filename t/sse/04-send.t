#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use Future;
use JSON::PP;

use lib 'lib';
use PAGI::SSE;

subtest 'send sends data-only event' => sub {
    my @sent;
    my $send = sub { push @sent, $_[0]; Future->done };

    my $sse = PAGI::SSE->new({ type => 'sse' }, sub {}, $send);
    $sse->start->get;

    $sse->send("Hello world")->get;

    is($sent[1]{type}, 'sse.send', 'event type is sse.send');
    is($sent[1]{data}, 'Hello world', 'data is set');
    ok(!exists $sent[1]{event}, 'no event field');
    ok(!exists $sent[1]{id}, 'no id field');
};

subtest 'send_json encodes as JSON' => sub {
    my @sent;
    my $send = sub { push @sent, $_[0]; Future->done };

    my $sse = PAGI::SSE->new({ type => 'sse' }, sub {}, $send);
    $sse->start->get;

    $sse->send_json({ message => "hello", count => 42 })->get;

    my $decoded = JSON::PP::decode_json($sent[1]{data});
    is($decoded->{message}, 'hello', 'JSON message field');
    is($decoded->{count}, 42, 'JSON count field');
};

subtest 'send_event with all fields' => sub {
    my @sent;
    my $send = sub { push @sent, $_[0]; Future->done };

    my $sse = PAGI::SSE->new({ type => 'sse' }, sub {}, $send);
    $sse->start->get;

    $sse->send_event(
        data  => { type => 'notification' },
        event => 'alert',
        id    => 'msg-123',
        retry => 5000,
    )->get;

    is($sent[1]{type}, 'sse.send', 'event type is sse.send');
    is($sent[1]{event}, 'alert', 'event name');
    is($sent[1]{id}, 'msg-123', 'event id');
    is($sent[1]{retry}, 5000, 'retry value');

    my $decoded = JSON::PP::decode_json($sent[1]{data});
    is($decoded->{type}, 'notification', 'data was JSON encoded');
};

subtest 'send_event with string data' => sub {
    my @sent;
    my $send = sub { push @sent, $_[0]; Future->done };

    my $sse = PAGI::SSE->new({ type => 'sse' }, sub {}, $send);
    $sse->start->get;

    $sse->send_event(data => "plain text")->get;

    is($sent[1]{data}, 'plain text', 'string data not encoded');
};

subtest 'send auto-starts if not started' => sub {
    my @sent;
    my $send = sub { push @sent, $_[0]; Future->done };

    my $sse = PAGI::SSE->new({ type => 'sse' }, sub {}, $send);

    # Send without calling start first
    $sse->send("Hello")->get;

    is(scalar @sent, 2, 'two events sent');
    is($sent[0]{type}, 'sse.start', 'first was sse.start');
    is($sent[1]{type}, 'sse.send', 'second was sse.send');
};

subtest 'send on closed connection dies' => sub {
    my $sse = PAGI::SSE->new({ type => 'sse' }, sub {}, sub { Future->done });
    $sse->_set_closed;

    like(
        dies { $sse->send("test")->get },
        qr/Cannot send on closed SSE/,
        'send on closed dies'
    );
};

done_testing;
