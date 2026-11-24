use strict;
use warnings;
use Future::AsyncAwait;

# Try to load Future::IO for loop-agnostic sleep, fall back to immediate if not available
my $HAS_FUTURE_IO = eval { require Future::IO; 1 };

sub maybe_sleep {
    my ($seconds) = @_;
    return $HAS_FUTURE_IO ? Future::IO->sleep($seconds) : Future->done;
}

async sub app {
    my ($scope, $receive, $send) = @_;

    die "Unsupported scope type: $scope->{type}" if $scope->{type} ne 'sse';
    my $conn = $scope->{'pagi.connection'};

    await $send->({
        type    => 'sse.start',
        status  => 200,
        headers => [ [ 'content-type', 'text/event-stream' ] ],
    });

    my @events = (
        { event => 'tick', data => '1' },
        { event => 'tick', data => '2' },
        { event => 'done', data => 'finished' },
    );

    # Send the events while the client is connected. If it leaves, the work
    # is cancelled at its next await and run_until_end returns nothing.
    my ($finished) = await $conn->run_until_end(async sub {
        for my $msg (@events) {
            await maybe_sleep(1);
            await $send->({ type => 'sse.send', %$msg });
        }
        return 1;
    });

    # A finite stream ends with sse.close, sent only when every event went:
    # a stream cut short by the client leaving does not claim to be complete.
    await $send->({ type => 'sse.close' }) if $finished;
}

\&app;  # Return coderef when loaded via do
