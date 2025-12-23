use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;

# Load the module
my $loaded = eval { require PAGI::Endpoint::Router; 1 };
ok($loaded, 'PAGI::Endpoint::Router loads') or diag $@;

subtest 'basic class structure' => sub {
    ok(PAGI::Endpoint::Router->can('new'), 'has new');
    ok(PAGI::Endpoint::Router->can('to_app'), 'has to_app');
    ok(PAGI::Endpoint::Router->can('stash'), 'has stash');
    ok(PAGI::Endpoint::Router->can('routes'), 'has routes');
    ok(PAGI::Endpoint::Router->can('on_startup'), 'has on_startup');
    ok(PAGI::Endpoint::Router->can('on_shutdown'), 'has on_shutdown');
};

subtest 'stash is a hashref' => sub {
    my $router = PAGI::Endpoint::Router->new;
    is(ref($router->stash), 'HASH', 'stash is hashref');

    $router->stash->{test} = 'value';
    is($router->stash->{test}, 'value', 'stash persists values');
};

subtest 'to_app returns coderef' => sub {
    my $app = PAGI::Endpoint::Router->to_app;
    is(ref($app), 'CODE', 'to_app returns coderef');
};

subtest 'HTTP route with method handler' => sub {
    # Create a test router subclass
    {
        package TestApp::HTTP;
        use parent 'PAGI::Endpoint::Router';
        use Future::AsyncAwait;

        sub routes {
            my ($self, $r) = @_;
            $r->get('/hello' => 'say_hello');
            $r->get('/users/:id' => 'get_user');
        }

        async sub say_hello {
            my ($self, $req, $res) = @_;
            await $res->text('Hello!');
        }

        async sub get_user {
            my ($self, $req, $res) = @_;
            my $id = $req->param('id');
            await $res->json({ id => $id });
        }
    }

    my $app = TestApp::HTTP->to_app;

    # Test /hello
    (async sub {
        my @sent;
        my $send = sub { push @sent, $_[0]; Future->done };
        my $receive = sub { Future->done({ type => 'http.request', body => '' }) };

        my $scope = {
            type   => 'http',
            method => 'GET',
            path   => '/hello',
            headers => [],
        };

        await $app->($scope, $receive, $send);

        is($sent[0]{status}, 200, '/hello returns 200');
        is($sent[1]{body}, 'Hello!', '/hello returns Hello!');
    })->()->get;

    # Test /users/:id
    (async sub {
        my @sent;
        my $send = sub { push @sent, $_[0]; Future->done };
        my $receive = sub { Future->done({ type => 'http.request', body => '' }) };

        my $scope = {
            type   => 'http',
            method => 'GET',
            path   => '/users/42',
            headers => [],
        };

        await $app->($scope, $receive, $send);

        is($sent[0]{status}, 200, '/users/42 returns 200');
        like($sent[1]{body}, qr/"id".*"42"/, 'body contains user id');
    })->()->get;
};

subtest 'WebSocket route with method handler' => sub {
    {
        package TestApp::WS;
        use parent 'PAGI::Endpoint::Router';
        use Future::AsyncAwait;

        sub routes {
            my ($self, $r) = @_;
            $r->websocket('/ws/echo/:room' => 'echo_handler');
        }

        async sub echo_handler {
            my ($self, $ws) = @_;

            # Check we got a PAGI::WebSocket
            die "Expected PAGI::WebSocket" unless $ws->isa('PAGI::WebSocket');

            # Check route params work
            my $room = $ws->param('room');
            die "Expected room param" unless $room eq 'test-room';

            await $ws->accept;
        }
    }

    my $app = TestApp::WS->to_app;

    (async sub {
        my @sent;
        my $send = sub { push @sent, $_[0]; Future->done };
        my $receive = sub { Future->done({ type => 'websocket.disconnect' }) };

        my $scope = {
            type    => 'websocket',
            path    => '/ws/echo/test-room',
            headers => [],
        };

        await $app->($scope, $receive, $send);

        is($sent[0]{type}, 'websocket.accept', 'WebSocket was accepted');
    })->()->get;
};

subtest 'SSE route with method handler' => sub {
    {
        package TestApp::SSE;
        use parent 'PAGI::Endpoint::Router';
        use Future::AsyncAwait;

        sub routes {
            my ($self, $r) = @_;
            $r->sse('/events/:channel' => 'events_handler');
        }

        async sub events_handler {
            my ($self, $sse) = @_;

            die "Expected PAGI::SSE" unless $sse->isa('PAGI::SSE');

            my $channel = $sse->param('channel');
            die "Expected channel param" unless $channel eq 'news';

            await $sse->send_event(event => 'connected', data => { channel => $channel });
        }
    }

    my $app = TestApp::SSE->to_app;

    (async sub {
        my @sent;
        my $send = sub { push @sent, $_[0]; Future->done };
        my $receive = sub { Future->done({ type => 'sse.disconnect' }) };

        my $scope = {
            type    => 'sse',
            path    => '/events/news',
            headers => [],
        };

        await $app->($scope, $receive, $send);

        ok(scalar @sent > 0, 'SSE sent events');
    })->()->get;
};

