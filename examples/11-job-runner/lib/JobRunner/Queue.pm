package JobRunner::Queue;

use strict;
use warnings;

use Exporter 'import';
use Time::HiRes qw(time);
use Scalar::Util qw(weaken);

our @EXPORT_OK = qw(
    create_job get_job get_all_jobs update_job cancel_job
    get_pending_jobs get_running_jobs
    pop_next_job complete_job fail_job
    update_progress get_progress
    add_queue_subscriber remove_queue_subscriber broadcast_queue_event
    add_job_subscriber remove_job_subscriber broadcast_job_event
    get_queue_stats clear_completed_jobs
    set_event_loop
);

# Job storage
my %jobs;               # job_id => job hashref
my @pending_queue;      # Ordered list of pending job IDs
my %running_jobs;       # job_id => 1 (currently executing)
my $job_counter = 0;    # Auto-incrementing job ID

# Subscribers for real-time updates
my %queue_subscribers;  # subscriber_id => send_cb (for queue-wide events)
my %job_subscribers;    # job_id => { subscriber_id => send_cb } (for per-job progress)

# Event loop reference
my $event_loop;

# Job statuses
use constant {
    STATUS_PENDING   => 'pending',
    STATUS_RUNNING   => 'running',
    STATUS_COMPLETED => 'completed',
    STATUS_FAILED    => 'failed',
    STATUS_CANCELLED => 'cancelled',
};

sub set_event_loop {
    my ($loop) = @_;

    $event_loop = $loop;
}

sub get_event_loop {
    my () = @_;

    return $event_loop;
}

#
# Job Lifecycle
#

sub create_job {
    my ($type, $params) = @_;
    $params //= {};

    my $job_id = ++$job_counter;

    my $job = {
        id           => $job_id,
        type         => $type,
        params       => $params,
        status       => STATUS_PENDING,
        progress     => { percent => 0, message => 'Queued' },
        result       => undef,
        error        => undef,
        created_at   => time(),
        started_at   => undef,
        completed_at => undef,
    };

    $jobs{$job_id} = $job;
    push @pending_queue, $job_id;

    broadcast_queue_event('job_created', _job_summary($job));

    return $job_id;
}

sub get_job {
    my ($job_id) = @_;

    return $jobs{$job_id};
}

sub get_all_jobs {
    my () = @_;

    return [ map { _job_summary($_) } values %jobs ];
}

sub update_job {
    my ($job_id, $updates) = @_;

    my $job = $jobs{$job_id} or return;

    for my $key (keys %$updates) {
        $job->{$key} = $updates->{$key};
    }

    return $job;
}

sub cancel_job {
    my ($job_id) = @_;

    my $job = $jobs{$job_id} or return 0;

    # Can only cancel pending or running jobs
    return 0 if $job->{status} eq STATUS_COMPLETED
             || $job->{status} eq STATUS_FAILED
             || $job->{status} eq STATUS_CANCELLED;

    my $was_pending = $job->{status} eq STATUS_PENDING;

    $job->{status} = STATUS_CANCELLED;
    $job->{completed_at} = time();

    # Remove from pending queue if it was pending
    if ($was_pending) {
        @pending_queue = grep { $_ != $job_id } @pending_queue;
    }

    # Remove from running if it was running
    delete $running_jobs{$job_id};

    broadcast_queue_event('job_cancelled', { job_id => $job_id });
    broadcast_job_event($job_id, 'cancelled', { job_id => $job_id });

    return 1;
}

#
# Queue Management
#

sub get_pending_jobs {
    my () = @_;

    return [ @pending_queue ];
}

sub get_running_jobs {
    my () = @_;

    return [ keys %running_jobs ];
}

sub pop_next_job {
    my () = @_;

    return unless @pending_queue;

    my $job_id = shift @pending_queue;
    my $job = $jobs{$job_id} or return pop_next_job();  # Skip if job was deleted

    $running_jobs{$job_id} = 1;
    $job->{status} = STATUS_RUNNING;
    $job->{started_at} = time();
    $job->{progress} = { percent => 0, message => 'Starting...' };

    broadcast_queue_event('job_started', {
        job_id     => $job_id,
        started_at => $job->{started_at},
    });

    return $job_id;
}

