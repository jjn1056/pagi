#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use Future;
use JSON::MaybeXS;

use lib 'lib';
use PAGI::Endpoint::WebSocket;
use PAGI::Context;

package EchoEndpoint {
    use parent 'PAGI::Endpoint::WebSocket';
    use Future::AsyncAwait;

    our @log;

    async sub on_connect {
        my ($self, $ctx) = @_;
        push @log, 'connect';
        await $ctx->websocket->accept;
    }

    async sub on_receive {
        my ($self, $ctx, $data) = @_;
        push @log, "receive:$data";
        await $ctx->websocket->send_text("echo:$data");
    }

    sub on_disconnect {
        my ($self, $ctx, $code, $reason) = @_;
        push @log, "disconnect:$code";
    }
}

subtest 'lifecycle via to_app' => sub {
    @EchoEndpoint::log = ();

    my $app = EchoEndpoint->to_app;
    my @sent;
    my $send = sub { push @sent, $_[0]; Future->done };

    # Simulate: connect, send "hello", send "world", disconnect
    my @events = (
        { type => 'websocket.receive', text => 'hello' },
        { type => 'websocket.receive', text => 'world' },
        { type => 'websocket.disconnect', code => 1000 },
    );
    my $idx = 0;
    my $receive = sub { Future->done($events[$idx++]) };

    my $scope = {
        type    => 'websocket',
        path    => '/ws/echo',
        headers => [],
    };

    $app->($scope, $receive, $send)->get;

    is($EchoEndpoint::log[0], 'connect', 'on_connect called');
    is($EchoEndpoint::log[1], 'receive:hello', 'first message');
    is($EchoEndpoint::log[2], 'receive:world', 'second message');
    like($EchoEndpoint::log[3], qr/disconnect/, 'on_disconnect called');

    # Check accept was sent
    ok((grep { ($_->{type} // '') eq 'websocket.accept' } @sent), 'accept sent');
};

subtest 'context_class defaults to PAGI::Context' => sub {
    is(EchoEndpoint->context_class, 'PAGI::Context', 'default context class');
};

subtest 'on_connect receives PAGI::Context::WebSocket' => sub {
    {
        package CheckCtxEndpoint;
        use parent 'PAGI::Endpoint::WebSocket';
        use Future::AsyncAwait;

        our $captured_ctx_class;

        async sub on_connect {
            my ($self, $ctx) = @_;
            $captured_ctx_class = ref($ctx);
            await $ctx->websocket->accept;
        }
    }

    my $app = CheckCtxEndpoint->to_app;
    my @sent;
    my $send = sub { push @sent, $_[0]; Future->done };
    my $receive = sub { Future->done({ type => 'websocket.disconnect', code => 1000 }) };

    $app->({ type => 'websocket', path => '/ws', headers => [] },
           $receive, $send)->get;

    is($CheckCtxEndpoint::captured_ctx_class, 'PAGI::Context::WebSocket', 'ctx is WebSocket context');
};

done_testing;
