#!/usr/bin/env perl
use strict;
use warnings;
use experimental 'signatures';
use Test2::V0;
use Future::AsyncAwait;
use IO::Async::Loop;

use PAGI::Middleware::RateLimit;
use PAGI::Middleware::Timeout;

my $loop = IO::Async::Loop->new;

# Helper to create HTTP scope
sub make_scope {
    my (%opts) = @_;
    return {
        type   => 'http',
        method => 'GET',
        path   => '/',
        client => $opts{client} // ['127.0.0.1', 12345],
        headers => $opts{headers} // [],
    };
}

# Helper to run async tests
sub run_async :prototype(&) {
    my ($code) = @_;
    $loop->await($code->());
}

# ===================
# RateLimit Middleware Tests
# ===================

subtest 'RateLimit - allows requests under limit' => sub {
    PAGI::Middleware::RateLimit->reset_all();

    my $rate_limit = PAGI::Middleware::RateLimit->new(
        requests_per_second => 100,
        burst               => 10,
    );

    my $app = async sub ($scope, $receive, $send) {
        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [['Content-Type', 'text/plain']],
        });
        await $send->({
            type => 'http.response.body',
            body => 'OK',
            more => 0,
        });
    };

    my $wrapped = $rate_limit->wrap($app);

    for my $i (1..5) {
        my $scope = make_scope(client => ['192.168.1.100', 12345]);
        my @events;
        my $send = async sub ($event) { push @events, $event };
        my $receive = async sub { { type => 'http.request', body => '', more => 0 } };

        run_async { $wrapped->($scope, $receive, $send) };

        is $events[0]{status}, 200, "request $i allowed";

        # Check rate limit headers
        my %headers = map { lc($_->[0]) => $_->[1] } @{$events[0]{headers}};
        ok exists $headers{'x-ratelimit-limit'}, 'has X-RateLimit-Limit';
        ok exists $headers{'x-ratelimit-remaining'}, 'has X-RateLimit-Remaining';
    }
};

subtest 'RateLimit - blocks requests over limit' => sub {
    PAGI::Middleware::RateLimit->reset_all();

    my $rate_limit = PAGI::Middleware::RateLimit->new(
        requests_per_second => 0.1,  # Very slow refill
        burst               => 3,
    );

    my $app = async sub ($scope, $receive, $send) {
        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [['Content-Type', 'text/plain']],
        });
        await $send->({
            type => 'http.response.body',
            body => 'OK',
            more => 0,
        });
    };

    my $wrapped = $rate_limit->wrap($app);

    # Use the burst allowance
    for my $i (1..3) {
        my $scope = make_scope(client => ['192.168.1.200', 12345]);
        my @events;
        my $send = async sub ($event) { push @events, $event };
        my $receive = async sub { { type => 'http.request', body => '', more => 0 } };

        run_async { $wrapped->($scope, $receive, $send) };
        is $events[0]{status}, 200, "request $i allowed";
    }

    # Next request should be rate limited
    my $scope = make_scope(client => ['192.168.1.200', 12345]);
    my @events;
    my $send = async sub ($event) { push @events, $event };
    my $receive = async sub { { type => 'http.request', body => '', more => 0 } };

    run_async { $wrapped->($scope, $receive, $send) };

    is $events[0]{status}, 429, 'request blocked with 429';
    my %headers = map { lc($_->[0]) => $_->[1] } @{$events[0]{headers}};
    ok exists $headers{'retry-after'}, 'has Retry-After header';
};

subtest 'RateLimit - different clients have separate limits' => sub {
    PAGI::Middleware::RateLimit->reset_all();

    my $rate_limit = PAGI::Middleware::RateLimit->new(
        requests_per_second => 0.1,
        burst               => 2,
    );

    my $app = async sub ($scope, $receive, $send) {
        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [['Content-Type', 'text/plain']],
        });
        await $send->({
            type => 'http.response.body',
            body => 'OK',
            more => 0,
        });
    };

    my $wrapped = $rate_limit->wrap($app);

    # Client A uses its burst
    for my $i (1..2) {
        my $scope = make_scope(client => ['10.0.0.1', 12345]);
        my @events;
        my $send = async sub ($event) { push @events, $event };
        my $receive = async sub { { type => 'http.request', body => '', more => 0 } };
        run_async { $wrapped->($scope, $receive, $send) };
        is $events[0]{status}, 200, "client A request $i allowed";
    }

    # Client B should still have its own burst
    for my $i (1..2) {
        my $scope = make_scope(client => ['10.0.0.2', 12345]);
        my @events;
        my $send = async sub ($event) { push @events, $event };
        my $receive = async sub { { type => 'http.request', body => '', more => 0 } };
        run_async { $wrapped->($scope, $receive, $send) };
        is $events[0]{status}, 200, "client B request $i allowed";
    }

    # Client A is now rate limited
    my $scope = make_scope(client => ['10.0.0.1', 12345]);
    my @events;
    my $send = async sub ($event) { push @events, $event };
    my $receive = async sub { { type => 'http.request', body => '', more => 0 } };
    run_async { $wrapped->($scope, $receive, $send) };
    is $events[0]{status}, 429, 'client A blocked';
};

