#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;

# Skip if Future::IO is not installed
BEGIN {
    eval { require Future::IO; 1 }
        or plan skip_all => 'Future::IO required for tutorial tests';
}

use Future::AsyncAwait;
use IO::Async::Loop;

# Load the IO::Async implementation for Future::IO
# This is what a PAGI server does at startup
use Future::IO::Impl::IOAsync;

my $loop = IO::Async::Loop->new;

# =============================================================================
# Test: Hello World app (Section 1.3)
# =============================================================================
subtest 'hello world app' => sub {
    my @events;
    my $send = async sub { push @events, shift };
    my $receive = async sub { { type => 'http.request', body => '', more => 0 } };
    my $scope = { type => 'http' };

    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        die "Expected http scope" unless $scope->{type} eq 'http';

        await $send->({
            type => 'http.response.start',
            status => 200,
            headers => [['content-type', 'text/plain']],
        });

        await $send->({
            type => 'http.response.body',
            body => 'Hello, World!',
        });
    };

    $loop->await($app->($scope, $receive, $send));

    is scalar(@events), 2, 'sent 2 events';
    is $events[0]{type}, 'http.response.start', 'first event is response.start';
    is $events[0]{status}, 200, 'status is 200';
    is $events[1]{type}, 'http.response.body', 'second event is response.body';
    is $events[1]{body}, 'Hello, World!', 'body is correct';
};

# =============================================================================
# Test: Future::IO->sleep (Section 1.4)
# =============================================================================
subtest 'Future::IO sleep' => sub {
    use Future::IO;
    use Time::HiRes qw(time);

    my $start = time();
    $loop->await(Future::IO->sleep(0.1));
    my $elapsed = time() - $start;

    # Use Time::HiRes for more accurate timing
    ok $elapsed >= 0.05, "sleep waited at least 0.05 seconds (got $elapsed)";
    ok $elapsed < 2, 'sleep did not wait too long';
};

# =============================================================================
# Test: Non-blocking app with sleep (Section 1.4)
# =============================================================================
subtest 'non-blocking app with sleep' => sub {
    use Future::IO;

    my @events;
    my $send = async sub { push @events, shift };
    my $receive = async sub { { type => 'http.request', body => '', more => 0 } };
    my $scope = { type => 'http' };

    my $app = async sub {
        my ($scope, $receive, $send) = @_;

        # Async sleep (doesn't block) - loop-agnostic!
        await Future::IO->sleep(0.01);

        await $send->({
            type => 'http.response.start',
            status => 200,
            headers => [['content-type', 'text/plain']],
        });

        await $send->({
            type => 'http.response.body',
            body => 'Non-blocking operations completed!',
        });
    };

    $loop->await($app->($scope, $receive, $send));

    is scalar(@events), 2, 'sent 2 events';
    is $events[1]{body}, 'Non-blocking operations completed!', 'body is correct';
};

# =============================================================================
# Test: Reading request body (Section 2.3)
# =============================================================================
subtest 'reading request body' => sub {
    my @events;
    my $send = async sub { push @events, shift };

    my @body_chunks = (
        { type => 'http.request', body => 'Hello, ', more => 1 },
        { type => 'http.request', body => 'PAGI!', more => 0 },
    );
    my $chunk_idx = 0;
    my $receive = async sub { $body_chunks[$chunk_idx++] };
    my $scope = { type => 'http' };

    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        die "Expected http scope" unless $scope->{type} eq 'http';

        my $body = '';
        while (1) {
            my $event = await $receive->();
            $body .= $event->{body} if defined $event->{body};
            last unless $event->{more};
        }

        my $response_body = "You sent: " . (length($body) ? $body : "(empty)");

        await $send->({
            type => 'http.response.start',
            status => 200,
            headers => [['content-type', 'text/plain']],
        });

        await $send->({
            type => 'http.response.body',
            body => $response_body,
        });
    };

    $loop->await($app->($scope, $receive, $send));

    is $events[1]{body}, 'You sent: Hello, PAGI!', 'echoed body correctly';
};

