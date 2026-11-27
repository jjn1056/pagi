use strict;
use warnings;
use Future::AsyncAwait;

# WebSocket echo with run_until_end: each message comes straight back, text
# as text and binary as binary. Sending "bye" ends the session from the
# server's side: the Close goes out after the call, only if the client is
# still connected. When the client closes or drops, there's nothing to send.

async sub app {
    my ($scope, $receive, $send) = @_;
    die "Unsupported scope type: $scope->{type}" if $scope->{type} ne 'websocket';
    my $conn = $scope->{'pagi.connection'};

    my $event = await $receive->();
    return unless $event->{type} eq 'websocket.connect';    # or the client left during the handshake
    await $send->({ type => 'websocket.accept' });

    await $conn->run_until_end(async sub {
        while (1) {
            my $frame = await $receive->();
            last if $frame->{type} eq 'websocket.disconnect';    # the client closed
            last if ($frame->{text} // '') eq 'bye';              # we're done
            my %payload = defined $frame->{text} ? (text => $frame->{text}) : (bytes => $frame->{bytes});
            await $send->({ type => 'websocket.send', %payload });
        }
    });

    unless ($conn->is_connected) {
        my $reason = $conn->disconnect_reason;
        warn defined $reason ? "session ended: $reason\n"
                             : "client closed: code " . ($conn->close_code // 'none') . "\n";
        return;
    }
    await $send->({ type => 'websocket.close', code => 1000 });
    warn "session ended: we said goodbye\n";
}

\&app;  # Return coderef when loaded via do
