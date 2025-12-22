#!/usr/bin/env perl
#
# Endpoint Demo - Showcasing all three endpoint types
#
# Run: pagi-server --app examples/endpoint-demo/app.pl --port 5000
# Open: http://localhost:5000/
#

use strict;
use warnings;
use Future::AsyncAwait;
use File::Basename qw(dirname);
use File::Spec;

use lib 'lib';
use PAGI::App::File;

#---------------------------------------------------------
# HTTP Endpoint - REST API for messages
#---------------------------------------------------------
package MessageAPI {
    use parent 'PAGI::Endpoint::HTTP';
    use v5.32;
    use feature 'signatures';
    no warnings 'experimental::signatures';
    use Future::AsyncAwait;

    my @messages = (
        { id => 1, text => 'Hello, World!' },
        { id => 2, text => 'Welcome to PAGI Endpoints' },
    );
    my $next_id = 3;

    async sub get ($self, $req, $res) {
        await $res->json(\@messages);
    }

    async sub post ($self, $req, $res) {
        my $data = await $req->json;
        my $message = { id => $next_id++, text => $data->{text} };
        push @messages, $message;

        # Notify SSE subscribers
        MessageEvents::broadcast($message);

        await $res->status(201)->json($message);
    }
}

#---------------------------------------------------------
# WebSocket Endpoint - Echo chat
#---------------------------------------------------------
package EchoWS {
    use parent 'PAGI::Endpoint::WebSocket';
    use v5.32;
    use feature 'signatures';
    no warnings 'experimental::signatures';
    use Future::AsyncAwait;

    sub encoding { 'json' }

    async sub on_connect ($self, $ws) {
        await $ws->accept;
        await $ws->send_json({ type => 'connected', message => 'Welcome!' });
    }

    async sub on_receive ($self, $ws, $data) {
        await $ws->send_json({
            type => 'echo',
            original => $data,
            timestamp => time(),
        });
    }

    sub on_disconnect ($self, $ws, $code) {
        print STDERR "WebSocket client disconnected: $code\n";
    }
}

#---------------------------------------------------------
# SSE Endpoint - Message notifications
#---------------------------------------------------------
package MessageEvents {
    use parent 'PAGI::Endpoint::SSE';
    use v5.32;
    use feature 'signatures';
    no warnings 'experimental::signatures';
    use Future::AsyncAwait;

    sub keepalive_interval { 25 }

    my %subscribers;
    my $sub_id = 0;

    sub broadcast ($message) {
        for my $sse (values %subscribers) {
            $sse->try_send_json($message);
        }
    }

    async sub on_connect ($self, $sse) {
        my $id = ++$sub_id;
        $subscribers{$id} = $sse;
        $sse->stash->{sub_id} = $id;

        await $sse->send_event(
            event => 'connected',
            data  => { subscriber_id => $id },
        );
    }

    sub on_disconnect ($self, $sse) {
        delete $subscribers{$sse->stash->{sub_id}};
        print STDERR "SSE client disconnected\n";
    }
}

#---------------------------------------------------------
# Main Router
#---------------------------------------------------------
my $static = PAGI::App::File->new(
    root => File::Spec->catdir(dirname(__FILE__), 'public')
)->to_app;

my $message_api = MessageAPI->to_app;
my $echo_ws = EchoWS->to_app;
my $events_sse = MessageEvents->to_app;

my $app = async sub ($scope, $receive, $send) {
    my $type = $scope->{type} // 'http';
    my $path = $scope->{path} // '/';

    # API routes
    if ($type eq 'http' && $path eq '/api/messages') {
        return await $message_api->($scope, $receive, $send);
    }

    # WebSocket
    if ($type eq 'websocket' && $path eq '/ws/echo') {
        return await $echo_ws->($scope, $receive, $send);
    }

    # SSE
    if ($type eq 'sse' && $path eq '/events') {
        return await $events_sse->($scope, $receive, $send);
    }

    # Static files
    if ($type eq 'http') {
        return await $static->($scope, $receive, $send);
    }

    die "Unknown route: $type $path";
};

$app;
