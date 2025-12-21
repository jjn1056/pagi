#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use IO::Async::Loop;

use PAGI::Middleware::WebSocket::Heartbeat;
use PAGI::Middleware::SSE::Retry;
use PAGI::Middleware::SSE::Heartbeat;

my $loop = IO::Async::Loop->new;

sub run_async :prototype(&) {
    my ($code) = @_;
    $loop->await($code->());
}

# ===================
# WebSocket::Heartbeat Tests
# ===================

subtest 'WebSocket::Heartbeat - adds heartbeat config to scope' => sub {
    my $heartbeat = PAGI::Middleware::WebSocket::Heartbeat->new(
        interval => 30,
        timeout  => 10,
        loop     => $loop,
    );

    my $captured_scope;
    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        $captured_scope = $scope;
        # Send accept
        await $send->({ type => 'websocket.accept' });
    };

    my $wrapped = $heartbeat->wrap($app);
    my $scope = {
        type => 'websocket',
        headers => [],
    };

    my @events;
    run_async {
        $wrapped->(
            $scope,
            async sub { { type => 'websocket.disconnect' } },
            async sub  {
        my ($e) = @_; push @events, $e }
        );
    };

    ok exists $captured_scope->{'pagi.websocket.heartbeat'}, 'has heartbeat config in scope';
    is $captured_scope->{'pagi.websocket.heartbeat'}{interval}, 30, 'interval set';
    is $captured_scope->{'pagi.websocket.heartbeat'}{timeout}, 10, 'timeout set';
};

subtest 'WebSocket::Heartbeat - passes through non-websocket' => sub {
    my $heartbeat = PAGI::Middleware::WebSocket::Heartbeat->new(loop => $loop);

    my $captured_scope;
    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        $captured_scope = $scope;
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
    };

    my $wrapped = $heartbeat->wrap($app);
    my $scope = { type => 'http', method => 'GET', path => '/' };

    run_async { $wrapped->($scope, async sub { {} }, async sub { }) };

    ok !exists $captured_scope->{'pagi.websocket.heartbeat'}, 'no heartbeat for HTTP';
};

# ===================
# SSE::Retry Tests
# ===================

subtest 'SSE::Retry - sends retry hint on start' => sub {
    my $retry = PAGI::Middleware::SSE::Retry->new(
        retry => 5000,
        include_on_start => 1,
    );

    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        await $send->({ type => 'sse.start' });
        await $send->({ type => 'sse.send', data => 'test' });
    };

    my $wrapped = $retry->wrap($app);
    my $scope = { type => 'sse', headers => [] };

    my @events;
    run_async {
        $wrapped->($scope, async sub { {} }, async sub  {
        my ($e) = @_; push @events, $e });
    };

    is scalar(@events), 3, 'three events sent';
    is $events[0]{type}, 'sse.start', 'first is sse.start';
    is $events[1]{type}, 'sse.send', 'second is retry hint';
    is $events[1]{retry}, 5000, 'retry value set';
    is $events[2]{type}, 'sse.send', 'third is data event';
};

subtest 'SSE::Retry - adds retry to scope' => sub {
    my $retry = PAGI::Middleware::SSE::Retry->new(retry => 3000);

    my $captured_scope;
    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        $captured_scope = $scope;
        await $send->({ type => 'sse.start' });
    };

    my $wrapped = $retry->wrap($app);
    my $scope = { type => 'sse', headers => [] };

    run_async { $wrapped->($scope, async sub { {} }, async sub { }) };

    is $captured_scope->{'pagi.sse.retry'}, 3000, 'retry in scope';
};

subtest 'SSE::Retry - passes through non-SSE' => sub {
    my $retry = PAGI::Middleware::SSE::Retry->new();

    my $captured_scope;
    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        $captured_scope = $scope;
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
    };

    my $wrapped = $retry->wrap($app);
    my $scope = { type => 'http', method => 'GET', path => '/' };

    run_async { $wrapped->($scope, async sub { {} }, async sub { }) };

    ok !exists $captured_scope->{'pagi.sse.retry'}, 'no retry for HTTP';
};

# ===================
# SSE::Heartbeat Tests
# ===================

subtest 'SSE::Heartbeat - adds heartbeat config to scope' => sub {
    my $heartbeat = PAGI::Middleware::SSE::Heartbeat->new(
        interval => 15,
        comment  => 'ping',
        loop     => $loop,
    );

    my $captured_scope;
    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        $captured_scope = $scope;
        await $send->({ type => 'sse.start' });
    };

    my $wrapped = $heartbeat->wrap($app);
    my $scope = { type => 'sse', headers => [] };

    run_async { $wrapped->($scope, async sub { { type => 'sse.disconnect' } }, async sub { }) };

    ok exists $captured_scope->{'pagi.sse.heartbeat'}, 'has heartbeat config';
    is $captured_scope->{'pagi.sse.heartbeat'}{interval}, 15, 'interval set';
    is $captured_scope->{'pagi.sse.heartbeat'}{comment}, 'ping', 'comment set';
};

subtest 'SSE::Heartbeat - passes through non-SSE' => sub {
    my $heartbeat = PAGI::Middleware::SSE::Heartbeat->new(loop => $loop);

    my $captured_scope;
    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        $captured_scope = $scope;
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
    };

    my $wrapped = $heartbeat->wrap($app);
    my $scope = { type => 'http', method => 'GET', path => '/' };

    run_async { $wrapped->($scope, async sub { {} }, async sub { }) };

    ok !exists $captured_scope->{'pagi.sse.heartbeat'}, 'no heartbeat for HTTP';
};

done_testing;
