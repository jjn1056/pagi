#!/usr/bin/env perl
#
# Endpoint Demo - Showcasing all three endpoint types with middleware
#
# Run: pagi-server -I lib examples/endpoint-demo/app.pl --port 5000
# Open: http://localhost:5000/
#

use strict;
use warnings;
use Future::AsyncAwait;
use File::Basename qw(dirname);
use File::Spec;
use Time::HiRes qw(time);

use PAGI::App::File;
use PAGI::App::Router;
use PAGI::Middleware::AccessLog;
use PAGI::Response;


#---------------------------------------------------------
# HTTP Endpoint - REST API for messages
#---------------------------------------------------------
package MessageAPI {
    use parent 'PAGI::Endpoint::HTTP';
    use Future::AsyncAwait;

    my @messages = (
        { id => 1, text => 'Hello, World!' },
        { id => 2, text => 'Welcome to PAGI Endpoints' },
    );
    my $next_id = 3;

    async sub get {
        my ($self, $ctx) = @_;
        await $ctx->response->json(\@messages);
    }

    async sub post {
        my ($self, $ctx) = @_;
        my $data = await $ctx->request->json;
        my $message = { id => $next_id++, text => $data->{text} };
        push @messages, $message;

        # Notify SSE subscribers
        MessageEvents::broadcast($message);

        await $ctx->response->status(201)->json($message);
    }
}

#---------------------------------------------------------
# WebSocket Endpoint - Echo chat
#---------------------------------------------------------
package EchoWS {
    use parent 'PAGI::Endpoint::WebSocket';
    use Future::AsyncAwait;

    sub encoding { 'json' }
    sub ping_interval { 25 }  # Keep connection alive

    async sub on_connect {
        my ($self, $ctx) = @_;
        my $ws = $ctx->websocket;
        await $ws->accept;
        await $ws->send_json({ type => 'connected', message => 'Welcome!' });
    }

    async sub on_receive {
        my ($self, $ctx, $data) = @_;
        await $ctx->websocket->send_json({
            type => 'echo',
            original => $data,
            timestamp => time(),
        });
    }

    sub on_disconnect {
        my ($self, $ctx, $code) = @_;
        print STDERR "WebSocket client disconnected: $code\n";
    }
}

#---------------------------------------------------------
# SSE Endpoint - Message notifications
#---------------------------------------------------------
package MessageEvents {
    use parent 'PAGI::Endpoint::SSE';
    use Future::AsyncAwait;

    sub keepalive_interval { 25 } # seconds

    my %subscribers; # In memory so has to be single process, no workers
    my $sub_id = 0;

    sub broadcast {
        my ($message) = @_;
        for my $sse (values %subscribers) {
            $sse->try_send_json($message);
        }
    }

    async sub on_connect {
        my ($self, $ctx) = @_;
        my $sse = $ctx->sse;
        my $id = ++$sub_id;
        $subscribers{$id} = $sse;
        $ctx->stash->set(sub_id => $id);

        await $sse->send_event(
            event => 'connected',
            data  => { subscriber_id => $id },
        );
    }

    sub on_disconnect {
        my ($self, $ctx) = @_;
        my $id = $ctx->stash->get('sub_id', 'unknown');
        delete $subscribers{$id};
    }
}

#---------------------------------------------------------
# Middleware Examples
#---------------------------------------------------------

# 1. PAGI::Middleware instance - request logging
my $access_log = PAGI::Middleware::AccessLog->new(
    format => 'tiny',
    logger => sub { print STDERR @_ },
);

# 2. Coderef middleware - request timing
my $timing = async sub {
    my ($scope, $receive, $send, $next) = @_;
    my $start = time();
    await $next->();
    my $duration = (time() - $start) * 1000;
    warn sprintf "[timing] %s %s %.2fms\n",
        $scope->{method} // 'WS/SSE', $scope->{path}, $duration;
};

# 3. Coderef middleware - JSON content-type validation for POST
my $require_json = async sub {
    my ($scope, $receive, $send, $next) = @_;

    # Only check POST requests
    if (($scope->{method} // '') eq 'POST') {
        my $content_type = '';
        for my $h (@{$scope->{headers} // []}) {
            if (lc($h->[0]) eq 'content-type') {
                $content_type = $h->[1];
                last;
            }
        }

        unless ($content_type =~ m{application/json}i) {
            my $res = PAGI::Response->new($scope, $send);
            await $res->status(415)->json({
                error => 'Content-Type must be application/json'
            });
            return;  # Short-circuit - don't call $next
        }
    }

    await $next->();
};

#---------------------------------------------------------
# Main Router - Unified routing for all protocols
#---------------------------------------------------------
my $router = PAGI::App::Router->new;

# Mount API endpoint with middleware:
# - $access_log: logs each request (PAGI::Middleware instance)
# - $require_json: validates Content-Type for POST (coderef middleware)
$router->mount('/api/messages' => [$access_log, $require_json] => MessageAPI->to_app);

# WebSocket with timing middleware
$router->mount('/ws/echo' => [$access_log, $timing] => EchoWS->to_app);

# SSE with timing middleware
$router->mount('/events' => [$timing] => MessageEvents->to_app);

# Static files as fallback for everything else (no middleware)
$router->mount('/' => PAGI::App::File->new(
    root => File::Spec->catdir(dirname(__FILE__), 'public')
)->to_app);

$router->to_app;
