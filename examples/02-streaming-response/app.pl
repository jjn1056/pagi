# Streaming Response Example
#
# Demonstrates chunked transfer encoding with trailers.
# Test with: curl -N http://localhost:5000/
#
# Note: Safari buffers chunked responses until complete (WebKit limitation).
# Use SSE or WebSockets for cross-browser progressive rendering.

use strict;
use warnings;
use Future::AsyncAwait;
use Future::IO;

# Drain the request body - keeps reading http.request events until
# we get one with more => 0 (end of body) or a non-request event.
# The await yields control to the event loop - this is NOT blocking.
async sub drain_request {
    my ($receive) = @_;

    while (1) {
        my $event = await $receive->();
        # Exit if not a request event (e.g., http.disconnect)
        last if $event->{type} ne 'http.request';
        # Exit if this is the final body chunk
        last unless $event->{more};
    }
}

async sub app {
    my ($scope, $receive, $send) = @_;

    die "Unsupported scope type: $scope->{type}" if $scope->{type} ne 'http';
    my $conn = $scope->{'pagi.connection'};

    # First, drain any request body
    await drain_request($receive);

    # Start the response with chunked encoding and trailers
    await $send->({
        type     => 'http.response.start',
        status   => 200,
        headers  => [ [ 'content-type', 'text/plain' ] ],
        trailers => 1,
    });

    # The body is the work. run_until_end runs it while the request is open:
    # if the client leaves, the work is cancelled at its next await (a send
    # or the sleep) and run_until_end resolves with 0.
    my $completed = await $conn->run_until_end(async sub {
        for my $n (1 .. 3) {
            await Future::IO->sleep(1) if $n > 1;
            await $send->({ type => 'http.response.body', body => "Chunk $n\n", more => 1 });
        }
    });

    # The end of the response, and its trailer, say the body is complete, so
    # they go only when the work produced all of it.
    unless ($completed) {
        warn "Client left early: " . ($conn->disconnect_reason // 'unknown') . "\n";
        return;
    }
    await $send->({ type => 'http.response.body', body => '', more => 0 });
    await $send->({
        type    => 'http.response.trailers',
        headers => [ [ 'x-stream-complete', '1' ] ],
    });
}

\&app;
