package JobRunner::Worker;

use strict;
use warnings;

use Exporter 'import';
use Future::AsyncAwait;
use Future::IO;
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
my $worker_tick;            # the running tick loop's Future
my $concurrency = 3;        # Default max concurrent jobs
my $running_count = 0;      # Currently running jobs
my $total_processed = 0;    # Total jobs completed
my $is_running = 0;

#
# Worker Control
#

sub start_worker {
    my ($max_concurrent) = @_;
    $max_concurrent //= 3;

    return if $is_running;

    $concurrency = $max_concurrent;
    $is_running = 1;

    # A self-rescheduling tick rather than an event-loop timer object. This
    # names no loop: Future::IO->sleep dispatches to whichever implementation
    # the server bound at startup, so the worker runs unchanged under any
    # conforming PAGI server.
    $worker_tick = (async sub {
        while ($is_running) {
            _check_queue();
            await Future::IO->sleep(0.1);
        }
    })->();

    $worker_tick->on_fail(sub {
        warn "[worker] tick loop stopped: $_[0]";
    });

    return 1;
}

sub stop_worker {
    my () = @_;

    return unless $is_running;

    # The tick loop checks this on its next pass; cancelling ends the pending
    # sleep so shutdown does not wait out the interval.
    $is_running = 0;

    if ($worker_tick) {
        $worker_tick->cancel unless $worker_tick->is_ready;
        $worker_tick = undef;
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
    my $future = execute_job($job, $progress_cb, $cancel_check);

    $future->on_done(sub {
        my ($result) = @_;
        complete_job($job_id, $result);
        $running_count--;
        $total_processed++;
        _broadcast_worker_stats();
    })->on_fail(sub {
        my ($error) = @_;
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
start_worker(3);

# Get worker status
my $stats = get_worker_stats();
# { active => 2, capacity => 3, processed => 15, is_running => 1 }

# Stop worker (wait for current jobs to finish)
stop_worker();
```