# =============================================================================
# Test: WebSocket echo (Section 2.4)
# =============================================================================
subtest 'websocket echo' => sub {
    my @events;
    my $send = async sub { push @events, shift };

    my @messages = (
        { type => 'websocket.connect' },
        { type => 'websocket.receive', text => 'Hello!' },
        { type => 'websocket.disconnect', code => 1000, reason => 'Normal' },
    );
    my $msg_idx = 0;
    my $receive = async sub { $messages[$msg_idx++] };
    my $scope = { type => 'websocket' };

    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        die "Expected websocket scope" unless $scope->{type} eq 'websocket';

        # Wait for connect
        my $event = await $receive->();

        # Accept
        await $send->({ type => 'websocket.accept' });

        # Echo loop
        while (1) {
            $event = await $receive->();

            if ($event->{type} eq 'websocket.disconnect') {
                last;
            }

            if (defined $event->{text}) {
                await $send->({
                    type => 'websocket.send',
                    text => "Echo: $event->{text}",
                });
            }
        }
    };

    $loop->await($app->($scope, $receive, $send));

    is scalar(@events), 2, 'sent 2 events (accept + echo)';
    is $events[0]{type}, 'websocket.accept', 'first event is accept';
    is $events[1]{type}, 'websocket.send', 'second event is send';
    is $events[1]{text}, 'Echo: Hello!', 'echoed text correctly';
};

# =============================================================================
# Test: Streaming response (Section 2.6)
# =============================================================================
subtest 'streaming response' => sub {
    use Future::IO;

    my @events;
    my $send = async sub { push @events, shift };
    my $receive = async sub { { type => 'http.request', body => '', more => 0 } };
    my $scope = { type => 'http' };

    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        die "Expected http scope" unless $scope->{type} eq 'http';

        await $send->({
            type => 'http.response.start',
            status => 200,
            headers => [['content-type', 'text/plain']],
        });

        # Send 3 chunks with minimal delay
        for my $i (1..3) {
            await $send->({
                type => 'http.response.body',
                body => "Chunk $i\n",
                more => 1,
            });
            await Future::IO->sleep(0.001);  # Minimal delay
        }

        await $send->({
            type => 'http.response.body',
            body => "Done!\n",
        });
    };

    $loop->await($app->($scope, $receive, $send));

    is scalar(@events), 5, 'sent 5 events (start + 3 chunks + final)';
    is $events[1]{body}, "Chunk 1\n", 'first chunk correct';
    is $events[2]{body}, "Chunk 2\n", 'second chunk correct';
    is $events[3]{body}, "Chunk 3\n", 'third chunk correct';
    is $events[4]{body}, "Done!\n", 'final chunk correct';
    is $events[1]{more}, 1, 'chunk 1 has more=1';
    ok !$events[4]{more}, 'final chunk has more=0 or undef';
};

# =============================================================================
# Test: Correct async pattern - awaiting (Section 2.9)
# =============================================================================
subtest 'correct async pattern - await sleep' => sub {
    use Future::IO;

    my @events;
    my $send = async sub { push @events, shift };
    my $scope = { type => 'http' };

    my $app = async sub {
        my ($scope, $receive, $send) = @_;

        # Wait for the delay
        await Future::IO->sleep(0.01);

        # Now send response (still within the app's Future)
        await $send->({
            type => 'http.response.start',
            status => 200,
            headers => [['content-type', 'text/plain']],
        });

        await $send->({
            type => 'http.response.body',
            body => 'Hello after delay',
        });
    };

    $loop->await($app->($scope, undef, $send));

    is scalar(@events), 2, 'sent 2 events after await';
    is $events[1]{body}, 'Hello after delay', 'response sent correctly';
};

done_testing;