subtest 'RateLimit - custom key generator' => sub {
    PAGI::Middleware::RateLimit->reset_all();

    my $rate_limit = PAGI::Middleware::RateLimit->new(
        requests_per_second => 0.1,
        burst               => 1,
        key_generator       => sub ($scope) { $scope->{path} },
    );

    my $app = async sub ($scope, $receive, $send) {
        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [['Content-Type', 'text/plain']],
        });
        await $send->({
            type => 'http.response.body',
            body => 'OK',
            more => 0,
        });
    };

    my $wrapped = $rate_limit->wrap($app);

    # Request to /path1
    my $scope1 = { %{make_scope()}, path => '/path1' };
    my @events1;
    run_async { $wrapped->($scope1, async sub { {} }, async sub { push @events1, shift }) };
    is $events1[0]{status}, 200, '/path1 first request allowed';

    # Request to /path2 should be allowed (different key)
    my $scope2 = { %{make_scope()}, path => '/path2' };
    my @events2;
    run_async { $wrapped->($scope2, async sub { {} }, async sub { push @events2, shift }) };
    is $events2[0]{status}, 200, '/path2 request allowed';

    # Another request to /path1 should be blocked
    my @events3;
    run_async { $wrapped->($scope1, async sub { {} }, async sub { push @events3, shift }) };
    is $events3[0]{status}, 429, '/path1 second request blocked';
};

# ===================
# Timeout Middleware Tests
# ===================

subtest 'Timeout - allows fast requests' => sub {
    my $timeout = PAGI::Middleware::Timeout->new(
        timeout => 5,
        loop    => $loop,
    );

    my $app = async sub ($scope, $receive, $send) {
        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [['Content-Type', 'text/plain']],
        });
        await $send->({
            type => 'http.response.body',
            body => 'Fast response',
            more => 0,
        });
    };

    my $wrapped = $timeout->wrap($app);
    my $scope = make_scope();

    my @events;
    my $send = async sub ($event) { push @events, $event };
    my $receive = async sub { { type => 'http.request', body => '', more => 0 } };

    run_async { $wrapped->($scope, $receive, $send) };

    is $events[0]{status}, 200, 'fast request succeeds';
    is $events[1]{body}, 'Fast response', 'body received';
};

subtest 'Timeout - times out slow requests' => sub {
    my $timeout_called = 0;
    my $timeout = PAGI::Middleware::Timeout->new(
        timeout    => 0.1,  # 100ms
        loop       => $loop,
        on_timeout => sub { $timeout_called = 1 },
    );

    my $app = async sub ($scope, $receive, $send) {
        # Simulate slow processing
        await $loop->delay_future(after => 1);  # 1 second
        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [['Content-Type', 'text/plain']],
        });
        await $send->({
            type => 'http.response.body',
            body => 'Slow response',
            more => 0,
        });
    };

    my $wrapped = $timeout->wrap($app);
    my $scope = make_scope();

    my @events;
    my $send = async sub ($event) { push @events, $event };
    my $receive = async sub { { type => 'http.request', body => '', more => 0 } };

    run_async { $wrapped->($scope, $receive, $send) };

    is $events[0]{status}, 504, 'slow request times out with 504';
    ok $timeout_called, 'on_timeout callback was called';
};

subtest 'Timeout - passes through non-HTTP requests' => sub {
    my $timeout = PAGI::Middleware::Timeout->new(
        timeout => 1,
        loop    => $loop,
    );

    my $app = async sub ($scope, $receive, $send) {
        await $send->({ type => 'websocket.accept' });
    };

    my $wrapped = $timeout->wrap($app);
    my $scope = { type => 'websocket' };

    my @events;
    my $send = async sub ($event) { push @events, $event };
    my $receive = async sub { {} };

    run_async { $wrapped->($scope, $receive, $send) };

    is $events[0]{type}, 'websocket.accept', 'non-HTTP passed through';
};

done_testing;
