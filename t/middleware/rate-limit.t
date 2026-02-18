#!/usr/bin/env perl

use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use IO::Async::Loop;

use lib 'lib';

use PAGI::Middleware::RateLimit;

my $loop = IO::Async::Loop->new;

sub run_async {
    my ($code) = @_;
    my $future = $code->();
    $loop->await($future);
}

my $simple_app = async sub {
    my ($scope, $receive, $send) = @_;
    await $send->({
        type    => 'http.response.start',
        status  => 200,
        headers => [['content-type', 'text/plain']],
    });
    await $send->({
        type => 'http.response.body',
        body => 'OK',
        more => 0,
    });
};

sub make_scope {
    my ($client_ip) = @_;
    return {
        type    => 'http',
        path    => '/',
        method  => 'GET',
        headers => [],
        client  => [$client_ip // '127.0.0.1', 12345],
    };
}

sub make_request {
    my ($wrapped, $client_ip) = @_;
    my @sent;
    run_async(async sub {
        await $wrapped->(
            make_scope($client_ip),
            async sub { { type => 'http.disconnect' } },
            async sub { my ($event) = @_; push @sent, $event },
        );
    });
    return @sent;
}

# =============================================================================
# Test: Rate limiting still works correctly (burst exhaustion -> 429)
# =============================================================================

subtest 'burst exhaustion results in 429' => sub {
    PAGI::Middleware::RateLimit->_clear_buckets();

    my $mw = PAGI::Middleware::RateLimit->new(
        requests_per_second => 0.1,  # Very slow refill
        burst               => 3,
    );

    my $wrapped = $mw->wrap($simple_app);

    for my $i (1..3) {
        my @sent = make_request($wrapped);
        is $sent[0]{status}, 200, "request $i allowed (within burst)";
    }

    my @sent = make_request($wrapped);
    is $sent[0]{status}, 429, 'request 4 blocked (burst exhausted)';
};

# =============================================================================
# Test: Stale buckets are cleaned up after time passes
# =============================================================================

subtest 'stale buckets are cleaned up' => sub {
    PAGI::Middleware::RateLimit->_clear_buckets();

    my $mw = PAGI::Middleware::RateLimit->new(
        requests_per_second => 1,
        burst               => 5,
        cleanup_interval    => 10,
    );

    my $wrapped = $mw->wrap($simple_app);

    # Create buckets for several clients
    for my $i (1..5) {
        make_request($wrapped, "10.0.0.$i");
    }

    is(PAGI::Middleware::RateLimit->_bucket_count(), 5, '5 buckets created');

    # Advance time beyond stale threshold (2 * burst / rate = 2 * 5 / 1 = 10s)
    # and beyond cleanup_interval (10s)
    PAGI::Middleware::RateLimit->_advance_time_for_test(25);

    # Trigger cleanup by making a request (from a new client)
    make_request($wrapped, '10.0.0.100');

    # The 5 old buckets should be cleaned up; only the new one remains
    is(PAGI::Middleware::RateLimit->_bucket_count(), 1, 'stale buckets cleaned up');
};

# =============================================================================
# Test: Active buckets are NOT cleaned up
# =============================================================================

subtest 'active buckets are not cleaned up' => sub {
    PAGI::Middleware::RateLimit->_clear_buckets();

    # stale_threshold = now - (2 * burst / rate) = now - 10
    my $mw = PAGI::Middleware::RateLimit->new(
        requests_per_second => 1,
        burst               => 5,
        cleanup_interval    => 10,
    );

    my $wrapped = $mw->wrap($simple_app);

    # T=0: create buckets for two clients
    make_request($wrapped, '10.0.0.1');
    make_request($wrapped, '10.0.0.2');
    is(PAGI::Middleware::RateLimit->_bucket_count(), 2, 'two buckets created');

    # T=22: advance past cleanup_interval, triggering cleanup
    # stale_threshold = T+22 - 10 = T+12
    # Both clients last seen at T=0 < T+12 -> both stale, BUT we keep client 1
    # active by making a request in the same tick (its last_time updates to T+22)
    PAGI::Middleware::RateLimit->_advance_time_for_test(22);
    make_request($wrapped, '10.0.0.1');

    # Client 1: last_time=T+22, >= stale_threshold T+12 -> kept
    # Client 2: last_time=T+0, < stale_threshold T+12 -> cleaned
    is(PAGI::Middleware::RateLimit->_bucket_count(), 1,
        'stale client cleaned but active client kept');
};

# =============================================================================
# Test: max_buckets safety valve evicts oldest
# =============================================================================

subtest 'max_buckets safety valve evicts oldest' => sub {
    PAGI::Middleware::RateLimit->_clear_buckets();

    my $mw = PAGI::Middleware::RateLimit->new(
        requests_per_second => 1,
        burst               => 5,
        max_buckets         => 10,
        cleanup_interval    => 3600,  # Large so periodic cleanup doesn't interfere
    );

    my $wrapped = $mw->wrap($simple_app);

    # Create 11 buckets (exceeds max_buckets of 10)
    for my $i (1..11) {
        # Small time offset between each so we have distinct last_time values
        PAGI::Middleware::RateLimit->_advance_time_for_test(1);
        make_request($wrapped, "10.0.0.$i");
    }

    # Safety valve should have kicked in, reducing to max_buckets/2 = 5
    ok(PAGI::Middleware::RateLimit->_bucket_count() <= 10,
        'bucket count reduced by safety valve');
    ok(PAGI::Middleware::RateLimit->_bucket_count() >= 1,
        'some buckets remain after safety valve');
};

done_testing;
