#!/usr/bin/env perl

# =============================================================================
# Integration Tests for Worker Pool
#
# Tests the worker pool with a real IO::Async event loop.
# Verifies that:
#   1. Worker pool is created correctly
#   2. Blocking code runs in separate processes
#   3. Results are returned correctly
#   4. Errors propagate back from workers
#   5. Context run_blocking() works end-to-end
#
# IMPORTANT: Closures with captured variables do NOT work because B::Deparse
# serializes code as text without capturing lexical values. Pass data via
# function arguments or package variables instead.
# =============================================================================

use strict;
use warnings;
use Test2::V0;
use experimental 'signatures';
use Future::AsyncAwait;

use FindBin;
use lib "$FindBin::Bin/../../lib";

use IO::Async::Loop;
use PAGI::Simple;
use PAGI::Simple::Context;
use Future;

# =============================================================================
# Test: Worker pool creation with real loop
# =============================================================================

subtest 'Worker pool created with event loop' => sub {
    my $loop = IO::Async::Loop->new;

    my $app = PAGI::Simple->new(
        name    => 'Worker Test',
        workers => { max_workers => 2 },
    );

    # Inject loop (normally done by server)
    $app->{_loop} = $loop;

    my $pool = $app->worker_pool;
    ok($pool, 'worker pool created');
    isa_ok($pool, ['IO::Async::Function'], 'pool is IO::Async::Function');

    # Cleanup
    $pool->stop->get;
    $loop->remove($pool);
};

# =============================================================================
# Test: Blocking code runs in worker process
# =============================================================================

subtest 'Blocking code runs in separate process' => sub {
    my $loop = IO::Async::Loop->new;

    my $app = PAGI::Simple->new(
        name    => 'Worker Test',
        workers => { max_workers => 2 },
    );

    $app->{_loop} = $loop;

    my $c = PAGI::Simple::Context->new(
        app     => $app,
        scope   => { type => 'http', method => 'GET', path => '/' },
        receive => sub { Future->done({}) },
        send    => sub { Future->done },
    );

    my $main_pid = $$;

    my $future = $c->run_blocking(sub {
        return {
            worker_pid => $$,
            computed   => 2 + 2,
        };
    });

    $loop->await($future);
    my $result = $future->get;

    ok($result, 'got result from worker');
    is($result->{computed}, 4, 'computation correct');
    isnt($result->{worker_pid}, $main_pid, 'ran in different process');

    # Cleanup
    $app->{_worker_pool}->stop->get;
    $loop->remove($app->{_worker_pool});
};

# =============================================================================
# Test: run_blocking via context
# =============================================================================

subtest 'run_blocking via context works' => sub {
    my $loop = IO::Async::Loop->new;

    my $app = PAGI::Simple->new(
        name    => 'Worker Test',
        workers => { max_workers => 2 },
    );

    $app->{_loop} = $loop;

    # Create context like a route handler would have
    my $c = PAGI::Simple::Context->new(
        app     => $app,
        scope   => { type => 'http', method => 'GET', path => '/' },
        receive => sub { Future->done({}) },
        send    => sub { Future->done },
    );

    my $future = $c->run_blocking(sub {
        # Simulate blocking computation
        my $sum = 0;
        $sum += $_ for 1..1000;
        return $sum;
    });

    $loop->await($future);
    my $result = $future->get;

    is($result, 500500, 'blocking computation returned correct result');

    # Cleanup
    $app->{_worker_pool}->stop->get;
    $loop->remove($app->{_worker_pool});
};

# =============================================================================
# Test: Error propagation from worker
# =============================================================================

subtest 'Errors propagate from worker' => sub {
    my $loop = IO::Async::Loop->new;

    my $app = PAGI::Simple->new(
        name    => 'Worker Test',
        workers => { max_workers => 2 },
    );

    $app->{_loop} = $loop;

    my $c = PAGI::Simple::Context->new(
        app     => $app,
        scope   => { type => 'http', method => 'GET', path => '/' },
        receive => sub { Future->done({}) },
        send    => sub { Future->done },
    );

    my $future = $c->run_blocking(sub {
        die "Intentional error for testing\n";
    });

    my $error;
    eval {
        $loop->await($future);
        $future->get;
    };
    $error = $@;

    like($error, qr/Intentional error/, 'error propagated from worker');

    # Cleanup
    $app->{_worker_pool}->stop->get;
    $loop->remove($app->{_worker_pool});
};

# =============================================================================
# Test: Multiple sequential operations
# =============================================================================