sub complete_job {
    my ($job_id, $result) = @_;

    my $job = $jobs{$job_id} or return;

    delete $running_jobs{$job_id};

    $job->{status} = STATUS_COMPLETED;
    $job->{result} = $result;
    $job->{completed_at} = time();
    $job->{progress} = { percent => 100, message => 'Complete' };

    my $duration = $job->{completed_at} - ($job->{started_at} // $job->{created_at});

    broadcast_queue_event('job_completed', {
        job_id   => $job_id,
        result   => $result,
        duration => $duration,
    });

    broadcast_job_event($job_id, 'complete', {
        status   => STATUS_COMPLETED,
        result   => $result,
        duration => $duration,
    });
}

sub fail_job {
    my ($job_id, $error) = @_;

    my $job = $jobs{$job_id} or return;

    delete $running_jobs{$job_id};

    $job->{status} = STATUS_FAILED;
    $job->{error} = $error;
    $job->{completed_at} = time();

    broadcast_queue_event('job_failed', {
        job_id => $job_id,
        error  => $error,
    });

    broadcast_job_event($job_id, 'failed', {
        status => STATUS_FAILED,
        error  => $error,
    });
}

#
# Progress Tracking
#

sub update_progress {
    my ($job_id, $percent, $message) = @_;

    my $job = $jobs{$job_id} or return;

    $job->{progress} = {
        percent => $percent,
        message => $message,
    };

    broadcast_queue_event('job_progress', {
        job_id  => $job_id,
        percent => $percent,
        message => $message,
    });

    broadcast_job_event($job_id, 'progress', {
        percent => $percent,
        message => $message,
    });
}

sub get_progress {
    my ($job_id) = @_;

    my $job = $jobs{$job_id} or return;
    return $job->{progress};
}

#
# Queue Subscribers (for WebSocket clients watching the queue)
#

sub add_queue_subscriber {
    my ($id, $send_cb) = @_;

    $queue_subscribers{$id} = $send_cb;
}

sub remove_queue_subscriber {
    my ($id) = @_;

    delete $queue_subscribers{$id};
}

sub broadcast_queue_event {
    my ($event_type, $data) = @_;

    for my $id (keys %queue_subscribers) {
        my $send_cb = $queue_subscribers{$id};
        next unless $send_cb;

        eval {
            $send_cb->({
                type => $event_type,
                data => $data,
            });
        };

        if ($@) {
            # Remove dead subscriber
            delete $queue_subscribers{$id};
        }
    }
}

#
# Job Subscribers (for SSE clients watching specific jobs)
#

sub add_job_subscriber {
    my ($job_id, $subscriber_id, $send_cb) = @_;

    $job_subscribers{$job_id} //= {};
    $job_subscribers{$job_id}{$subscriber_id} = $send_cb;
}

sub remove_job_subscriber {
    my ($job_id, $subscriber_id) = @_;

    return unless $job_subscribers{$job_id};
    delete $job_subscribers{$job_id}{$subscriber_id};

    # Clean up empty subscriber lists
    delete $job_subscribers{$job_id} unless keys %{$job_subscribers{$job_id}};
}

sub broadcast_job_event {
    my ($job_id, $event_type, $data) = @_;

    my $subs = $job_subscribers{$job_id} or return;

    for my $id (keys %$subs) {
        my $send_cb = $subs->{$id};
        next unless $send_cb;

        eval {
            $send_cb->($event_type, $data);
        };

        if ($@) {
            delete $subs->{$id};
        }
    }
}

#
# Statistics
#

sub get_queue_stats {
    my () = @_;

    my $pending   = scalar @pending_queue;
    my $running   = scalar keys %running_jobs;
    my $completed = 0;
    my $failed    = 0;
    my $cancelled = 0;

    for my $job (values %jobs) {
        $completed++ if $job->{status} eq STATUS_COMPLETED;
        $failed++    if $job->{status} eq STATUS_FAILED;
        $cancelled++ if $job->{status} eq STATUS_CANCELLED;
    }

    return {
        pending   => $pending,
        running   => $running,
        completed => $completed,
        failed    => $failed,
        cancelled => $cancelled,
        total     => scalar keys %jobs,
    };
}

sub clear_completed_jobs {
    my () = @_;

    my @to_delete;

    for my $job_id (keys %jobs) {
        my $job = $jobs{$job_id};
        if ($job->{status} eq STATUS_COMPLETED
            || $job->{status} eq STATUS_FAILED
            || $job->{status} eq STATUS_CANCELLED) {
            push @to_delete, $job_id;
        }
    }

    delete $jobs{$_} for @to_delete;

    broadcast_queue_event('jobs_cleared', { count => scalar @to_delete });

    return scalar @to_delete;
}

#
# Helper Functions
#

sub _job_summary {
    my ($job) = @_;

    return {
        id         => $job->{id},
        type       => $job->{type},
        params     => $job->{params},
        status     => $job->{status},
        progress   => $job->{progress},
        result     => $job->{result},
        error      => $job->{error},
        created_at => $job->{created_at},
        started_at => $job->{started_at},
        completed_at => $job->{completed_at},
    };
}

1;

__END__

# NAME

JobRunner::Queue - Job queue state management

# DESCRIPTION

Centralized in-memory storage for all job state. Handles job lifecycle,
progress tracking, and broadcasting updates to subscribers.

## Job Statuses

- **pending** - In queue, waiting to be picked up
- **running** - Currently executing
- **completed** - Finished successfully
- **failed** - Finished with error
- **cancelled** - Aborted by user
