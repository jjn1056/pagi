use strict;
use warnings;
use Future::AsyncAwait;

# Conflation under backpressure with pagi.transport.
#
# A high-frequency SSE feed that SKIPS stale readings when the client falls
# behind, so a slow client always receives the freshest one instead of a growing
# backlog of old ones. pagi.transport is the server-side analogue of the
# browser's WebSocket.bufferedAmount.
#
# See PAGI::Cookbook ("Flow Control") and PAGI::Spec::Www ("Transport Flow
# Control"). With a fast client nothing is skipped; throttle the client (see the
# README) to watch the feed conflate.

# Loop-agnostic sleep, with a graceful fallback if Future::IO isn't installed.
my $HAS_FUTURE_IO = eval { require Future::IO; 1 };

sub maybe_sleep {
    my ($seconds) = @_;
    return $HAS_FUTURE_IO ? Future::IO->sleep($seconds) : Future->done;
}

async sub watch_sse_disconnect {
    my ($receive) = @_;
    while (1) {
        my $event = await $receive->();
        return $event if $event->{type} eq 'sse.disconnect';
    }
}

# Stand-in for a real high-frequency source (market data, a sensor, a metrics
# stream): a fresh reading every 20ms, padded to ~2KB so a throttled client
# builds a visible backlog within a few seconds.
async sub current_reading {
    await maybe_sleep(0.02);
    return scalar(localtime) . ' ' . ('.' x 2000);
}

async sub app {
    my ($scope, $receive, $send) = @_;

    die "Unsupported scope type: $scope->{type}" if $scope->{type} ne 'sse';

    await $send->({
        type    => 'sse.start',
        status  => 200,
        headers => [ [ 'content-type', 'text/event-stream' ] ],
    });

    my $transport  = $scope->{'pagi.transport'};   # undef if the server can't measure
    my $disconnect = watch_sse_disconnect($receive);

    my ($sent, $skipped, $iter) = (0, 0, 0);

    until ($disconnect->is_ready) {
        my $reading = await current_reading();
        $iter++;

        # Conflate: skip this reading if the client is already behind -- it will
        # get the next, fresher one. Threshold relative to the server's own
        # ceiling rather than a hard-coded byte count.
        my $behind = 0;
        if ($transport) {
            my $ceiling = $transport->high_water_mark // 65536;
            $behind = $transport->buffered_amount > $ceiling / 2;
        }

        if ($behind) {
            $skipped++;
        }
        else {
            $sent++;
            await $send->({ type => 'sse.send', event => 'reading', data => $reading });
        }

        # Log a summary roughly once a second so you can watch it conflate.
        warn sprintf "[%s] sent=%d skipped=%d buffered=%d\n",
            ($behind ? 'CONFLATING' : 'healthy'),
            $sent, $skipped,
            ($transport ? $transport->buffered_amount : 0)
            if $iter % 50 == 0;
    }
}

\&app;  # Return coderef when loaded via do
