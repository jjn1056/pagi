#!/usr/bin/env perl

use strict;
use warnings;

use Future::AsyncAwait;
use File::Basename;
use File::Spec;
use IO::Async::Loop;

use JobRunner::Queue qw(set_event_loop);
use JobRunner::Worker qw(start_worker stop_worker);
use JobRunner::HTTP;
use JobRunner::SSE;
use JobRunner::WebSocket;

# Determine public directory
my $app_dir = dirname(__FILE__);
my $public_dir = File::Spec->catdir($app_dir, 'public');
JobRunner::HTTP::set_public_dir($public_dir);

# Get handlers
my $http_handler = JobRunner::HTTP::handler();
my $sse_handler = JobRunner::SSE::handler();
my $ws_handler = JobRunner::WebSocket::handler();

# Main application
my $app = async sub  {
        my ($scope, $receive, $send) = @_;
    my $type = $scope->{type};

    if ($type eq 'lifespan') {
        await _handle_lifespan($scope, $receive, $send);
    }
    elsif ($type eq 'http') {
        await $http_handler->($scope, $receive, $send);
    }
    elsif ($type eq 'websocket') {
        await $ws_handler->($scope, $receive, $send);
    }
    elsif ($type eq 'sse') {
        await $sse_handler->($scope, $receive, $send);
    }
    else {
        die "Unsupported scope type: $type";
    }
};

async sub _handle_lifespan {
    my ($scope, $receive, $send) = @_;

    while (1) {
        my $event = await $receive->();
        my $event_type = $event->{type};

        if ($event_type eq 'lifespan.startup') {
            eval {
                my $loop = IO::Async::Loop->new;

                set_event_loop($loop);

                # Start worker with 3 concurrent jobs
                start_worker($loop, 3);

                say "[lifespan] Job Runner started (worker concurrency: 3)";
            };

            if ($@) {
                await $send->({
                    type    => 'lifespan.startup.failed',
                    message => "$@",
                });
                return;
            }

            await $send->({ type => 'lifespan.startup.complete' });
        }
        elsif ($event_type eq 'lifespan.shutdown') {
            eval {
                stop_worker();
                say "[lifespan] Job Runner stopped";
            };

            await $send->({ type => 'lifespan.shutdown.complete' });
            return;
        }
    }
}

$app;
