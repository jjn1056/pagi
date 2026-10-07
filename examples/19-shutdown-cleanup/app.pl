use strict;
use warnings;
use Future::AsyncAwait;
use Future::IO;

# Cleaning up when the server shuts down.
#
# Each WebSocket connection keeps a little state (here, the messages it
# received). When the connection ends -- the client leaves, or the server
# shuts down -- the app saves that state before it returns. Saving is
# asynchronous (a database, a remote service); the 0.2 s sleep in save_session
# stands in for that latency.
#
# On shutdown the server closes each WebSocket with code 1012 ("Service
# Restart") and reason server_shutdown, waits (up to its shutdown_timeout) for
# each app call to return, and only then sends lifespan.shutdown -- so every
# session is saved before the process exits.
#
# Run:    pagi-server --app examples/19-shutdown-cleanup/app.pl --port 5000
# Try:    websocat ws://127.0.0.1:5000/   (type a few lines), then Ctrl-C the
#         server: each session is saved, then the shutdown summary prints.

my $saved = 0;

# Stands in for an asynchronous store.
async sub save_session {
    my ($id, $messages) = @_;
    await Future::IO->sleep(0.2);
    $saved++;
    print STDERR "session $id: saved ", scalar(@$messages), " message(s)\n";
}

async sub handle_lifespan {
    my ($scope, $receive, $send) = @_;
    while (1) {
        my $event = await $receive->();
        if ($event->{type} eq 'lifespan.startup') {
            await $send->({ type => 'lifespan.startup.complete' });
        }
        elsif ($event->{type} eq 'lifespan.shutdown') {
            # Every connection's app has returned by now: its session is saved.
            print STDERR "shutdown: $saved session(s) saved\n";
            await $send->({ type => 'lifespan.shutdown.complete' });
            return;
        }
    }
}

my $next_id = 0;

async sub handle_websocket {
    my ($scope, $receive, $send) = @_;
    my $id = ++$next_id;
    my @messages;

    await $receive->();                                  # websocket.connect
    await $send->({ type => 'websocket.accept' });

    while (1) {
        my $event = await $receive->();
        if ($event->{type} eq 'websocket.receive') {
            push @messages, $event->{text} // '';
            await $send->({ type => 'websocket.send', text => "noted: " . scalar(@messages) });
        }
        elsif ($event->{type} eq 'websocket.disconnect') {
            # code 1012 / reason server_shutdown: the server is restarting.
            my $why = ($event->{reason} // '') eq 'server_shutdown' ? 'server shutdown' : 'client left';
            print STDERR "session $id: ended ($why, code $event->{code})\n";
            await save_session($id, \@messages);
            return;
        }
    }
}

my $app = async sub {
    my ($scope, $receive, $send) = @_;
    return await handle_lifespan($scope, $receive, $send)  if $scope->{type} eq 'lifespan';
    return await handle_websocket($scope, $receive, $send) if $scope->{type} eq 'websocket';
    die "Unsupported scope type: $scope->{type}";
};

$app;
