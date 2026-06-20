use strict;
use warnings;
use Future::AsyncAwait;
use Future::IO;
use JSON::PP ();

# Keep this example's package-level state (the ticker future, below) out of
# main::, which is shared with the server and any other loaded app file.
package PeriodicEvents;

# --- In-app event source -------------------------------------------------
# Every $INTERVAL seconds, produce a result and deliver it to whoever is
# currently listening. The timer is a Future::IO->sleep, so this names no
# event loop: it runs on whatever loop the server is using.
my $INTERVAL = 2;
my $count    = 0;
my @waiters;   # Futures awaiting the next tick

# Keep the source future in a package variable so it is not garbage-collected
# when the app file finishes loading (package variables outlive the do-file scope).
our $TICKER = (async sub {
    while (1) {
        await Future::IO->sleep($INTERVAL);
        $count++;
        my $result = { tick => $count, at => time };
        my @pending = @waiters;
        @waiters = ();
        $_->done($result) for @pending;
    }
})->();
$TICKER->on_fail(sub { warn "periodic source failed: $_[0]\n" });

# --- The PAGI application ------------------------------------------------
my $app = async sub {
    my ($scope, $receive, $send) = @_;

    # Decline any non-HTTP scope (e.g. lifespan) by raising -- a PAGI app signals
    # "I don't handle this scope" with an exception, not a bare return. The server
    # treats a raise on the lifespan scope as "lifespan unsupported" and continues.
    die "Unsupported scope type: $scope->{type}" if $scope->{type} ne 'http';

    if ($scope->{path} eq '/next') {
        # "Listen" for the next event: await a Future the source resolves.
        # Non-blocking -- other requests are served while this one waits.
        my $f = Future->new;
        push @waiters, $f;
        await reply($send, 200, await $f);
    }
    else {
        await reply($send, 200,
            { count => $count, hint => 'GET /next to wait for the next tick' });
    }
};

async sub reply {
    my ($send, $status, $data) = @_;
    await $send->({
        type    => 'http.response.start',
        status  => $status,
        headers => [ ['content-type', 'application/json'] ],
    });
    await $send->({
        type => 'http.response.body',
        body => JSON::PP::encode_json($data),
    });
}

$app;
