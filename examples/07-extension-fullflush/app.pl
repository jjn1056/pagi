use strict;
use warnings;
use Future::AsyncAwait;
use experimental 'signatures';

# Demonstrates fullflush extension during streaming response.
# The fullflush event forces immediate TCP buffer flush, useful for
# Server-Sent Events or real-time streaming where latency matters.

async sub app ($scope, $receive, $send) {
    die "Unsupported scope type: $scope->{type}" if $scope->{type} ne 'http';

    # Drain request body if present
    while (1) {
        my $event = await $receive->();
        last if $event->{type} ne 'http.request';
        last unless $event->{more};
    }

    # Check if server supports fullflush extension
    my $supports_fullflush = exists $scope->{extensions}{fullflush};

    await $send->({
        type    => 'http.response.start',
        status  => 200,
        headers => [ [ 'content-type', 'text/plain' ] ],
    });

    # Stream chunks with flush after each (if supported)
    my @chunks = ("Line 1\n", "Line 2\n", "Line 3\n");

    for my $i (0 .. $#chunks) {
        my $is_last = ($i == $#chunks);
        await $send->({
            type => 'http.response.body',
            body => $chunks[$i],
            more => $is_last ? 0 : 1,
        });

        # Flush immediately after each chunk so client sees it right away
        # Only send if server advertises support and not the final chunk
        if ($supports_fullflush && !$is_last) {
            await $send->({ type => 'http.fullflush' });
        }
    }
}

\&app;  # Return coderef when loaded via do
