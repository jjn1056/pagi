#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use IO::Async::Loop;

use PAGI::Middleware::WebSocket::Compression;
use PAGI::Middleware::WebSocket::RateLimit;

my $loop = IO::Async::Loop->new;

sub run_async :prototype(&) {
    my ($code) = @_;
    $loop->await($code->());
}

# ===================
# WebSocket::Compression Tests
# ===================

subtest 'WebSocket::Compression - adds compression config to scope' => sub {
    my $compress = PAGI::Middleware::WebSocket::Compression->new(
        level    => 6,
        min_size => 128,
    );

    my $captured_scope;
    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        $captured_scope = $scope;
        await $send->({ type => 'websocket.accept' });
    };

    my $wrapped = $compress->wrap($app);
    my $scope = {
        type    => 'websocket',
        headers => [['sec-websocket-extensions', 'permessage-deflate']],
    };

    run_async {
        $wrapped->(
            $scope,
            async sub { { type => 'websocket.disconnect' } },
            async sub { }
        );
    };

    ok exists $captured_scope->{'pagi.websocket.compression'}, 'has compression config';
    is $captured_scope->{'pagi.websocket.compression'}{level}, 6, 'level set';
    is $captured_scope->{'pagi.websocket.compression'}{min_size}, 128, 'min_size set';
};

subtest 'WebSocket::Compression - passes through non-websocket' => sub {
    my $compress = PAGI::Middleware::WebSocket::Compression->new();

    my $captured_scope;
    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        $captured_scope = $scope;
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
    };

    my $wrapped = $compress->wrap($app);
    my $scope = { type => 'http', method => 'GET', path => '/' };

    run_async { $wrapped->($scope, async sub { {} }, async sub { }) };

    ok !exists $captured_scope->{'pagi.websocket.compression'}, 'no compression for HTTP';
};

subtest 'WebSocket::Compression - passes through without extension' => sub {
    my $compress = PAGI::Middleware::WebSocket::Compression->new();

    my $captured_scope;
    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        $captured_scope = $scope;
        await $send->({ type => 'websocket.accept' });
    };

    my $wrapped = $compress->wrap($app);
    my $scope = {
        type    => 'websocket',
        headers => [],  # No permessage-deflate
    };

    run_async {
        $wrapped->(
            $scope,
            async sub { { type => 'websocket.disconnect' } },
            async sub { }
        );
    };

    ok !exists $captured_scope->{'pagi.websocket.compression'}, 'no compression without extension';
};

# ===================
# WebSocket::RateLimit Tests
# ===================

subtest 'WebSocket::RateLimit - adds rate limit config to scope' => sub {
    my $ratelimit = PAGI::Middleware::WebSocket::RateLimit->new(
        messages_per_second => 50,
        bytes_per_second    => 32768,
        burst_multiplier    => 3,
    );

    my $captured_scope;
    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        $captured_scope = $scope;
        await $send->({ type => 'websocket.accept' });
    };

    my $wrapped = $ratelimit->wrap($app);
    my $scope = {
        type    => 'websocket',
        headers => [],
    };

    run_async {
        $wrapped->(
            $scope,
            async sub { { type => 'websocket.disconnect' } },
            async sub { }
        );
    };

    ok exists $captured_scope->{'pagi.websocket.rate_limit'}, 'has rate limit config';
    is $captured_scope->{'pagi.websocket.rate_limit'}{messages_per_second}, 50, 'msg limit set';
    is $captured_scope->{'pagi.websocket.rate_limit'}{bytes_per_second}, 32768, 'byte limit set';
    is $captured_scope->{'pagi.websocket.rate_limit'}{burst_multiplier}, 3, 'burst set';
};

subtest 'WebSocket::RateLimit - passes through messages within limit' => sub {
    my $ratelimit = PAGI::Middleware::WebSocket::RateLimit->new(
        messages_per_second => 100,
        bytes_per_second    => 1048576,
    );

    my @received_events;
    my $msg_count = 0;

    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        await $send->({ type => 'websocket.accept' });

        while ($msg_count < 3) {
            my $event = await $receive->();
            last if $event->{type} eq 'websocket.disconnect';
            push @received_events, $event;
            $msg_count++;
        }
    };

    my $wrapped = $ratelimit->wrap($app);
    my $scope = { type => 'websocket', headers => [] };

    my $recv_count = 0;
    my @test_messages = (
        { type => 'websocket.receive', text => 'Hello' },
        { type => 'websocket.receive', text => 'World' },
        { type => 'websocket.receive', text => '!' },
        { type => 'websocket.disconnect' },
    );

    run_async {
        $wrapped->(
            $scope,
            async sub { $test_messages[$recv_count++] },
            async sub { }
        );
    };

    is scalar(@received_events), 3, 'all messages passed through';
    is $received_events[0]{text}, 'Hello', 'first message received';
    is $received_events[1]{text}, 'World', 'second message received';
    is $received_events[2]{text}, '!', 'third message received';
};

subtest 'WebSocket::RateLimit - passes through non-websocket' => sub {
    my $ratelimit = PAGI::Middleware::WebSocket::RateLimit->new();

    my $captured_scope;
    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        $captured_scope = $scope;
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
    };

    my $wrapped = $ratelimit->wrap($app);
    my $scope = { type => 'http', method => 'GET', path => '/' };

    run_async { $wrapped->($scope, async sub { {} }, async sub { }) };

    ok !exists $captured_scope->{'pagi.websocket.rate_limit'}, 'no rate limit for HTTP';
};

subtest 'WebSocket::RateLimit - calls callback on limit exceeded' => sub {
    my @callback_args;
    my $ratelimit = PAGI::Middleware::WebSocket::RateLimit->new(
        messages_per_second => 1,
        burst_multiplier    => 1,
        on_limit_exceeded   => sub {
            push @callback_args, [@_];
            return 0;  # Don't close, just drop
        },
    );

    my $recv_count = 0;
    my @test_messages = (
        { type => 'websocket.receive', text => 'First' },
        { type => 'websocket.receive', text => 'Second' },  # Should exceed
        { type => 'websocket.disconnect' },
    );

    my @received;
    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        await $send->({ type => 'websocket.accept' });

        for my $i (1..2) {
            my $event = await $receive->();
            last if $event->{type} eq 'websocket.disconnect';
            push @received, $event;
        }
    };

    my $wrapped = $ratelimit->wrap($app);
    my $scope = { type => 'websocket', headers => [] };

    run_async {
        $wrapped->(
            $scope,
            async sub { $test_messages[$recv_count++] },
            async sub { }
        );
    };

    # First message should pass, second should trigger callback
    # Since callback returns 0, message is dropped but connection stays open
    is scalar(@received), 1, 'only first message received';
    is $received[0]{text}, 'First', 'first message correct';
};

done_testing;
