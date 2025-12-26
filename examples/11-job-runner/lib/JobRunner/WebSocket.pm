package JobRunner::WebSocket;

use strict;
use warnings;

use Future::AsyncAwait;
use JSON::MaybeXS;
use IO::Async::Loop;
use IO::Async::Timer::Periodic;
use Scalar::Util qw(weaken);

use JobRunner::Queue qw(
    create_job get_job get_all_jobs cancel_job clear_completed_jobs
    get_queue_stats add_queue_subscriber remove_queue_subscriber
);
use JobRunner::Jobs qw(get_job_types validate_job_params);
use JobRunner::Worker qw(get_worker_stats);

my $JSON = JSON::MaybeXS->new->utf8->canonical->allow_nonref;

sub handler {
    return async sub  {
        my ($scope, $receive, $send) = @_;
        # Wait for connection event
        my $event = await $receive->();
        return unless $event->{type} eq 'websocket.connect';

        # Accept connection
        await $send->({ type => 'websocket.accept' });

        # Generate subscriber ID
        my $sub_id = "ws-$$-" . time() . "-" . int(rand(10000));

        # Create send callback for queue events
        my $connected = 1;
        my $weak_send = $send;
        weaken($weak_send);

        my $queue_event_cb = sub  {
        my ($event_data) = @_;
            return unless $connected && $weak_send;
            eval {
                $weak_send->({
                    type => 'websocket.send',
                    text => $JSON->encode($event_data),
                });
            };
        };

        # Subscribe to queue events
        add_queue_subscriber($sub_id, $queue_event_cb);

        # Send initial state
        await _send_full_state($send);

        # Set up ping timer
        my $loop = IO::Async::Loop->new;
        my $ping_timer = IO::Async::Timer::Periodic->new(
            interval => 25,
            on_tick  => sub {
                return unless $connected && $weak_send;
                eval {
                    $weak_send->({
                        type => 'websocket.send',
                        text => $JSON->encode({ type => 'ping', ts => time() }),
                    });
                };
            },
        );
        $loop->add($ping_timer);
        $ping_timer->start;

        # Message loop
        eval {
            while (1) {
                my $event = await $receive->();

                if ($event->{type} eq 'websocket.receive') {
                    if (defined $event->{text}) {
                        await _handle_message($event->{text}, $send);
                    }
                }
                elsif ($event->{type} eq 'websocket.disconnect') {
                    last;
                }
            }
        };
        my $error = $@;

        # Cleanup
        $connected = 0;
        $ping_timer->stop;
        $loop->remove($ping_timer);
        remove_queue_subscriber($sub_id);

        die $error if $error && $error !~ /disconnect|closed/i;
    };
}

async sub _handle_message {
    my ($text, $send) = @_;

    my $msg = eval { $JSON->decode($text) };
    return unless $msg && ref $msg eq 'HASH';

    my $type = $msg->{type} // '';

    if ($type eq 'create_job') {
        await _handle_create_job($msg, $send);
    }
    elsif ($type eq 'cancel_job') {
        await _handle_cancel_job($msg, $send);
    }
    elsif ($type eq 'clear_completed') {
        await _handle_clear_completed($send);
    }
    elsif ($type eq 'get_state') {
        await _send_full_state($send);
    }
    elsif ($type eq 'get_job_types') {
        await _send_job_types($send);
    }
    elsif ($type eq 'ping') {
        await _send_json($send, { type => 'pong', ts => $msg->{ts} });
    }
    elsif ($type eq 'pong') {
        # Response to our ping - nothing to do
    }
}

async sub _handle_create_job {
    my ($msg, $send) = @_;

    my $job_type = $msg->{job_type};
    my $params = $msg->{params} // {};

    unless ($job_type) {
        return await _send_json($send, {
            type    => 'error',
            message => "Missing 'job_type' field",
        });
    }

    # Validate parameters
    my ($valid, $error, $normalized_params) = validate_job_params($job_type, $params);
    unless ($valid) {
        return await _send_json($send, {
            type    => 'error',
            message => $error,
        });
    }

    # Create job (queue will broadcast job_created event)
    my $job_id = create_job($job_type, $normalized_params);

    await _send_json($send, {
        type   => 'job_created_ack',
        job_id => $job_id,
    });
}

async sub _handle_cancel_job {
    my ($msg, $send) = @_;

    my $job_id = $msg->{job_id};

    unless ($job_id) {
        return await _send_json($send, {
            type    => 'error',
            message => "Missing 'job_id' field",
        });
    }

    my $success = cancel_job($job_id);

    if ($success) {
        await _send_json($send, {
            type    => 'job_cancelled_ack',
            job_id  => $job_id,
            success => JSON::MaybeXS::true,
        });
    } else {
        my $job = get_job($job_id);
        await _send_json($send, {
            type    => 'error',
            message => $job
                ? "Cannot cancel job in status: $job->{status}"
                : "Job not found: $job_id",
        });
    }
}

async sub _handle_clear_completed {
    my ($send) = @_;

    my $count = clear_completed_jobs();
    await _send_json($send, {
        type    => 'jobs_cleared_ack',
        cleared => $count,
    });
}

async sub _send_full_state {
    my ($send) = @_;

    await _send_json($send, {
        type      => 'queue_state',
        jobs      => get_all_jobs(),
        stats     => get_queue_stats(),
        worker    => get_worker_stats(),
        job_types => get_job_types(),
    });
}

async sub _send_job_types {
    my ($send) = @_;

    await _send_json($send, {
        type      => 'job_types',
        job_types => get_job_types(),
    });
}

async sub _send_json {
    my ($send, $data) = @_;

    await $send->({
        type => 'websocket.send',
        text => $JSON->encode($data),
    });
}

1;

__END__

# NAME

JobRunner::WebSocket - Real-time queue management via WebSocket

# DESCRIPTION

Provides real-time queue updates and admin commands via WebSocket.

## Server -> Client Messages

- **queue_state** - Full queue state on connect
- **job_created** - New job added to queue
- **job_started** - Job started executing
- **job_progress** - Job progress update
- **job_completed** - Job completed successfully
- **job_failed** - Job failed
- **job_cancelled** - Job was cancelled
- **jobs_cleared** - Completed jobs cleared
- **ping** - Server heartbeat

## Client -> Server Messages

- **create_job** - Create new job { job_type, params }
- **cancel_job** - Cancel job { job_id }
- **clear_completed** - Clear completed jobs
- **get_state** - Request full state
- **get_job_types** - Request job types
- **ping/pong** - Heartbeat
