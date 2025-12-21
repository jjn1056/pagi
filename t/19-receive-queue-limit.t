use strict;
use warnings;
use Test2::V0;
use IO::Async::Loop;
use Net::Async::WebSocket::Client;
use Future::AsyncAwait;
use FindBin;
use lib "$FindBin::Bin/../lib";

use PAGI::Server;

my $loop = IO::Async::Loop->new;

# Test: Demonstrate unbounded receive queue with slow consumer
# This test shows the issue where a WebSocket app that doesn't consume
# messages fast enough allows the receive_queue to grow without limit.

subtest 'WebSocket receive queue grows when app does not consume messages' => sub {
    my $queue_size_observed = 0;
    my $messages_sent = 0;
    my $app_started = 0;

    # App that accepts WebSocket but delays consuming messages
    my $slow_app = async sub  {
        my ($scope, $receive, $send) = @_;
        if ($scope->{type} eq 'lifespan') {
            while (1) {
                my $event = await $receive->();
                if ($event->{type} eq 'lifespan.startup') {
                    await $send->({ type => 'lifespan.startup.complete' });
                }
                elsif ($event->{type} eq 'lifespan.shutdown') {
                    await $send->({ type => 'lifespan.shutdown.complete' });
                    last;
                }
            }
            return;
        }

        return unless $scope->{type} eq 'websocket';

        # Accept the WebSocket connection
        await $send->({ type => 'websocket.accept' });
        $app_started = 1;

        # Intentionally delay before starting to consume messages
        # This simulates a slow consumer or an app doing expensive setup
        await $loop->delay_future(after => 0.5);

        # Now consume messages and count how many were queued
        my $count = 0;
        while (1) {
            my $event = await $receive->();
            last if $event->{type} eq 'websocket.disconnect';
            $count++ if $event->{type} eq 'websocket.receive';
        }
        $queue_size_observed = $count;
    };

    my $server = PAGI::Server->new(
        app   => $slow_app,
        host  => '127.0.0.1',
        port  => 0,
        quiet => 1,
    );

    $loop->add($server);
    $server->listen->get;

    my $port = $server->port;

    my $client = Net::Async::WebSocket::Client->new;
    $loop->add($client);

    eval {
        $client->connect(url => "ws://127.0.0.1:$port/")->get;

        # Wait for app to accept the connection
        my $deadline = time + 2;
        while (!$app_started && time < $deadline) {
            $loop->loop_once(0.01);
        }

        # Rapidly send many small messages while app is "busy"
        # These will queue up in receive_queue
        for my $i (1..100) {
            $client->send_text_frame("msg$i");
            $messages_sent++;
            # Small delay to allow frames to be sent
            $loop->loop_once(0.001);
        }

        # Close connection - app will then consume the queued messages
        $client->close;

        # Wait for app to finish processing
        $deadline = time + 3;
        while ($queue_size_observed == 0 && time < $deadline) {
            $loop->loop_once(0.1);
        }
    };

    # The test demonstrates that messages queue up
    # Without a limit, all 100 messages are queued
    ok($messages_sent == 100, "Sent 100 messages");
    ok($queue_size_observed > 0, "App observed queued messages: $queue_size_observed");

    # This is the actual issue: with no limit, queue can grow to any size
    # A production fix would cap this (e.g., max_receive_queue option)
    note("Messages sent: $messages_sent, Queue size observed: $queue_size_observed");

    eval { $loop->remove($client) };  # May already be removed
    $server->shutdown->get;
    eval { $loop->remove($server) };
};

