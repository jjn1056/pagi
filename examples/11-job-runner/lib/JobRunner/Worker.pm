package JobRunner::Worker;

use strict;
use warnings;
use feature 'signatures';
no warnings 'experimental::signatures';

use Exporter 'import';
use Future::AsyncAwait;
use IO::Async::Timer::Periodic;
use Scalar::Util qw(weaken);

use JobRunner::Queue qw(
    get_job pop_next_job update_progress
    complete_job fail_job get_running_jobs
    broadcast_queue_event
);
use JobRunner::Jobs qw(execute_job);

our @EXPORT_OK = qw(
    start_worker stop_worker get_worker_stats
);

# Worker state
my $worker_timer;
my $event_loop;
my $concurrency = 3;        # Default max concurrent jobs
my $running_count = 0;      # Currently running jobs
my $total_processed = 0;    # Total jobs completed
my $is_running = 0;

#
# Worker Control
#

sub start_worker {
    my ($loop, $max_concurrent) = @_;
    $max_concurrent //= 3;

    return if $is_running;

    $event_loop = $loop;
    $concurrency = $max_concurrent;
    $is_running = 1;

    # Create worker timer - polls for new jobs every 100ms
    $worker_timer = IO::Async::Timer::Periodic->new(
        interval => 0.1,
        on_tick  => \&_check_queue,
    );

    $loop->add($worker_timer);
    $worker_timer->start;

    return 1;
}

sub stop_worker {
    my () = @_;

    return unless $is_running;

    $is_running = 0;

    if ($worker_timer) {
        $worker_timer->stop;
        $event_loop->remove($worker_timer) if $event_loop;
        $worker_timer = undef;
    }

    return 1;
}

sub get_worker_stats {
    my () = @_;

    return {
        active    => $running_count,
        capacity  => $concurrency,
        processed => $total_processed,
        is_running => $is_running,
    };
}

sub _broadcast_worker_stats {
    my () = @_;

    broadcast_queue_event('worker_stats', get_worker_stats());
}

#
# Internal Functions
#

sub _check_queue {
    return unless $is_running;

    # Don't exceed concurrency limit
    return if $running_count >= $concurrency;

    # Try to get next job
    my $job_id = pop_next_job();
    return unless $job_id;

    # Spawn async execution
    $running_count++;
    _broadcast_worker_stats();

    # Execute job asynchronously (fire and forget)
    _execute_job_async($job_id);
}

sub _execute_job_async {
    my ($job_id) = @_;

    my $job = get_job($job_id);
    return unless $job;

    # Create progress callback
    my $progress_cb = sub  {
        my ($percent, $message) = @_;
        update_progress($job_id, $percent, $message);
    };

    # Create cancellation check
    my $cancel_check = sub {
        my $current = get_job($job_id);
        return $current && $current->{status} eq 'cancelled';
    };

    # Execute the job
    my $future = execute_job($job, $event_loop, $progress_cb, $cancel_check);

    $future->on_done(sub ($result) {
        complete_job($job_id, $result);
        $running_count--;
        $total_processed++;
        _broadcast_worker_stats();
    })->on_fail(sub ($error) {
        # Check if it was a cancellation
        if ($error =~ /cancelled/i) {
            # Job was cancelled - don't mark as failed (already marked)
        } else {
            fail_job($job_id, "$error");
        }
        $running_count--;
        $total_processed++;
        _broadcast_worker_stats();
    })->retain;  # Keep future alive
}

1;

__END__

# NAME

JobRunner::Worker - Async job execution engine

# DESCRIPTION

Polls the job queue and executes jobs asynchronously up to a configurable
concurrency limit.

## Usage

```perl
use JobRunner::Worker qw(start_worker stop_worker get_worker_stats);

# Start worker with max 3 concurrent jobs
start_worker($loop, 3);

# Get worker status
my $stats = get_worker_stats();
# { active => 2, capacity => 3, processed => 15, is_running => 1 }

# Stop worker (wait for current jobs to finish)
stop_worker();
```
