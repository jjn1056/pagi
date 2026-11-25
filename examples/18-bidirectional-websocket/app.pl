use strict;
use warnings;
use Future;
use Future::AsyncAwait;
use Future::IO;

# Bidirectional WebSocket: send AND receive at the same time.
#
# After accepting, the handler runs TWO concurrent branches on the one
# connection:
#
#   - incoming: read client messages and echo them back (uppercased)
#   - outgoing: push an unsolicited server "tick" every second, unprompted
#
# Both run at once -- $receive and $send are independent -- so the client sees
# server ticks interleaved with echoes of whatever it types. This is the
# tree-of-futures idea applied to one connection: a node with two branches the
# loop turns concurrently, joined with wait_any, inside run_until_end on the
# connection object. When the client leaves, the server ends the scope and
# cancels both branches.

async sub app {
    my ($scope, $receive, $send) = @_;
    die "Unsupported scope type: $scope->{type}" if $scope->{type} ne 'websocket';
    my $conn = $scope->{'pagi.connection'};

    my $event = await $receive->();
    die "Expected websocket.connect" if $event->{type} ne 'websocket.connect';
    await $send->({ type => 'websocket.accept' });

    # Branch 1: receive client messages, echo them back (uppercased for fun).
    my $incoming = async sub {
        while (1) {
            my $frame = await $receive->();
            last if $frame->{type} eq 'websocket.disconnect';
            next unless $frame->{type} eq 'websocket.receive' && defined $frame->{text};
            await $send->({ type => 'websocket.send', text => "you said: \U$frame->{text}" });
        }
    };

    # Branch 2: push a server tick every second -- without waiting to be asked.
    my $outgoing = async sub {
        my $n = 0;
        while (1) {
            await Future::IO->sleep(1);
            $n++;
            await $send->({ type => 'websocket.send', text => "server tick #$n" });
        }
    };

    # Run both directions at once, while the client is connected. The branches
    # start inside run_until_end, so the client leaving cancels both. wait_any
    # cancels the loser too: a disconnect ends `incoming`, and the `outgoing`
    # tick-loop goes with it. (Contrast the receive-multiplex in examples
    # 14/17, which keep one live $receive across ticks with an on_ready race.
    # Here the losers are our own branches, so cancelling is the goal.)
    #
    # Only the client ends this session, so there is no ending to send after
    # the call: by then the socket has closed.
    await $conn->run_until_end(sub { Future->wait_any($incoming->(), $outgoing->()) });
}

\&app;  # Return coderef when loaded via do
