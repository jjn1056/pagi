use strict;
use warnings;
use Test2::V0;
use FindBin qw($Bin);
use lib "$Bin/../examples/endpoint-router-demo/lib";
use lib "$Bin/../lib";
use Future::AsyncAwait;

use PAGI::Test::Client;
use PAGI::Lifespan;

# Load example app modules
subtest 'example app modules load' => sub {
    my $main_loaded = eval { require MyApp::Main; 1 };
    ok($main_loaded, 'MyApp::Main loads') or diag $@;

    my $api_loaded = eval { require MyApp::API; 1 };
    ok($api_loaded, 'MyApp::API loads') or diag $@;
};

subtest 'MyApp::Main class structure' => sub {
    ok(MyApp::Main->can('new'), 'has new');
    ok(MyApp::Main->can('to_app'), 'has to_app');
    ok(MyApp::Main->can('routes'), 'has routes');
    ok(MyApp::Main->can('state'), 'has state');
    ok(MyApp::Main->can('home'), 'has home handler');
    ok(MyApp::Main->can('ws_echo'), 'has ws_echo handler');
    ok(MyApp::Main->can('sse_metrics'), 'has sse_metrics handler');
    # No longer has on_startup/on_shutdown - lifecycle handled by PAGI::Lifespan
};

subtest 'app routes work with lifespan' => sub {
    my $router = MyApp::Main->new;

    my $app = PAGI::Lifespan->wrap(
        $router->to_app,
        startup => async sub {
            my ($state) = @_;
            # Populate state - injected into every request via $req->state
            $state->{config} = {
                app_name => 'Endpoint Router Demo',
                version  => '1.0.0',
            };
            $state->{metrics} = {
                requests  => 0,
                ws_active => 0,
            };
        },
    );

    PAGI::Test::Client->run($app, sub {
        my ($client) = @_;

        subtest 'home page' => sub {
            my $res = $client->get('/');
            is($res->status, 200, '/ returns 200');
            like($res->text, qr/Endpoint Router Demo/, 'body contains app name from state');
        };

        subtest 'API info' => sub {
            my $res = $client->get('/api/info');
            is($res->status, 200, '/api/info returns 200');
            like($res->text, qr/version/, 'body contains version');
        };

        subtest 'API users list' => sub {
            my $res = $client->get('/api/users');
            is($res->status, 200, '/api/users returns 200');
            like($res->text, qr/Alice|Bob/, 'body contains user names');
        };

        subtest 'WebSocket echo' => sub {
            $client->websocket('/ws/echo', sub {
                my ($ws) = @_;
                my $msg = $ws->receive_json;
                is($msg->{type}, 'connected', 'received connected message');
            });
        };

        subtest 'SSE metrics' => sub {
            $client->sse('/events/metrics', sub {
                my ($sse) = @_;
                my $event = $sse->receive_event;
                is($event->{event}, 'connected', 'received connected event');
            });
        };
    });
};

done_testing;
