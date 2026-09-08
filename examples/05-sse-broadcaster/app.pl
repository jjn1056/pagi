use strict;
use warnings;
use Future::AsyncAwait;

# Try to load Future::IO for loop-agnostic sleep, fall back to immediate if not available
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

async sub app {
    my ($scope, $receive, $send) = @_;

    die "Unsupported scope type: $scope->{type}" if $scope->{type} ne 'sse';

    await $send->({
        type    => 'sse.start',
        status  => 200,
        headers => [ [ 'content-type', 'text/event-stream' ] ],
    });

    my $disconnect = watch_sse_disconnect($receive);
    my @events = (
        { event => 'tick', data => '1' },
        { event => 'tick', data => '2' },
        { event => 'done', data => 'finished' },
    );

    for my $msg (@events) {
        last if $disconnect->is_ready;
        await maybe_sleep(1);
        await $send->({ type => 'sse.send', %$msg });
    }

    # A finite stream ends with sse.close. Skip it if the client already left:
    # a terminal event after a disconnect would assert a delivery that did not
    # happen.
    await $send->({ type => 'sse.close' }) unless $disconnect->is_ready;

    $disconnect->cancel if $disconnect->can('cancel') && !$disconnect->is_ready;
}

\&app;  # Return coderef when loaded via do
