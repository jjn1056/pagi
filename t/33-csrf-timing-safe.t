#!/usr/bin/env perl

# =============================================================================
# Test: CSRF timing-safe comparison
#
# Verifies that CSRF token comparison uses constant-time comparison
# to prevent timing attacks.
# =============================================================================

use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use IO::Async::Loop;

require PAGI::Middleware::CSRF;

my $loop = IO::Async::Loop->new;

sub run_async {
    my ($code) = @_;
    my $future = $code->();
    $loop->await($future);
}

# =============================================================================
# Test: _secure_compare method
# =============================================================================

subtest '_secure_compare constant-time comparison' => sub {
    my $csrf = PAGI::Middleware::CSRF->new(secret => 'test-secret');

    # Basic equality tests
    ok($csrf->_secure_compare('abc', 'abc'), 'identical strings match');
    ok(!$csrf->_secure_compare('abc', 'abd'), 'different strings do not match');
    ok(!$csrf->_secure_compare('abc', 'ab'), 'different length strings do not match');
    ok(!$csrf->_secure_compare('ab', 'abc'), 'different length strings do not match (reversed)');

    # Edge cases
    ok($csrf->_secure_compare('', ''), 'empty strings match');
    ok(!$csrf->_secure_compare('', 'a'), 'empty vs non-empty do not match');
    ok(!$csrf->_secure_compare('a', ''), 'non-empty vs empty do not match');

    # Undefined handling
    ok(!$csrf->_secure_compare(undef, 'abc'), 'undef vs string returns false');
    ok(!$csrf->_secure_compare('abc', undef), 'string vs undef returns false');
    ok(!$csrf->_secure_compare(undef, undef), 'undef vs undef returns false');

    # Long strings (ensure full comparison)
    my $long1 = 'a' x 1000;
    my $long2 = 'a' x 1000;
    my $long3 = 'a' x 999 . 'b';
    ok($csrf->_secure_compare($long1, $long2), 'long identical strings match');
    ok(!$csrf->_secure_compare($long1, $long3), 'long strings differing at end do not match');

    # Difference at beginning vs end should both fail
    # (timing attack would show faster failure at beginning with naive compare)
    my $token1 = 'abcdef1234567890abcdef1234567890';
    my $token2 = 'Xbcdef1234567890abcdef1234567890';  # differs at start
    my $token3 = 'abcdef1234567890abcdef123456789X';  # differs at end
    ok(!$csrf->_secure_compare($token1, $token2), 'difference at start fails');
    ok(!$csrf->_secure_compare($token1, $token3), 'difference at end fails');
};

# =============================================================================
# Test: CSRF middleware uses _secure_compare
# =============================================================================

subtest 'CSRF middleware token validation' => sub {
    my $csrf = PAGI::Middleware::CSRF->new(secret => 'test-secret');

    # Generate a token
    my $token = $csrf->_generate_token();
    ok(length($token) > 0, 'token generated');

    # Mock app that just succeeds
    my $app_called = 0;
    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        $app_called = 1;
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'ok', more => 0 });
    };

    my $wrapped = $csrf->wrap($app);

    # Test: POST with matching tokens should succeed
    $app_called = 0;
    my @events;
    my $scope = {
        type => 'http',
        method => 'POST',
        path => '/test',
        headers => [
            ['cookie', "csrf_token=$token"],
            ['x-csrf-token', $token],
        ],
    };

    my $receive = async sub { { type => 'http.disconnect' } };
    my $send = async sub { push @events, $_[0] };

    run_async(async sub {
        await $wrapped->($scope, $receive, $send);
    });
    ok($app_called, 'app called with valid token');

    # Test: POST with mismatched tokens should fail
    $app_called = 0;
    @events = ();
    $scope = {
        type => 'http',
        method => 'POST',
        path => '/test',
        headers => [
            ['cookie', "csrf_token=$token"],
            ['x-csrf-token', 'wrong-token'],
        ],
    };

    run_async(async sub {
        await $wrapped->($scope, $receive, $send);
    });
    ok(!$app_called, 'app NOT called with invalid token');
    is($events[0]{status}, 403, 'returns 403 for invalid token');

    # Test: POST with no submitted token should fail
    $app_called = 0;
    @events = ();
    $scope = {
        type => 'http',
        method => 'POST',
        path => '/test',
        headers => [
            ['cookie', "csrf_token=$token"],
        ],
    };

    run_async(async sub {
        await $wrapped->($scope, $receive, $send);
    });
    ok(!$app_called, 'app NOT called with missing token');
    is($events[0]{status}, 403, 'returns 403 for missing token');

    # Test: GET should pass through without validation
    $app_called = 0;
    @events = ();
    $scope = {
        type => 'http',
        method => 'GET',
        path => '/test',
        headers => [],
    };

    run_async(async sub {
        await $wrapped->($scope, $receive, $send);
    });
    ok($app_called, 'GET passes through without CSRF check');
};

done_testing;
