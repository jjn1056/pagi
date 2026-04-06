#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use Future;
use PAGI::Stash;

# Load the modules
require PAGI::Endpoint::Router;
require PAGI::Context;

subtest 'context_class defaults to PAGI::Context' => sub {
    my $router = PAGI::Endpoint::Router->new;
    is($router->context_class, 'PAGI::Context', 'default context class');
};

subtest 'HTTP handler receives $ctx' => sub {
    {
        package TestCtx::HTTP;
        use parent 'PAGI::Endpoint::Router';
        use Future::AsyncAwait;

        sub routes {
            my ($self, $r) = @_;
            $r->get('/hello' => 'say_hello');
            $r->get('/users/:id' => 'get_user');
        }

        async sub say_hello {
            my ($self, $ctx) = @_;
            die "Expected PAGI::Context::HTTP"
                unless $ctx->isa('PAGI::Context::HTTP');
            await $ctx->response->text('Hello!');
        }

        async sub get_user {
            my ($self, $ctx) = @_;
            my $id = $ctx->request->path_param('id');
            await $ctx->response->json({ id => $id });
        }
    }

    my $app = TestCtx::HTTP->to_app;

    # Test /hello
    (async sub {
        my @sent;
        my $send = sub { push @sent, $_[0]; Future->done };
        my $receive = sub { Future->done({ type => 'http.request', body => '' }) };

        await $app->(
            { type => 'http', method => 'GET', path => '/hello', headers => [] },
            $receive, $send,
        );

        is($sent[0]{status}, 200, '/hello returns 200');
        is($sent[1]{body}, 'Hello!', '/hello returns Hello!');
    })->()->get;

    # Test /users/:id
    (async sub {
        my @sent;
        my $send = sub { push @sent, $_[0]; Future->done };
        my $receive = sub { Future->done({ type => 'http.request', body => '' }) };

        await $app->(
            { type => 'http', method => 'GET', path => '/users/42', headers => [] },
            $receive, $send,
        );

        is($sent[0]{status}, 200, '/users/42 returns 200');
        like($sent[1]{body}, qr/"id".*"42"/, 'body contains user id');
    })->()->get;
};

subtest 'WebSocket handler receives $ctx' => sub {
    {
        package TestCtx::WS;
        use parent 'PAGI::Endpoint::Router';
        use Future::AsyncAwait;

        sub routes {
            my ($self, $r) = @_;
            $r->websocket('/ws/echo/:room' => 'echo_handler');
        }

        async sub echo_handler {
            my ($self, $ctx) = @_;
            die "Expected PAGI::Context::WebSocket"
                unless $ctx->isa('PAGI::Context::WebSocket');

            my $ws = $ctx->websocket;
            my $room = $ws->path_param('room');
            die "Expected room param" unless $room eq 'test-room';

            await $ws->accept;
        }
    }

    my $app = TestCtx::WS->to_app;

    (async sub {
        my @sent;
        my $send = sub { push @sent, $_[0]; Future->done };
        my $receive = sub { Future->done({ type => 'websocket.disconnect' }) };

        await $app->(
            { type => 'websocket', path => '/ws/echo/test-room', headers => [] },
            $receive, $send,
        );

        is($sent[0]{type}, 'websocket.accept', 'WebSocket was accepted');
    })->()->get;
};

subtest 'SSE handler receives $ctx' => sub {
    {
        package TestCtx::SSE;
        use parent 'PAGI::Endpoint::Router';
        use Future::AsyncAwait;

        sub routes {
            my ($self, $r) = @_;
            $r->sse('/events/:channel' => 'events_handler');
        }

        async sub events_handler {
            my ($self, $ctx) = @_;
            die "Expected PAGI::Context::SSE"
                unless $ctx->isa('PAGI::Context::SSE');

            my $sse = $ctx->sse;
            my $channel = $sse->path_param('channel');
            die "Expected channel param" unless $channel eq 'news';

            await $sse->send_event(event => 'connected', data => { channel => $channel });
        }
    }

    my $app = TestCtx::SSE->to_app;

    (async sub {
        my @sent;
        my $send = sub { push @sent, $_[0]; Future->done };
        my $receive = sub { Future->done({ type => 'sse.disconnect' }) };

        await $app->(
            { type => 'sse', path => '/events/news', headers => [] },
            $receive, $send,
        );

        ok(scalar @sent > 0, 'SSE sent events');
    })->()->get;
};

