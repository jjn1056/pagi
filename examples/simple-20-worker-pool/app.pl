#!/usr/bin/env perl
use strict;
use warnings;
use experimental 'signatures';
use Future::AsyncAwait;

use PAGI::Simple;

# =============================================================================
# Worker Pool Example
#
# Demonstrates running blocking operations without blocking the event loop.
# This is useful for:
#   - Database queries (DBI, DBD::*)
#   - File I/O operations
#   - CPU-intensive computations
#   - External command execution
#   - Any code that doesn't support async
#
# IMPORTANT: Use @_ style arguments, not subroutine signatures.
# Due to B::Deparse limitations, signatures don't work in run_blocking.
# =============================================================================

my $app = PAGI::Simple->new(
    name => 'Worker Pool Demo',

    # Enable worker pool with 4 workers
    workers => {
        max_workers  => 4,    # Maximum concurrent workers
        min_workers  => 1,    # Keep at least 1 worker alive
        idle_timeout => 60,   # Kill idle workers after 60s
    },
);

# Home page with links
$app->get('/' => sub ($c) {
    $c->html(<<'HTML');
<!DOCTYPE html>
<html>
<head>
    <title>Worker Pool Demo</title>
    <style>
        body { font-family: system-ui; max-width: 800px; margin: 2rem auto; padding: 0 1rem; }
        pre { background: #f5f5f5; padding: 1rem; overflow-x: auto; }
        .endpoint { margin: 1rem 0; padding: 1rem; border: 1px solid #ddd; border-radius: 4px; }
        code { background: #f0f0f0; padding: 0.2rem 0.4rem; }
        .note { background: #e7f3ff; padding: 1rem; border-radius: 4px; margin: 1rem 0; }
    </style>
</head>
<body>
    <h1>Worker Pool Demo</h1>
    <p>This example demonstrates <code>$c->run_blocking()</code> for running
       blocking operations in worker processes.</p>

    <div class="note">
        <strong>Usage:</strong> Pass arguments after the coderef, receive via <code>@_</code><br>
        <code>await $c->run_blocking(sub { my ($a, $b) = @_; ... }, $a, $b);</code>
    </div>

    <div class="endpoint">
        <h3>GET /compute/:n</h3>
        <p>CPU-intensive computation (sum of 1 to n) in worker.</p>
        <a href="/compute/1000000">Try: /compute/1000000</a>
    </div>

    <div class="endpoint">
        <h3>GET /sleep/:seconds</h3>
        <p>Blocking sleep in worker (doesn't block event loop).</p>
        <a href="/sleep/2">Try: /sleep/2</a>
    </div>

    <div class="endpoint">
        <h3>GET /file-stats</h3>
        <p>Get file statistics using blocking stat() calls.</p>
        <a href="/file-stats">Try: /file-stats</a>
    </div>

    <div class="endpoint">
        <h3>GET /fibonacci/:n</h3>
        <p>Calculate Fibonacci number (CPU-intensive, recursive).</p>
        <a href="/fibonacci/35">Try: /fibonacci/35</a>
    </div>

    <div class="endpoint">
        <h3>GET /non-blocking</h3>
        <p>For comparison: a normal async endpoint (no worker).</p>
        <a href="/non-blocking">Try: /non-blocking</a>
    </div>
</body>
</html>
HTML
});

# CPU-intensive computation in worker with argument passing
$app->get('/compute/:n' => async sub ($c) {
    my $n = $c->path_params->{n} || 1000;
    $n = 10_000_000 if $n > 10_000_000;  # Limit

    my $start = time();

    # Pass $n as an argument to the worker
    my $result = await $c->run_blocking(sub {
        my ($limit) = @_;
        my $sum = 0;
        $sum += $_ for 1..$limit;
        return {
            sum        => $sum,
            worker_pid => $$,
        };
    }, $n);

    my $elapsed = time() - $start;

    $c->json({
        input      => $n,
        sum        => $result->{sum},
        worker_pid => $result->{worker_pid},
        main_pid   => $$,
        elapsed_ms => int($elapsed * 1000),
    });
});

# Blocking sleep with argument passing
$app->get('/sleep/:seconds' => async sub ($c) {
    my $seconds = $c->path_params->{seconds} || 1;
    $seconds = 10 if $seconds > 10;  # Limit

    my $start = time();

    # Pass sleep duration as argument
    await $c->run_blocking(sub {
        my ($secs) = @_;
        sleep($secs);
        return 1;
    }, $seconds);

    my $elapsed = time() - $start;

    $c->json({
        requested_sleep => $seconds,
        actual_elapsed  => $elapsed,
        message         => "Slept in worker - event loop stayed responsive!",
    });
});

# Blocking file stats with argument passing
$app->get('/file-stats' => async sub ($c) {
    # Pass file list as argument
    my @files = qw(/etc/passwd /etc/hosts /tmp);

    my $result = await $c->run_blocking(sub {
        my ($file_list) = @_;
        my @stats;

        for my $file (@$file_list) {
            my @stat = stat($file);
            push @stats, {
                path   => $file,
                size   => $stat[7] // 'N/A',
                mtime  => $stat[9] // 'N/A',
                exists => -e $file ? 1 : 0,
            };
        }

        return {
            files      => \@stats,
            worker_pid => $$,
        };
    }, \@files);

    $c->json($result);
});

# CPU-intensive Fibonacci with argument passing
$app->get('/fibonacci/:n' => async sub ($c) {
    my $n = $c->path_params->{n} || 30;
    $n = 40 if $n > 40;  # Limit to prevent excessive computation

    my $start = time();

    # Pass target number as argument
    my $result = await $c->run_blocking(sub {
        my ($target) = @_;

        my $fib;
        $fib = sub {
            my ($n) = @_;
            return $n if $n < 2;
            return $fib->($n - 1) + $fib->($n - 2);
        };

        return {
            n          => $target,
            result     => $fib->($target),
            worker_pid => $$,
        };
    }, $n);

    my $elapsed = time() - $start;

    $c->json({
        n          => $n,
        fibonacci  => $result->{result},
        worker_pid => $result->{worker_pid},
        main_pid   => $$,
        elapsed_ms => int($elapsed * 1000),
    });
});

# Non-blocking comparison
$app->get('/non-blocking' => sub ($c) {
    $c->json({
        message => "This is a normal non-blocking handler",
        pid     => $$,
        note    => "No worker used - runs in main process",
    });
});

$app->to_app;