# Test: Verify max_receive_queue limit is enforced
subtest 'max_receive_queue limit closes connection when exceeded' => sub {
    my $app_started = 0;
    my $close_sent = 0;

    # App that accepts WebSocket but NEVER calls receive (simulating frozen app)
    my $non_consuming_app = async sub  {
        my ($scope, $receive, $send) = @_;
        if ($scope->{type} eq 'lifespan') {
            while (1) {
                my $event = await $receive->();
                if ($event->{type} eq 'lifespan.startup') {
                    await $send->({ type => 'lifespan.startup.complete' });
                }
                elsif ($event->{type} eq 'lifespan.shutdown') {
                    await $send->({ type => 'lifespan.shutdown.complete' });
                    last;
                }
            }
            return;
        }

        return unless $scope->{type} eq 'websocket';

        await $send->({ type => 'websocket.accept' });
        $app_started = 1;

        # Simulate slow/frozen processing - sleep instead of consuming
        # The server should close connection when queue fills up
        await $loop->delay_future(after => 5);
    };

    # Instrument _send_close_frame to track when server closes
    {
        no warnings 'redefine';
        my $orig = \&PAGI::Server::Connection::_send_close_frame;
        local *PAGI::Server::Connection::_send_close_frame = sub {
            my ($self, $code, $reason) = @_;
            $close_sent = 1 if $code == 1008;  # Policy violation = queue overflow
            return $orig->($self, $code, $reason);
        };

        # Server with LOW max_receive_queue for testing
        my $server = PAGI::Server->new(
            app               => $non_consuming_app,
            host              => '127.0.0.1',
            port              => 0,
            quiet             => 1,
            max_receive_queue => 5,  # Very low limit for testing
        );

        $loop->add($server);
        $server->listen->get;

        my $port = $server->port;

        my $client = Net::Async::WebSocket::Client->new;
        $loop->add($client);

        eval {
            $client->connect(url => "ws://127.0.0.1:$port/")->get;

            # Wait for app to accept
            my $deadline = time + 2;
            while (!$app_started && time < $deadline) {
                $loop->loop_once(0.01);
            }

            # Send MORE than max_receive_queue messages
            for my $i (1..10) {
                eval { $client->send_text_frame("msg$i") };
                last if $@;
                $loop->loop_once(0.05);
            }

            # Give server time to process and trigger close
            $loop->loop_once(0.5);
        };

        ok($close_sent, "Server sent close frame with code 1008 when queue exceeded");

        eval { $loop->remove($client) };
        $server->shutdown->get;
        eval { $loop->remove($server) };
    }
};

# Test: Verify the queue doesn't prevent normal operation
subtest 'WebSocket works normally with responsive consumer' => sub {
    my @received;

    my $responsive_app = async sub  {
        my ($scope, $receive, $send) = @_;
        if ($scope->{type} eq 'lifespan') {
            while (1) {
                my $event = await $receive->();
                if ($event->{type} eq 'lifespan.startup') {
                    await $send->({ type => 'lifespan.startup.complete' });
                }
                elsif ($event->{type} eq 'lifespan.shutdown') {
                    await $send->({ type => 'lifespan.shutdown.complete' });
                    last;
                }
            }
            return;
        }

        return unless $scope->{type} eq 'websocket';

        await $send->({ type => 'websocket.accept' });

        # Responsive consumer - process messages immediately
        while (1) {
            my $event = await $receive->();
            if ($event->{type} eq 'websocket.disconnect') {
                last;
            }
            if ($event->{type} eq 'websocket.receive') {
                push @received, $event->{text};
                # Echo back immediately
                await $send->({ type => 'websocket.send', text => "ack" });
            }
        }
    };

    my $server = PAGI::Server->new(
        app   => $responsive_app,
        host  => '127.0.0.1',
        port  => 0,
        quiet => 1,
    );

    $loop->add($server);
    $server->listen->get;

    my $port = $server->port;

    my $acks = 0;
    my $client = Net::Async::WebSocket::Client->new(
        on_text_frame => sub {
            my ($self, $text) = @_;
            $acks++ if $text eq 'ack';
        },
    );
    $loop->add($client);

    eval {
        $client->connect(url => "ws://127.0.0.1:$port/")->get;

        # Send messages with small delays
        for my $i (1..10) {
            $client->send_text_frame("msg$i");
            # Allow time for round-trip
            $loop->loop_once(0.05);
        }

        # Wait for all acks
        my $deadline = time + 2;
        while ($acks < 10 && time < $deadline) {
            $loop->loop_once(0.1);
        }

        $client->close;
    };

    is(scalar(@received), 10, "Responsive app received all 10 messages");
    is($acks, 10, "Client received all 10 acks");

    eval { $loop->remove($client) };  # May already be removed
    $server->shutdown->get;
    eval { $loop->remove($server) };
};

done_testing;
