use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use PAGI::Stash;

# Load the module
my $loaded = eval { require PAGI::Endpoint::Router; 1 };
ok($loaded, 'PAGI::Endpoint::Router loads') or diag $@;

subtest 'basic class structure' => sub {
    ok(PAGI::Endpoint::Router->can('new'), 'has new');
    ok(PAGI::Endpoint::Router->can('to_app'), 'has to_app');
    ok(PAGI::Endpoint::Router->can('state'), 'has state');
    ok(PAGI::Endpoint::Router->can('routes'), 'has routes');
};

subtest 'state is a hashref' => sub {
    my $router = PAGI::Endpoint::Router->new;
    is(ref($router->state), 'HASH', 'state is hashref');

    $router->state->{test} = 'value';
    is($router->state->{test}, 'value', 'state persists values');
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
            my ($self, $ctx) = @_;
            await $ctx->response->text('Hello!');
        }

        async sub get_user {
            my ($self, $ctx) = @_;
            my $id = $ctx->request->path_param('id');
            await $ctx->response->json({ id => $id });
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
            my ($self, $ctx) = @_;

            my $ws = $ctx->websocket;
            die "Expected PAGI::WebSocket" unless $ws->isa('PAGI::WebSocket');

            # Check route params work
            my $room = $ws->path_param('room');
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
            my ($self, $ctx) = @_;

            my $sse = $ctx->sse;
            die "Expected PAGI::SSE" unless $sse->isa('PAGI::SSE');

            my $channel = $sse->path_param('channel');
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

subtest 'state accessible in handlers' => sub {
    {
        package TestApp::State;
        use parent 'PAGI::Endpoint::Router';
        use Future::AsyncAwait;

        our $state_value;
        our $req_state_value;

        sub routes {
            my ($self, $r) = @_;
            # Pre-populate state (normally done via PAGI::Lifespan startup)
            $self->state->{db} = 'connected';
            $r->get('/test' => 'test_handler');
        }

        async sub test_handler {
            my ($self, $ctx) = @_;
            # Access state via $self->state
            $state_value = $self->state->{db};
            # Also accessible via $ctx->state
            $req_state_value = $ctx->state->{db};
            await $ctx->response->text('ok');
        }
    }

    my $app = TestApp::State->to_app;

    (async sub {
        my @sent;
        my $send = sub { push @sent, $_[0]; Future->done };
        my $receive = sub { Future->done({ type => 'http.request', body => '' }) };

        await $app->({ type => 'http', method => 'GET', path => '/test', headers => [] },
                     $receive, $send);

        is($TestApp::State::state_value, 'connected', 'state accessible via $self->state');
        is($TestApp::State::req_state_value, 'connected', 'state accessible via $ctx->state');
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
            my ($self, $ctx, $next) = @_;
            $auth_called = 1;

            my $token = $ctx->header('authorization');
            if ($token && $token eq 'Bearer valid') {
                $ctx->stash->set(user => { id => 1 });
                await $next->();
            } else {
                await $ctx->response->status(401)->json({ error => 'Unauthorized' });
            }
        }

        async sub log_request {
            my ($self, $ctx, $next) = @_;
            $log_called = 1;
            await $next->();
        }

        async sub public_handler {
            my ($self, $ctx) = @_;
            await $ctx->response->text('public');
        }

        async sub protected_handler {
            my ($self, $ctx) = @_;
            my $user = $ctx->stash->get('user');
            await $ctx->response->json({ user_id => $user->{id} });
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

subtest 'stash flows through middleware to handler' => sub {
    {
        package TestApp::StashFlow;
        use parent 'PAGI::Endpoint::Router';
        use Future::AsyncAwait;

        our $handler_saw_user;

        sub routes {
            my ($self, $r) = @_;
            $r->get('/test' => ['set_user'] => 'check_user');
        }

        async sub set_user {
            my ($self, $ctx, $next) = @_;
            $ctx->stash->set(user => 'alice');
            await $next->();
        }

        async sub check_user {
            my ($self, $ctx) = @_;
            $handler_saw_user = $ctx->stash->get('user');
            await $ctx->response->text('ok');
        }
    }

    my $app = TestApp::StashFlow->to_app;

    (async sub {
        my @sent;
        await $app->(
            { type => 'http', method => 'GET', path => '/test', headers => [] },
            sub { Future->done({ type => 'http.request', body => '' }) },
            sub { push @sent, $_[0]; Future->done }
        );

        is($TestApp::StashFlow::handler_saw_user, 'alice',
           'handler sees stash set by middleware');
    })->()->get;
};

done_testing;
