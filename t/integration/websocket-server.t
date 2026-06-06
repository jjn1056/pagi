#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use IO::Async::Loop;
use Net::Async::WebSocket::Client;
use Future::AsyncAwait;
use FindBin;
use lib "$FindBin::Bin/../../lib";

use PAGI::Server;
use PAGI::WebSocket;

my $loop = IO::Async::Loop->new;

sub create_server {
    my ($app) = @_;

    my $server = PAGI::Server->new(
        app   => $app,
        host  => '127.0.0.1',
        port  => 0,
        quiet => 1,
    );

    $loop->add($server);
    $server->listen->get;

    return $server;
}

subtest 'PAGI::WebSocket echo app' => sub {
    my $app = async sub {
        my ($scope, $receive, $send) = @_;

        if ($scope->{type} eq 'lifespan') {
            while (1) {
                my $event = await $receive->();
                if ($event->{type} eq 'lifespan.startup') {
                    await $send->({ type => 'lifespan.startup.complete' });
                } elsif ($event->{type} eq 'lifespan.shutdown') {
                    await $send->({ type => 'lifespan.shutdown.complete' });
                    last;
                }
            }
            return;
        }

        my $ws = PAGI::WebSocket->new($scope, $receive, $send);
        await $ws->accept;

        await $ws->each_text(async sub {
            my ($text) = @_;
            await $ws->send_text("echo: $text");
        });
    };

    my $server = create_server($app);
    my $port = $server->port;

    my @received;
    my $client = Net::Async::WebSocket::Client->new(
        on_text_frame => sub {
            my ($self, $text) = @_;
            push @received, $text;
        },
    );

    $loop->add($client);

    eval {
        $client->connect(url => "ws://127.0.0.1:$port/")->get;
        $client->send_text_frame("Hello");
        $client->send_text_frame("World");

        my $deadline = time + 5;
        while (@received < 2 && time < $deadline) {
            $loop->loop_once(0.1);
        }

        $client->close;
    };

    is(\@received, ['echo: Hello', 'echo: World'], 'echo app works');

    $server->shutdown->get;
};

subtest 'PAGI::WebSocket JSON echo app' => sub {
    my $app = async sub {
        my ($scope, $receive, $send) = @_;

        if ($scope->{type} eq 'lifespan') {
            while (1) {
                my $event = await $receive->();
                if ($event->{type} eq 'lifespan.startup') {
                    await $send->({ type => 'lifespan.startup.complete' });
                } elsif ($event->{type} eq 'lifespan.shutdown') {
                    await $send->({ type => 'lifespan.shutdown.complete' });
                    last;
                }
            }
            return;
        }

        my $ws = PAGI::WebSocket->new($scope, $receive, $send);
        await $ws->accept;

        await $ws->each_json(async sub {
            my ($data) = @_;
            $data->{echoed} = 1;
            await $ws->send_json($data);
        });
    };

    my $server = create_server($app);
    my $port = $server->port;

    my @received;
    my $client = Net::Async::WebSocket::Client->new(
        on_text_frame => sub {
            my ($self, $text) = @_;
            push @received, $text;
        },
    );

    $loop->add($client);

    eval {
        $client->connect(url => "ws://127.0.0.1:$port/")->get;
        $client->send_text_frame('{"msg":"test"}');

        my $deadline = time + 5;
        while (@received < 1 && time < $deadline) {
            $loop->loop_once(0.1);
        }

        $client->close;
    };

    use JSON::MaybeXS;
    my $response = decode_json($received[0]);
    is($response->{msg}, 'test', 'original data preserved');
    is($response->{echoed}, 1, 'echoed flag added');

    $server->shutdown->get;
};

subtest 'on_close runs on client disconnect' => sub {
    my $cleanup_ran = 0;

    my $app = async sub {
        my ($scope, $receive, $send) = @_;

        if ($scope->{type} eq 'lifespan') {
            while (1) {
                my $event = await $receive->();
                if ($event->{type} eq 'lifespan.startup') {
                    await $send->({ type => 'lifespan.startup.complete' });
                } elsif ($event->{type} eq 'lifespan.shutdown') {
                    await $send->({ type => 'lifespan.shutdown.complete' });
                    last;
                }
            }
            return;
        }

        my $ws = PAGI::WebSocket->new($scope, $receive, $send);
        await $ws->accept;

        $ws->on_close(async sub {
            $cleanup_ran = 1;
        });

        await $ws->each_text(async sub {});
    };

    my $server = create_server($app);
    my $port = $server->port;

    my $client = Net::Async::WebSocket::Client->new;
    $loop->add($client);

    eval {
        $client->connect(url => "ws://127.0.0.1:$port/")->get;
        $client->send_text_frame("test");
        $loop->loop_once(0.1);
        $client->close;

        # Wait for cleanup
        my $deadline = time + 3;
        while (!$cleanup_ran && time < $deadline) {
            $loop->loop_once(0.1);
        }
    };

    ok($cleanup_ran, 'on_close ran on client disconnect');

    $server->shutdown->get;
};

done_testing;
