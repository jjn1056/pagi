use strict;
use warnings;
use Future::AsyncAwait;
use experimental 'signatures';

async sub drain_request ($receive) {
    while (1) {
        my $event = await $receive->();
        last if $event->{type} ne 'http.request';
        last unless $event->{more};
    }
}

async sub watch_disconnect ($receive) {
    while (1) {
        my $event = await $receive->();
        return $event if $event->{type} eq 'http.disconnect';
        # Ignore any other post-response events (none expected after draining body)
    }
}

async sub app ($scope, $receive, $send) {
    die "Unsupported scope type: $scope->{type}" if $scope->{type} ne 'http';

    await drain_request($receive);

    await $send->({
        type     => 'http.response.start',
        status   => 200,
        headers  => [ [ 'content-type', 'text/plain' ] ],
        trailers => 1,
    });

    my @chunks = (
        "Chunk 1\n",
        "Chunk 2\n",
        "Chunk 3\n",
    );

    my $disconnect_task = watch_disconnect($receive);

    while (@chunks) {
        last if $disconnect_task->is_ready;
        my $body = shift @chunks;
        await $send->({ type => 'http.response.body', body => $body, more => scalar @chunks ? 1 : 0 });
    }

    if ($disconnect_task->is_ready) {
        warn "client disconnected before trailers";
        return;
    }

    await $send->({
        type    => 'http.response.trailers',
        headers => [ [ 'x-stream-complete', '1' ] ],
    });

    $disconnect_task->cancel if $disconnect_task->can('cancel') && !$disconnect_task->is_ready;
}

\&app;  # Return coderef when loaded via do
