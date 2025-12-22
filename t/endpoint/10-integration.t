#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use Future;

use lib 'lib';
use PAGI::Endpoint::HTTP;
use PAGI::Endpoint::WebSocket;
use PAGI::Endpoint::SSE;

# A realistic multi-protocol endpoint setup
package MyApp::UserAPI {
    use parent 'PAGI::Endpoint::HTTP';
    use v5.32;
    use feature 'signatures';
    no warnings 'experimental::signatures';
    use Future::AsyncAwait;

    async sub get ($self, $req, $res) {
        await $res->json({ users => ['alice', 'bob'] });
    }

    async sub post ($self, $req, $res) {
        await $res->status(201)->json({ created => 1 });
    }

    async sub delete ($self, $req, $res) {
        await $res->status(204)->empty;
    }
}

package MyApp::ChatWS {
    use parent 'PAGI::Endpoint::WebSocket';
    use v5.32;
    use feature 'signatures';
    no warnings 'experimental::signatures';
    use Future::AsyncAwait;

    sub encoding { 'json' }

    async sub on_connect ($self, $ws) {
        await $ws->accept;
        await $ws->send_json({ type => 'welcome' });
    }

    async sub on_receive ($self, $ws, $data) {
        await $ws->send_json({ type => 'echo', data => $data });
    }
}

package MyApp::EventsSSE {
    use parent 'PAGI::Endpoint::SSE';
    use v5.32;
    use feature 'signatures';
    no warnings 'experimental::signatures';
    use Future::AsyncAwait;

    sub keepalive_interval { 30 }

    async sub on_connect ($self, $sse) {
        await $sse->send_event(
            event => 'connected',
            data  => { server_time => time() },
        );
    }
}

subtest 'HTTP endpoint handles CRUD' => sub {
    ok(MyApp::UserAPI->can('get'), 'has get');
    ok(MyApp::UserAPI->can('post'), 'has post');
    ok(MyApp::UserAPI->can('delete'), 'has delete');
    ok(!MyApp::UserAPI->can('patch'), 'no patch');

    my @allowed = MyApp::UserAPI->new->allowed_methods;
    ok((grep { $_ eq 'GET' } @allowed), 'GET in allowed');
    ok((grep { $_ eq 'POST' } @allowed), 'POST in allowed');
    ok((grep { $_ eq 'DELETE' } @allowed), 'DELETE in allowed');
};

subtest 'WebSocket endpoint has correct encoding' => sub {
    is(MyApp::ChatWS->encoding, 'json', 'JSON encoding');
};

subtest 'SSE endpoint has keepalive configured' => sub {
    is(MyApp::EventsSSE->keepalive_interval, 30, 'keepalive is 30s');
};

subtest 'all endpoints produce PAGI apps' => sub {
    my $http_app = MyApp::UserAPI->to_app;
    my $ws_app = MyApp::ChatWS->to_app;
    my $sse_app = MyApp::EventsSSE->to_app;

    ref_ok($http_app, 'CODE', 'HTTP app is coderef');
    ref_ok($ws_app, 'CODE', 'WS app is coderef');
    ref_ok($sse_app, 'CODE', 'SSE app is coderef');
};

done_testing;