subtest 'middleware receives $ctx' => sub {
    {
        package TestCtx::Middleware;
        use parent 'PAGI::Endpoint::Router';
        use Future::AsyncAwait;

        our $auth_called = 0;
        our $handler_saw_user;

        sub routes {
            my ($self, $r) = @_;
            $r->get('/protected' => ['require_auth'] => 'protected_handler');
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

        async sub protected_handler {
            my ($self, $ctx) = @_;
            $handler_saw_user = $ctx->stash->get('user');
            await $ctx->response->json({ user_id => $handler_saw_user->{id} });
        }
    }

    my $app = TestCtx::Middleware->to_app;

    # Without auth
    (async sub {
        my @sent;
        $TestCtx::Middleware::auth_called = 0;

        await $app->(
            { type => 'http', method => 'GET', path => '/protected', headers => [] },
            sub { Future->done({ type => 'http.request', body => '' }) },
            sub { push @sent, $_[0]; Future->done },
        );

        ok($TestCtx::Middleware::auth_called, 'auth middleware called');
        is($sent[0]{status}, 401, 'returns 401 without auth');
    })->()->get;

    # With auth
    (async sub {
        my @sent;
        $TestCtx::Middleware::auth_called = 0;

        await $app->(
            {
                type    => 'http',
                method  => 'GET',
                path    => '/protected',
                headers => [['authorization', 'Bearer valid']],
            },
            sub { Future->done({ type => 'http.request', body => '' }) },
            sub { push @sent, $_[0]; Future->done },
        );

        is($sent[0]{status}, 200, 'returns 200 with auth');
        is($TestCtx::Middleware::handler_saw_user->{id}, 1, 'handler sees user from middleware');
    })->()->get;
};

subtest 'state accessible via context' => sub {
    {
        package TestCtx::State;
        use parent 'PAGI::Endpoint::Router';
        use Future::AsyncAwait;

        our $state_value;

        sub routes {
            my ($self, $r) = @_;
            $self->state->{db} = 'connected';
            $r->get('/test' => 'test_handler');
        }

        async sub test_handler {
            my ($self, $ctx) = @_;
            $state_value = $ctx->state->{db};
            await $ctx->response->text('ok');
        }
    }

    my $app = TestCtx::State->to_app;

    (async sub {
        my @sent;
        await $app->(
            { type => 'http', method => 'GET', path => '/test', headers => [] },
            sub { Future->done({ type => 'http.request', body => '' }) },
            sub { push @sent, $_[0]; Future->done },
        );

        is($TestCtx::State::state_value, 'connected', 'state accessible via $ctx->state');
    })->()->get;
};

subtest 'custom context_class' => sub {
    {
        package TestCustomCtx::Context;
        our @ISA = ('PAGI::Context');

        sub _type_map {
            my ($class) = @_;
            return {
                %{ $class->SUPER::_type_map },
                http => 'TestCustomCtx::Context::HTTP',
            };
        }

        package TestCustomCtx::Context::HTTP;
        our @ISA = ('PAGI::Context::HTTP');

        sub custom_method { 'custom' }

        package TestCustomCtx::App;
        use parent 'PAGI::Endpoint::Router';
        use Future::AsyncAwait;

        our $custom_method_result;

        sub context_class { 'TestCustomCtx::Context' }

        sub routes {
            my ($self, $r) = @_;
            $r->get('/test' => 'test_handler');
        }

        async sub test_handler {
            my ($self, $ctx) = @_;
            $custom_method_result = $ctx->custom_method;
            await $ctx->response->text('ok');
        }
    }

    my $app = TestCustomCtx::App->to_app;

    (async sub {
        my @sent;
        await $app->(
            { type => 'http', method => 'GET', path => '/test', headers => [] },
            sub { Future->done({ type => 'http.request', body => '' }) },
            sub { push @sent, $_[0]; Future->done },
        );

        is($TestCustomCtx::App::custom_method_result, 'custom',
           'custom context_class used');
    })->()->get;
};

done_testing;
