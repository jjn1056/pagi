use strict;
use warnings;
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
# loop turns concurrently, joined with wait_any. A client disconnect ends the
# `incoming` branch, and wait_any then cancels `outgoing`.

async sub app {
    my ($scope, $receive, $send) = @_;
    die "Unsupported scope type: $scope->{type}" if $scope->{type} ne 'websocket';

    my $event = await $receive->();
    die "Expected websocket.connect" if $event->{type} ne 'websocket.connect';
    await $send->({ type => 'websocket.accept' });

    # Branch 1: receive client messages, echo them back (uppercased for fun).
    my $incoming = (async sub {
        while (1) {
            my $frame = await $receive->();
            last if $frame->{type} eq 'websocket.disconnect';
            next unless $frame->{type} eq 'websocket.receive' && defined $frame->{text};
            await $send->({ type => 'websocket.send', text => "you said: \U$frame->{text}" });
        }
    })->();

    # Branch 2: push a server tick every second -- without waiting to be asked.
    my $outgoing = (async sub {
        my $n = 0;
        while (1) {
            await Future::IO->sleep(1);
            $n++;
            await $send->({ type => 'websocket.send', text => "server tick #$n" });
        }
    })->();

    # Run both directions at once; whichever ends first (a disconnect ends
    # `incoming`) cancels the other.
    await Future->wait_any($incoming, $outgoing);
}

\&app;  # Return coderef when loaded via do
