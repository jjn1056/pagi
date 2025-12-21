#!/usr/bin/env perl

use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use IO::Async::Loop;

use lib 'lib';

use PAGI::App::WebSocket::Echo;
use PAGI::App::WebSocket::Broadcast;
use PAGI::App::WebSocket::Chat;

my $loop = IO::Async::Loop->new;

sub run_async {
    my ($code) = @_;
    my $future = $code->();
    $loop->await($future);
}

# =============================================================================
# Test: PAGI::App::WebSocket::Echo
# =============================================================================

subtest 'App::WebSocket::Echo' => sub {

    subtest 'echoes text messages' => sub {
        my $app = PAGI::App::WebSocket::Echo->new->to_app;

        my @events = (
            { type => 'websocket.receive', text => 'Hello' },
            { type => 'websocket.disconnect', code => 1000 },
        );
        my $event_idx = 0;

        my @sent;
        run_async(async sub {
            await $app->(
                { type => 'websocket', path => '/' },
                async sub { $events[$event_idx++] },
                async sub  {
        my ($event) = @_; push @sent, $event },
            );
        });

        is $sent[0]{type}, 'websocket.accept', 'accepts connection';
        is $sent[1]{type}, 'websocket.send', 'sends echo';
        is $sent[1]{text}, 'Hello', 'echoes correct text';
    };

    subtest 'echoes binary messages' => sub {
        my $app = PAGI::App::WebSocket::Echo->new->to_app;

        my @events = (
            { type => 'websocket.receive', bytes => "\x00\x01\x02" },
            { type => 'websocket.disconnect', code => 1000 },
        );
        my $event_idx = 0;

        my @sent;
        run_async(async sub {
            await $app->(
                { type => 'websocket', path => '/' },
                async sub { $events[$event_idx++] },
                async sub  {
        my ($event) = @_; push @sent, $event },
            );
        });

        is $sent[1]{bytes}, "\x00\x01\x02", 'echoes binary data';
    };

    subtest 'calls on_connect callback' => sub {
        my $connected = 0;
        my $app = PAGI::App::WebSocket::Echo->new(
            on_connect => sub { $connected = 1 },
        )->to_app;

        my @events = (
            { type => 'websocket.disconnect', code => 1000 },
        );
        my $event_idx = 0;

        run_async(async sub {
            await $app->(
                { type => 'websocket', path => '/' },
                async sub { $events[$event_idx++] },
                async sub  {
        my ($event) = @_; },
            );
        });

        ok $connected, 'on_connect called';
    };

    subtest 'calls on_disconnect callback' => sub {
        my $disconnect_code;
        my $app = PAGI::App::WebSocket::Echo->new(
            on_disconnect => sub  {
        my ($scope, $code) = @_; $disconnect_code = $code },
        )->to_app;

        my @events = (
            { type => 'websocket.disconnect', code => 1001 },
        );
        my $event_idx = 0;

        run_async(async sub {
            await $app->(
                { type => 'websocket', path => '/' },
                async sub { $events[$event_idx++] },
                async sub  {
        my ($event) = @_; },
            );
        });

        is $disconnect_code, 1001, 'on_disconnect called with code';
    };
};

# =============================================================================
# Test: PAGI::App::WebSocket::Broadcast
# =============================================================================

subtest 'App::WebSocket::Broadcast' => sub {

    subtest 'client_count tracks connections' => sub {
        # Reset state
        my $count = PAGI::App::WebSocket::Broadcast->client_count;
        is $count, 0, 'starts with 0 clients';
    };

    subtest 'creates broadcast app' => sub {
        my $app = PAGI::App::WebSocket::Broadcast->new->to_app;
        ok ref($app) eq 'CODE', 'returns coderef';
    };
};

# =============================================================================
# Test: PAGI::App::WebSocket::Chat
# =============================================================================

subtest 'App::WebSocket::Chat' => sub {

    subtest 'sends welcome message on connect' => sub {
        my $app = PAGI::App::WebSocket::Chat->new->to_app;

        my @events = (
            { type => 'websocket.disconnect', code => 1000 },
        );
        my $event_idx = 0;

        my @sent;
        run_async(async sub {
            await $app->(
                { type => 'websocket', path => '/' },
                async sub { $events[$event_idx++] },
                async sub  {
        my ($event) = @_; push @sent, $event },
            );
        });

        is $sent[0]{type}, 'websocket.accept', 'accepts connection';
        is $sent[1]{type}, 'websocket.send', 'sends welcome';

        my $welcome = eval { JSON::PP::decode_json($sent[1]{text}) };
        is $welcome->{type}, 'welcome', 'welcome message type';
        ok exists $welcome->{user_id}, 'has user_id';
        ok exists $welcome->{username}, 'has username';
        is $welcome->{room}, 'lobby', 'joined default room';
    };

    subtest 'handles nick command' => sub {
        my $app = PAGI::App::WebSocket::Chat->new->to_app;

        my @events = (
            { type => 'websocket.receive', text => '{"type":"nick","username":"testuser"}' },
            { type => 'websocket.disconnect', code => 1000 },
        );
        my $event_idx = 0;

        my @sent;
        run_async(async sub {
            await $app->(
                { type => 'websocket', path => '/' },
                async sub { $events[$event_idx++] },
                async sub  {
        my ($event) = @_; push @sent, $event },
            );
        });

        # Find nick response
        my $nick_response;
        for my $s (@sent) {
            next unless $s->{type} eq 'websocket.send';
            my $data = eval { JSON::PP::decode_json($s->{text}) };
            if ($data && $data->{type} eq 'nick') {
                $nick_response = $data;
                last;
            }
        }

        ok $nick_response, 'received nick response';
        is $nick_response->{username}, 'testuser', 'username changed';
    };

    subtest 'handles rooms command' => sub {
        my $app = PAGI::App::WebSocket::Chat->new->to_app;

        my @events = (
            { type => 'websocket.receive', text => '{"type":"rooms"}' },
            { type => 'websocket.disconnect', code => 1000 },
        );
        my $event_idx = 0;

        my @sent;
        run_async(async sub {
            await $app->(
                { type => 'websocket', path => '/' },
                async sub { $events[$event_idx++] },
                async sub  {
        my ($event) = @_; push @sent, $event },
            );
        });

        # Find rooms response
        my $rooms_response;
        for my $s (@sent) {
            next unless $s->{type} eq 'websocket.send';
            my $data = eval { JSON::PP::decode_json($s->{text}) };
            if ($data && $data->{type} eq 'rooms') {
                $rooms_response = $data;
                last;
            }
        }

        ok $rooms_response, 'received rooms response';
        ok ref($rooms_response->{rooms}) eq 'ARRAY', 'rooms is array';
    };
};

done_testing;
