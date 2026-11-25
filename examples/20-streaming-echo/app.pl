use strict;
use warnings;
use Future;
use Future::AsyncAwait;
use Future::IO;

# Streaming in and out at once, over plain HTTP: the client uploads numbers,
# one per line; the server answers each with the running total and, on its
# own, sends a progress tick every second. When the upload ends, the ticker
# stops and the summary goes out.
#
# Both directions run inside one run_until_end, joined with wait_any: the
# upload ending finishes the read branch and wait_any cancels the ticker. If
# the client leaves, run_until_end cancels both. The summary is the ending,
# so it goes out after the call, only if the client is still connected.

async sub app {
    my ($scope, $receive, $send) = @_;
    die "Unsupported scope type: $scope->{type}" if $scope->{type} ne 'http';
    my $conn = $scope->{'pagi.connection'};

    await $send->({
        type    => 'http.response.start',
        status  => 200,
        headers => [ [ 'content-type', 'text/plain' ] ],
    });

    my ($total, $count, $buffer) = (0, 0, '');

    # In: read the upload as it arrives; answer each number.
    my $read = async sub {
        while (1) {
            my $event = await $receive->();
            last if $event->{type} eq 'http.disconnect';
            $buffer .= $event->{body} // '';
            while ($buffer =~ s/\A\s*(-?\d+)\s*\n//) {
                $total += $1;
                $count++;
                await $send->({ type => 'http.response.body', body => "got $1, total $total\n", more => 1 });
            }
            last unless $event->{more};
        }
    };

    # Out: a tick every second, whatever the client is doing.
    my $tick = async sub {
        for (my $n = 1; ; $n++) {
            await Future::IO->sleep(1);
            await $send->({ type => 'http.response.body', body => "tick $n: $count numbers so far\n", more => 1 });
        }
    };

    await $conn->run_until_end(sub { Future->wait_any($read->(), $tick->()) });

    unless ($conn->is_connected) {
        warn "running total stopped after $count numbers: " . $conn->disconnect_reason . "\n";
        return;
    }
    await $send->({ type => 'http.response.body', body => "done: $count numbers, total $total\n", more => 0 });
}

\&app;
