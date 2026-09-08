package JobRunner::SSE;

use strict;
use warnings;

use Future::AsyncAwait;
use Future;
use JSON::MaybeXS;

use JobRunner::Queue qw(
    get_job add_job_subscriber remove_job_subscriber
);

my $JSON = JSON::MaybeXS->new->utf8->canonical->allow_nonref;

sub handler {
    return async sub  {
        my ($scope, $receive, $send) = @_;
        # Extract job ID from path: /api/jobs/:id/progress
        my $path = $scope->{path};
        my ($job_id) = $path =~ m{/api/jobs/(\d+)/progress};

        # An sse scope is an ordinary HTTP request until sse.start, so a bad
        # request is refused with an ordinary HTTP response.
        unless ($job_id) {
            await $send->({
                type    => 'http.response.start',
                status  => 400,
                headers => [['content-type', 'text/plain']],
            });
            await $send->({ type => 'http.response.body', body => 'Invalid job ID' });
            return;
        }

        # Check if job exists
        my $job = get_job($job_id);
        unless ($job) {
            await $send->({
                type    => 'http.response.start',
                status  => 404,
                headers => [['content-type', 'text/plain']],
            });
            await $send->({ type => 'http.response.body', body => 'Job not found' });
            return;
        }

        # Start SSE stream
        await $send->({
            type    => 'sse.start',
            status  => 200,
            headers => [
                ['cache-control', 'no-cache'],
                ['x-accel-buffering', 'no'],
            ],
        });

        # Generate subscriber ID
        my $sub_id = "sse-$$-" . time() . "-" . int(rand(10000));

        # Send current job state
        await _send_job_status($send, $job);

        # If the job is already finished, send its final event and close
        if ($job->{status} =~ /^(completed|failed|cancelled)$/) {
            await _send_final_event($send, $job);
            await $send->({ type => 'sse.close', reason => "job_$job->{status}" });
            return;
        }

        # The stream ends either because the client left (on_disconnect) or
        # because the job finished and the callback below closed it
        # (on_complete). Exactly one of the two fires.
        my $conn      = $scope->{'pagi.connection'};
        my $ended     = Future->new;
        my $connected = 1;
        $conn->on_disconnect(sub { $connected = 0; $ended->done unless $ended->is_ready });
        $conn->on_complete(sub  { $connected = 0; $ended->done unless $ended->is_ready });

        # Job events arrive from the queue; final ones end the stream
        my %final = map { $_ => 1 } qw(complete failed cancelled);
        my $event_cb = sub  {
            my ($event_type, $data) = @_;
            return unless $connected;

            eval {
                my $sent = $send->({
                    type  => 'sse.send',
                    event => $event_type,
                    data  => $JSON->encode($data),
                });
                if ($final{$event_type}) {
                    $connected = 0;
                    $sent->then(sub {
                        $send->({ type => 'sse.close', reason => "job_$event_type" });
                    })->retain;
                }
            };
        };

        # Subscribe to job events
        add_job_subscriber($job_id, $sub_id, $event_cb);

        # Wait for the stream to end
        await $ended;

        # Cleanup
        $connected = 0;
        remove_job_subscriber($job_id, $sub_id);
    };
}

async sub _send_job_status {
    my ($send, $job) = @_;

    await $send->({
        type  => 'sse.send',
        event => 'status',
        data  => $JSON->encode({
            id         => $job->{id},
            type       => $job->{type},
            status     => $job->{status},
            progress   => $job->{progress},
            started_at => $job->{started_at},
        }),
    });
}

async sub _send_final_event {
    my ($send, $job) = @_;

    my $event_type;
    my $data = { status => $job->{status} };

    if ($job->{status} eq 'completed') {
        $event_type = 'complete';
        $data->{result} = $job->{result};
        $data->{duration} = $job->{completed_at} - ($job->{started_at} // $job->{created_at});
    }
    elsif ($job->{status} eq 'failed') {
        $event_type = 'failed';
        $data->{error} = $job->{error};
    }
    elsif ($job->{status} eq 'cancelled') {
        $event_type = 'cancelled';
    }

    await $send->({
        type  => 'sse.send',
        event => $event_type,
        data  => $JSON->encode($data),
    });
}

1;

__END__

# NAME

JobRunner::SSE - Server-Sent Events for job progress streaming

# DESCRIPTION

Provides real-time progress streaming for individual jobs via SSE.

## Endpoint

GET /api/jobs/:id/progress

## Events

- **status** - Initial job status on connection
- **progress** - Progress update { percent, message }
- **complete** - Job completed successfully { status, result, duration }
- **failed** - Job failed { status, error }
- **cancelled** - Job was cancelled { status }
