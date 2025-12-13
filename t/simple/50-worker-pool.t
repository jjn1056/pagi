#!/usr/bin/env perl

# =============================================================================
# Unit Tests for Worker Pool Feature
#
# Tests configuration handling and error messages for the worker pool.
# Integration tests with actual worker processes are in t/integration/
# =============================================================================

use strict;
use warnings;
use Test2::V0;
use experimental 'signatures';

use FindBin;
use lib "$FindBin::Bin/../../lib";

use PAGI::Simple;
use PAGI::Simple::Context;
use Future;

# =============================================================================
# Test: Workers not configured (default)
# =============================================================================

subtest 'Workers disabled by default' => sub {
    my $app = PAGI::Simple->new(name => 'Test App');

    is($app->worker_pool, undef, 'worker_pool returns undef when not configured');
    ok(!exists $app->{_worker_config} || !defined $app->{_worker_config},
       'no worker config stored');
};

# =============================================================================
# Test: run_blocking fails without config
# =============================================================================

subtest 'run_blocking fails without worker config' => sub {
    my $app = PAGI::Simple->new(name => 'Test App');

    # Create minimal context
    my $c = PAGI::Simple::Context->new(
        app     => $app,
        scope   => { type => 'http', method => 'GET', path => '/' },
        receive => sub { Future->done({}) },
        send    => sub { Future->done },
    );

    like(
        dies { $c->run_blocking(sub { 1 }) },
        qr/requires worker configuration/,
        'run_blocking dies with helpful message'
    );

    like(
        dies { $c->run_blocking(sub { 1 }) },
        qr/PAGI::Simple->new/,
        'error message mentions how to configure'
    );
};

# =============================================================================
# Test: Worker configuration accepted
# =============================================================================

subtest 'Worker config stored correctly' => sub {
    my $app = PAGI::Simple->new(
        name    => 'Test App',
        workers => {
            max_workers  => 8,
            min_workers  => 2,
            idle_timeout => 60,
        },
    );

    ok($app->{_worker_config}, 'worker config stored');
    is($app->{_worker_config}{max_workers}, 8, 'max_workers preserved');
    is($app->{_worker_config}{min_workers}, 2, 'min_workers preserved');
    is($app->{_worker_config}{idle_timeout}, 60, 'idle_timeout preserved');
};

subtest 'Worker config with defaults' => sub {
    my $app = PAGI::Simple->new(
        name    => 'Test App',
        workers => {},  # Empty config - use all defaults
    );

    ok($app->{_worker_config}, 'empty worker config stored');
    # Pool not created yet (lazy)
    is($app->{_worker_pool}, undef, 'worker pool not created until needed');
};

# =============================================================================
# Test: Worker pool requires event loop
# =============================================================================

subtest 'Worker pool creation requires event loop' => sub {
    my $app = PAGI::Simple->new(
        name    => 'Test App',
        workers => { max_workers => 2 },
    );

    # No loop set - should fail
    like(
        dies { $app->worker_pool },
        qr/requires event loop/,
        'worker_pool dies without event loop'
    );

    like(
        dies { $app->worker_pool },
        qr/pagi-server/,
        'error message mentions pagi-server'
    );
};

# =============================================================================
# Test: Worker pool is lazy
# =============================================================================

subtest 'Worker pool is lazily created' => sub {
    my $app = PAGI::Simple->new(
        name    => 'Test App',
        workers => { max_workers => 2 },
    );

    # Config present but pool not created
    ok($app->{_worker_config}, 'config present');
    is($app->{_worker_pool}, undef, 'pool not yet created');

    # Attempting to create will fail without loop (tested above)
    # But the key point is it's not created in constructor
};

# =============================================================================
# Test: Multiple apps don't share worker pools
# =============================================================================

subtest 'Apps have independent worker configs' => sub {
    my $app1 = PAGI::Simple->new(
        name    => 'App 1',
        workers => { max_workers => 2 },
    );

    my $app2 = PAGI::Simple->new(
        name    => 'App 2',
        workers => { max_workers => 8 },
    );

    my $app3 = PAGI::Simple->new(
        name    => 'App 3',
        # No workers config
    );

    is($app1->{_worker_config}{max_workers}, 2, 'app1 has 2 workers');
    is($app2->{_worker_config}{max_workers}, 8, 'app2 has 8 workers');
    ok(!$app3->{_worker_config}, 'app3 has no workers');
};

done_testing;
