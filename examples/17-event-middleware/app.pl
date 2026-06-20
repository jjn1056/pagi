use strict;
use warnings;
use Future::AsyncAwait;
use Future::IO;
use Future::Selector;

# Delivering your own events through $receive -- the composable way.
#
# A middleware owns a periodic event source and wraps the $receive it passes to
# the inner app, so the app's own "tick" events arrive on the SAME channel as the
# protocol events (http.request, http.disconnect). The inner app never reaches
# into shared state for a source: it just awaits the next event and switches on
# its type, exactly as it does for protocol events.
#
# Why this shape (and not a hub the handler pulls from, as in example 14)? Because
# the events ride IN the $receive stream, every other middleware in the stack can
# wrap them too -- log them, gate them, transform them, fold in more. A source the
# handler pulls from a shared object is a side-channel the pipeline cannot see.
# This is exactly what PAGI::Middleware::Channels does for cross-process events.

# A tiny periodic source: a subscriber gets a Future that resolves on the next tick.
package TickHub {
    sub new       { bless { count => 0, waiters => [] }, shift }
    sub next_tick { push @{ $_[0]{waiters} }, my $f = Future->new; return $f }
    sub publish {
        my $self = shift;
        $self->{count}++;
        # Drain in place; ->done on a waiter cancelled by a lost wait_any race is a
        # harmless no-op, so no guard is needed.
        $_->done($self->{count}) for splice @{ $self->{waiters} };
    }
}

# The middleware: owns the source (rooted in lifespan) and folds its events into
# the inner app's $receive.
# Resolve as soon as ANY of the given futures is ready, cancelling none of them.
# (Future->wait_any cancels the losers; cancelling the long-lived $receive would
# end the connection, so we watch each with on_ready instead.)
async sub await_either {
    my @futures = @_;
    my $first = Future->new;
    $_->on_ready(sub { $first->done unless $first->is_ready }) for @futures;
    await $first;
    return;
}

sub with_ticks {
    my ($inner) = @_;
    my $hub;   # created on lifespan startup; one per worker, shared by all scopes

    return async sub {
        my ($scope, $receive, $send) = @_;

        # The middleware owns the lifespan: it starts and runs the ticker here,
        # rooted in this frame, so the inner app never sees lifespan at all.
        if ($scope->{type} eq 'lifespan') {
            $hub = TickHub->new;
            while (1) { last if (await $receive->())->{type} eq 'lifespan.startup' }
            await $send->({ type => 'lifespan.startup.complete' });

            my $selector = Future::Selector->new;
            $selector->add(data => 'ticker', gen => async sub {
                await Future::IO->sleep(2);
                $hub->publish;
                return;
            });
            my $shutdown = (async sub {
                while (1) { return if (await $receive->())->{type} eq 'lifespan.shutdown' }
            })->();
            await Future->wait_any($shutdown, $selector->run);

            await $send->({ type => 'lifespan.shutdown.complete' });
            return;
        }

        # Every other scope: wrap $receive so a tick arrives as an event alongside
        # the protocol events, then hand off to the inner app unchanged. Keep ONE
        # outstanding protocol future across calls and race it with await_either,
        # which never cancels the long-lived $receive (cancelling it would end the
        # stream). When a protocol event fires, consume it and fetch a fresh one.
        my $protocol_f;
        my $wrapped_receive = async sub {
            $protocol_f //= $receive->();    # one outstanding receive, kept alive
            my $tick_f = $hub->next_tick;    # the source's next event
            await await_either($protocol_f, $tick_f);
            if ($protocol_f->is_ready) {     # a protocol event arrived
                my $event = $protocol_f->get;
                undef $protocol_f;           # consumed -> fetch a fresh one next time
                return $event;
            }
            return { type => 'tick', count => $tick_f->get };   # a tick, shaped as an event
        };
        return await $inner->($scope, $wrapped_receive, $send);
    };
}

# The inner app is PURE: it knows nothing about hubs, sources, or state. It awaits
# the next event and switches on type -- a tick and a disconnect arrive the same
# way, through $receive.
my $app = async sub {
    my ($scope, $receive, $send) = @_;
    die "Unsupported scope type: $scope->{type}" if $scope->{type} ne 'http';

    await $send->({
        type    => 'http.response.start',
        status  => 200,
        headers => [ ['content-type', 'application/x-ndjson'] ],
    });

    while (1) {
        my $event = await $receive->();
        if ($event->{type} eq 'tick') {
            await $send->({
                type => 'http.response.body',
                body => qq({"tick":$event->{count}}\n),
                more => 1,
            });
        }
        elsif ($event->{type} eq 'http.disconnect') {
            last;   # client went away -- stop the stream
        }
        # http.request (the request body) is ignored in this demo.
    }
};

with_ticks($app);