subtest 'Multiple sequential operations work' => sub {
    my $loop = IO::Async::Loop->new;

    my $app = PAGI::Simple->new(
        name    => 'Worker Test',
        workers => { max_workers => 2 },
    );

    $app->{_loop} = $loop;

    my $c = PAGI::Simple::Context->new(
        app     => $app,
        scope   => { type => 'http', method => 'GET', path => '/' },
        receive => sub { Future->done({}) },
        send    => sub { Future->done },
    );

    my @results;

    # Run multiple operations sequentially
    for my $n (1, 2, 3) {
        my $future = $c->run_blocking(sub {
            return 10;  # Simple return, no closure
        });
        $loop->await($future);
        push @results, $future->get;
    }

    is(\@results, [10, 10, 10], 'all sequential operations completed');

    # Cleanup
    $app->{_worker_pool}->stop->get;
    $loop->remove($app->{_worker_pool});
};

# =============================================================================
# Test: Worker pool is reused across calls
# =============================================================================

subtest 'Worker pool is reused across calls' => sub {
    my $loop = IO::Async::Loop->new;

    my $app = PAGI::Simple->new(
        name    => 'Worker Test',
        workers => { max_workers => 2 },
    );

    $app->{_loop} = $loop;

    # First call creates pool
    my $pool1 = $app->worker_pool;
    ok($pool1, 'first call creates pool');

    # Get the refaddr to compare
    my $addr1 = "$pool1";

    # Second call returns same pool
    my $pool2 = $app->worker_pool;
    ok($pool2, 'second call returns pool');
    my $addr2 = "$pool2";

    is($addr1, $addr2, 'same pool instance returned (by address)');

    # Cleanup
    $app->{_worker_pool}->stop->get;
    $loop->remove($app->{_worker_pool});
};

# =============================================================================
# Test: Self-contained computation (no closures)
# =============================================================================

subtest 'Self-contained computation works' => sub {
    my $loop = IO::Async::Loop->new;

    my $app = PAGI::Simple->new(
        name    => 'Worker Test',
        workers => { max_workers => 2 },
    );

    $app->{_loop} = $loop;

    my $c = PAGI::Simple::Context->new(
        app     => $app,
        scope   => { type => 'http', method => 'GET', path => '/' },
        receive => sub { Future->done({}) },
        send    => sub { Future->done },
    );

    my $future = $c->run_blocking(sub {
        # All data is self-contained - no closures
        my $items = [1, 2, 3, 4, 5];
        my $sum = 0;
        $sum += $_ for @$items;
        return {
            count => scalar(@$items),
            sum   => $sum,
            avg   => $sum / scalar(@$items),
        };
    });

    $loop->await($future);
    my $result = $future->get;

    is($result->{count}, 5, 'count correct');
    is($result->{sum}, 15, 'sum correct');
    is($result->{avg}, 3, 'average correct');

    # Cleanup
    $app->{_worker_pool}->stop->get;
    $loop->remove($app->{_worker_pool});
};

# =============================================================================
# Test: Return complex nested structures
# =============================================================================

subtest 'Complex return values work' => sub {
    my $loop = IO::Async::Loop->new;

    my $app = PAGI::Simple->new(
        name    => 'Worker Test',
        workers => { max_workers => 2 },
    );

    $app->{_loop} = $loop;

    my $c = PAGI::Simple::Context->new(
        app     => $app,
        scope   => { type => 'http', method => 'GET', path => '/' },
        receive => sub { Future->done({}) },
        send    => sub { Future->done },
    );

    my $future = $c->run_blocking(sub {
        return {
            string => 'hello',
            number => 42,
            float  => 3.14,
            array  => [1, 2, 3],
            nested => {
                a => 1,
                b => [4, 5, 6],
            },
        };
    });

    $loop->await($future);
    my $result = $future->get;

    is($result->{string}, 'hello', 'string returned');
    is($result->{number}, 42, 'number returned');
    ok(abs($result->{float} - 3.14) < 0.001, 'float returned');
    is($result->{array}, [1, 2, 3], 'array returned');
    is($result->{nested}{a}, 1, 'nested hash returned');
    is($result->{nested}{b}, [4, 5, 6], 'nested array returned');

    # Cleanup
    $app->{_worker_pool}->stop->get;
    $loop->remove($app->{_worker_pool});
};

# =============================================================================
# Test: Simulated blocking I/O
# =============================================================================

# =============================================================================
# Test: Arguments passed to worker
# =============================================================================

# Note: Due to a B::Deparse bug, subroutine signatures don't work correctly
# in run_blocking. Use traditional @_ argument handling instead.

