use strict;
use warnings;
use Future::AsyncAwait;
use experimental 'signatures';

async sub app ($scope, $receive, $send) {
    die "Unsupported scope type: $scope->{type}" if $scope->{type} ne 'websocket';

    my $event = await $receive->();
    die "Expected websocket.connect" if $event->{type} ne 'websocket.connect';

    await $send->({ type => 'websocket.accept' });

    while (1) {
        my $frame = await $receive->();
        if ($frame->{type} eq 'websocket.receive') {
            my %payload;
            if (defined $frame->{text}) {
                $payload{text} = "echo: $frame->{text}";
            }
            elsif (defined $frame->{bytes}) {
                $payload{bytes} = $frame->{bytes};
            }
            else {
                next;
            }
            await $send->({ type => 'websocket.send', %payload });
        }
        elsif ($frame->{type} eq 'websocket.disconnect') {
            last;
        }
    }
}

\&app;  # Return coderef when loaded via do
