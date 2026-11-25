use strict;
use warnings;
use Future::AsyncAwait;
use Future::IO;

# SSE with run_until_end: events go out inside it; sse.close goes out after
# it, only if the client is still connected. Query parameters pick a case:
#
#   /?n=3                  a feed of three ticks, then sse.close
#   /                      an endless feed: ends when the client or server does
#   /?n=5&fail=2           the feed's source dies at tick 2
#   /?every=3              a quiet feed: one tick every 3s (server idle timeout)
#   /?size=65536&every=0   big events, as fast as they go (a client that stops reading)
#   /?deadline=2           our own limit: give up after 2 seconds

sub query {
    my ($scope) = @_;
    return map { split /=/, $_, 2 } split /&/, ($scope->{query_string} // '');
}

async sub app {
    my ($scope, $receive, $send) = @_;
    die "Unsupported scope type: $scope->{type}" if $scope->{type} ne 'sse';
    my $conn = $scope->{'pagi.connection'};
    my %q    = query($scope);

    await $send->({ type => 'sse.start', status => 200 });

    # Our own deadline: abort ends the scope, like any other end.
    my $deadline = $q{deadline}
        ? Future::IO->sleep($q{deadline})->on_done(sub { $conn->abort("gave up after $q{deadline}s") })
        : undef;

    my $ticks = 0;

    # The eval is optional. Without it, a failure in the work escapes the
    # app, and the server logs it and ends the stream without sse.close.
    # It's here only to show a failure message of the app's own choosing.
    my $ok = eval {
        await $conn->run_until_end(async sub {
            while (!$q{n} || $ticks < $q{n}) {
                await Future::IO->sleep($q{every} // 0.5);
                die "feed source failed at tick " . ($ticks + 1) . "\n" if $q{fail} && $ticks + 1 == $q{fail};
                $ticks++;
                await $send->({ type => 'sse.send', event => 'tick',
                                data => $q{size} ? 'x' x $q{size} : $ticks });
            }
        });
        1;
    };
    $deadline->cancel if $deadline;

    # The work failed while the client may still be there: say so, in the
    # feed's own terms, and close.
    unless ($ok) {
        warn "feed failed after $ticks ticks: $@";
        if ($conn->is_connected) {
            await $send->({ type => 'sse.send', event => 'error', data => 'feed unavailable' });
            await $send->({ type => 'sse.close' });
        }
        return;
    }

    # The scope ended first. An SSE client can't close politely, so a reason
    # is always set: the client left, a server limit, shutdown, or our abort.
    unless ($conn->is_connected) {
        my $why = $conn->disconnect_reason;
        $why .= " ($_)" for grep { defined } $conn->disconnect_detail;
        warn "feed ended after $ticks ticks: $why\n";
        return;    # no sse.close
    }

    # The feed ran to its end with the client still there.
    await $send->({ type => 'sse.close' });
    warn "feed completed: $ticks ticks\n";
}

\&app;  # Return coderef when loaded via do