subtest 'Arguments passed to worker code' => sub {
    my $loop = IO::Async::Loop->new;

    my $app = PAGI::Simple->new(
        name    => 'Worker Test',
        workers => { max_workers => 2 },
    );

    $app->{_loop} = $loop;

    my $c = PAGI::Simple::Context->new(
        app     => $app,
        scope   => { type => 'http', method => 'GET', path => '/' },
        receive => sub { Future->done({}) },
        send    => sub { Future->done },
    );

    # Pass scalar arguments - use @_ style (signatures don't work with B::Deparse)
    my $id = 42;
    my $name = 'test_user';

    my $future = $c->run_blocking(sub {
        my ($user_id, $user_name) = @_;
        return {
            id   => $user_id,
            name => $user_name,
            combined => "$user_name:$user_id",
        };
    }, $id, $name);

    $loop->await($future);
    my $result = $future->get;

    is($result->{id}, 42, 'scalar id passed correctly');
    is($result->{name}, 'test_user', 'scalar name passed correctly');
    is($result->{combined}, 'test_user:42', 'values usable in worker');

    # Cleanup
    $app->{_worker_pool}->stop->get;
    $loop->remove($app->{_worker_pool});
};

subtest 'Complex arguments passed to worker' => sub {
    my $loop = IO::Async::Loop->new;

    my $app = PAGI::Simple->new(
        name    => 'Worker Test',
        workers => { max_workers => 2 },
    );

    $app->{_loop} = $loop;

    my $c = PAGI::Simple::Context->new(
        app     => $app,
        scope   => { type => 'http', method => 'GET', path => '/' },
        receive => sub { Future->done({}) },
        send    => sub { Future->done },
    );

    # Pass complex data structures
    my $filters = {
        status => 'active',
        tags   => ['perl', 'async'],
        limit  => 10,
    };
    my $items = [1, 2, 3, 4, 5];

    my $future = $c->run_blocking(sub {
        my ($opts, $data) = @_;
        return {
            status     => $opts->{status},
            tag_count  => scalar(@{$opts->{tags}}),
            first_tag  => $opts->{tags}[0],
            item_sum   => do { my $s = 0; $s += $_ for @$data; $s },
            limit      => $opts->{limit},
        };
    }, $filters, $items);

    $loop->await($future);
    my $result = $future->get;

    is($result->{status}, 'active', 'hash value passed');
    is($result->{tag_count}, 2, 'nested array passed');
    is($result->{first_tag}, 'perl', 'array element accessible');
    is($result->{item_sum}, 15, 'array argument passed');
    is($result->{limit}, 10, 'numeric value passed');

    # Cleanup
    $app->{_worker_pool}->stop->get;
    $loop->remove($app->{_worker_pool});
};

subtest 'No arguments still works' => sub {
    my $loop = IO::Async::Loop->new;

    my $app = PAGI::Simple->new(
        name    => 'Worker Test',
        workers => { max_workers => 2 },
    );

    $app->{_loop} = $loop;

    my $c = PAGI::Simple::Context->new(
        app     => $app,
        scope   => { type => 'http', method => 'GET', path => '/' },
        receive => sub { Future->done({}) },
        send    => sub { Future->done },
    );

    # No arguments - should still work
    my $future = $c->run_blocking(sub {
        return 'no args needed';
    });

    $loop->await($future);
    my $result = $future->get;

    is($result, 'no args needed', 'no-argument call still works');

    # Cleanup
    $app->{_worker_pool}->stop->get;
    $loop->remove($app->{_worker_pool});
};

# =============================================================================
# Test: Simulated blocking I/O
# =============================================================================

subtest 'Simulated blocking sleep works' => sub {
    my $loop = IO::Async::Loop->new;

    my $app = PAGI::Simple->new(
        name    => 'Worker Test',
        workers => { max_workers => 2 },
    );

    $app->{_loop} = $loop;

    my $c = PAGI::Simple::Context->new(
        app     => $app,
        scope   => { type => 'http', method => 'GET', path => '/' },
        receive => sub { Future->done({}) },
        send    => sub { Future->done },
    );

    my $start = time();

    my $future = $c->run_blocking(sub {
        # Simulate a short blocking operation
        select(undef, undef, undef, 0.1);  # 100ms sleep
        return 'done';
    });

    $loop->await($future);
    my $result = $future->get;

    my $elapsed = time() - $start;

    is($result, 'done', 'blocking operation completed');
    ok($elapsed >= 0.05, 'some time passed');  # Allow for timing variance

    # Cleanup
    $app->{_worker_pool}->stop->get;
    $loop->remove($app->{_worker_pool});
};

done_testing;