subtest 'lifespan startup and shutdown' => sub {
    {
        package TestApp::Lifespan;
        use parent 'PAGI::Endpoint::Router';
        use Future::AsyncAwait;

        our $startup_called = 0;
        our $shutdown_called = 0;
        our $stash_value;

        async sub on_startup {
            my ($self) = @_;
            $startup_called = 1;
            $self->stash->{db} = 'connected';
        }

        async sub on_shutdown {
            my ($self) = @_;
            $shutdown_called = 1;
        }

        sub routes {
            my ($self, $r) = @_;
            $r->get('/test' => 'test_handler');
        }

        async sub test_handler {
            my ($self, $req, $res) = @_;
            $stash_value = $req->stash->{db};
            await $res->text('ok');
        }
    }

    my $app = TestApp::Lifespan->to_app;

    # Test startup
    (async sub {
        my @lifespan_sent;
        my $lifespan_send = sub { push @lifespan_sent, $_[0]; Future->done };

        my $msg_index = 0;
        my @lifespan_messages = (
            { type => 'lifespan.startup' },
            { type => 'lifespan.shutdown' },
        );
        my $lifespan_receive = sub {
            my $msg = $lifespan_messages[$msg_index++];
            Future->done($msg);
        };

        my $lifespan_scope = { type => 'lifespan' };

        await $app->($lifespan_scope, $lifespan_receive, $lifespan_send);

        ok($TestApp::Lifespan::startup_called, 'on_startup was called');
        ok($TestApp::Lifespan::shutdown_called, 'on_shutdown was called');
        is($lifespan_sent[0]{type}, 'lifespan.startup.complete', 'startup complete sent');
        is($lifespan_sent[1]{type}, 'lifespan.shutdown.complete', 'shutdown complete sent');

        # Test that stash is available to handlers
        my @http_sent;
        my $http_send = sub { push @http_sent, $_[0]; Future->done };
        my $http_receive = sub { Future->done({ type => 'http.request', body => '' }) };

        my $http_scope = {
            type    => 'http',
            method  => 'GET',
            path    => '/test',
            headers => [],
        };

        await $app->($http_scope, $http_receive, $http_send);

        is($TestApp::Lifespan::stash_value, 'connected', 'stash from on_startup available in handler');
    })->()->get;
};

subtest 'middleware as method names' => sub {
    {
        package TestApp::Middleware;
        use parent 'PAGI::Endpoint::Router';
        use Future::AsyncAwait;

        our $auth_called = 0;
        our $log_called = 0;

        sub routes {
            my ($self, $r) = @_;
            $r->get('/public' => 'public_handler');
            $r->get('/protected' => ['require_auth'] => 'protected_handler');
            $r->get('/logged' => ['log_request', 'require_auth'] => 'protected_handler');
        }

        async sub require_auth {
            my ($self, $req, $res, $next) = @_;
            $auth_called = 1;

            my $token = $req->header('authorization');
            if ($token && $token eq 'Bearer valid') {
                $req->set('user', { id => 1 });
                await $next->();
            } else {
                await $res->status(401)->json({ error => 'Unauthorized' });
            }
        }

        async sub log_request {
            my ($self, $req, $res, $next) = @_;
            $log_called = 1;
            await $next->();
        }

        async sub public_handler {
            my ($self, $req, $res) = @_;
            await $res->text('public');
        }

        async sub protected_handler {
            my ($self, $req, $res) = @_;
            my $user = $req->get('user');
            await $res->json({ user_id => $user->{id} });
        }
    }

    my $app = TestApp::Middleware->to_app;

    # Test public route (no middleware)
    (async sub {
        my @sent;
        my $send = sub { push @sent, $_[0]; Future->done };
        my $receive = sub { Future->done({ type => 'http.request', body => '' }) };

        await $app->({ type => 'http', method => 'GET', path => '/public', headers => [] },
                     $receive, $send);

        is($sent[1]{body}, 'public', 'public route works');
    })->()->get;

    # Test protected route without auth
    (async sub {
        my @sent;
        $TestApp::Middleware::auth_called = 0;

        my $send = sub { push @sent, $_[0]; Future->done };
        my $receive = sub { Future->done({ type => 'http.request', body => '' }) };

        await $app->({ type => 'http', method => 'GET', path => '/protected', headers => [] },
                     $receive, $send);

        ok($TestApp::Middleware::auth_called, 'auth middleware was called');
        is($sent[0]{status}, 401, 'returns 401 without auth');
    })->()->get;

    # Test protected route with auth
    (async sub {
        my @sent;
        $TestApp::Middleware::auth_called = 0;

        my $send = sub { push @sent, $_[0]; Future->done };
        my $receive = sub { Future->done({ type => 'http.request', body => '' }) };

        await $app->({
            type    => 'http',
            method  => 'GET',
            path    => '/protected',
            headers => [['authorization', 'Bearer valid']],
        }, $receive, $send);

        is($sent[0]{status}, 200, 'returns 200 with auth');
        like($sent[1]{body}, qr/"user_id"/, 'returns user data');
    })->()->get;

    # Test middleware chaining
    (async sub {
        my @sent;
        $TestApp::Middleware::auth_called = 0;
        $TestApp::Middleware::log_called = 0;

        my $send = sub { push @sent, $_[0]; Future->done };
        my $receive = sub { Future->done({ type => 'http.request', body => '' }) };

        await $app->({
            type    => 'http',
            method  => 'GET',
            path    => '/logged',
            headers => [['authorization', 'Bearer valid']],
        }, $receive, $send);

        ok($TestApp::Middleware::log_called, 'log middleware was called');
        ok($TestApp::Middleware::auth_called, 'auth middleware was called');
        is($sent[0]{status}, 200, 'handler was reached');
    })->()->get;
};

done_testing;
