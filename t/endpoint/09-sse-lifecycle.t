#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use Future;

use lib 'lib';
use PAGI::Endpoint::SSE;
use PAGI::Context;

package MetricsEndpoint {
    use parent 'PAGI::Endpoint::SSE';
    use Future::AsyncAwait;

    sub keepalive_interval { 25 }

    our @log;

    async sub on_connect {
        my ($self, $ctx) = @_;
        push @log, 'connect';
        await $ctx->sse->send_event(event => 'connected', data => { ok => 1 });
    }

    sub on_disconnect {
        my ($self, $ctx) = @_;
        push @log, 'disconnect';
    }
}

subtest 'lifecycle via to_app' => sub {
    @MetricsEndpoint::log = ();

    my $app = MetricsEndpoint->to_app;
    my @sent;
    my $send = sub { push @sent, $_[0]; Future->done };
    my $receive = sub { Future->done({ type => 'sse.disconnect' }) };

    my $scope = {
        type    => 'sse',
        path    => '/events',
        headers => [],
    };

    $app->($scope, $receive, $send)->get;

    is($MetricsEndpoint::log[0], 'connect', 'on_connect called');
    is($MetricsEndpoint::log[1], 'disconnect', 'on_disconnect called');
};

subtest 'events are sent' => sub {
    @MetricsEndpoint::log = ();

    my $app = MetricsEndpoint->to_app;
    my @sent;
    my $send = sub { push @sent, $_[0]; Future->done };
    my $receive = sub { Future->done({ type => 'sse.disconnect' }) };

    $app->({ type => 'sse', path => '/events', headers => [] },
           $receive, $send)->get;

    ok(scalar @sent > 0, 'events were sent');
};

subtest 'context_class defaults to PAGI::Context' => sub {
    is(MetricsEndpoint->context_class, 'PAGI::Context', 'default context class');
};

subtest 'on_connect receives PAGI::Context::SSE' => sub {
    {
        package CheckSSECtx;
        use parent 'PAGI::Endpoint::SSE';
        use Future::AsyncAwait;

        our $ctx_class;

        async sub on_connect {
            my ($self, $ctx) = @_;
            $ctx_class = ref($ctx);
        }
    }

    my $app = CheckSSECtx->to_app;
    my @sent;
    my $send = sub { push @sent, $_[0]; Future->done };
    my $receive = sub { Future->done({ type => 'sse.disconnect' }) };

    $app->({ type => 'sse', path => '/events', headers => [] },
           $receive, $send)->get;

    is($CheckSSECtx::ctx_class, 'PAGI::Context::SSE', 'ctx is SSE context');
};

subtest 'to_app returns PAGI-compatible coderef' => sub {
    my $app = MetricsEndpoint->to_app;
    ref_ok($app, 'CODE', 'to_app returns coderef');
};

done_testing;
