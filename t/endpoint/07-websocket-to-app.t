#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use Future;

use lib 'lib';
use PAGI::Endpoint::WebSocket;

package SimpleWSEndpoint {
    use parent 'PAGI::Endpoint::WebSocket';
    use Future::AsyncAwait;

    async sub on_connect {
        my ($self, $ctx) = @_;
        await $ctx->websocket->accept;
        await $ctx->websocket->send_text("Welcome!");
    }
}

subtest 'to_app returns PAGI-compatible coderef' => sub {
    my $app = SimpleWSEndpoint->to_app;

    ref_ok($app, 'CODE', 'to_app returns coderef');
};

subtest 'app creates WebSocket wrapper and calls handle' => sub {
    my $app = SimpleWSEndpoint->to_app;

    my @sent;
    my @events = (
        { type => 'websocket.connect' },
        { type => 'websocket.disconnect', code => 1000 },
    );
    my $idx = 0;

    my $scope = { type => 'websocket', path => '/ws', headers => [] };
    my $receive = sub { Future->done($events[$idx++]) };
    my $send = sub { push @sent, $_[0]; Future->done };

    $app->($scope, $receive, $send)->get;

    ok(@sent > 0, 'sent events');
    is($sent[0]{type}, 'websocket.accept', 'accepted connection');
};

done_testing;
