# Endpoint Base Class Context Integration Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Update `PAGI::Endpoint::HTTP`, `PAGI::Endpoint::WebSocket`, and `PAGI::Endpoint::SSE` to inject `$ctx` (PAGI::Context) instead of raw protocol objects, matching the pattern already used by `PAGI::Endpoint::Router`.

**Architecture:** Each base class gets a `context_class` method (replacing `request_class`/`response_class`/`websocket_class`/`sse_class`). `to_app` constructs Context; `dispatch`/`handle` receives `$ctx` and passes it to all user-facing methods. Protocol objects are extracted internally via `$ctx->request`/`$ctx->response`/`$ctx->websocket`/`$ctx->sse`.

**Tech Stack:** Perl 5.18+, Test2::V0, Future::AsyncAwait, PAGI::Context (already implemented)

**Spec:** `docs/superpowers/specs/2026-04-06-endpoint-base-context-design.md`

---

## File Map

| File | Action | Responsibility |
|------|--------|---------------|
| `lib/PAGI/Endpoint/HTTP.pm` | Modify | Replace request_class/response_class with context_class, update dispatch |
| `lib/PAGI/Endpoint/WebSocket.pm` | Modify | Replace websocket_class with context_class, update handle/callbacks |
| `lib/PAGI/Endpoint/SSE.pm` | Modify | Replace sse_class with context_class, update handle/callbacks |
| `t/endpoint/02-http-dispatch.t` | Modify | Update to pass $ctx to dispatch |
| `t/endpoint/03-http-to-app.t` | Modify | Update handler signatures |
| `t/endpoint/06-websocket-lifecycle.t` | Modify | Update to pass $ctx to handle, update handler signatures |
| `t/endpoint/09-sse-lifecycle.t` | Modify | Update to pass $ctx to handle, update handler signatures |
| `t/endpoint/10-integration.t` | Modify | Update handler signatures if needed |
| `examples/endpoint-demo/app.pl` | Modify | Update all handler signatures to $ctx |

---

### Task 1: PAGI::Endpoint::HTTP — context_class, dispatch, to_app

**Files:**
- Modify: `lib/PAGI/Endpoint/HTTP.pm`
- Modify: `t/endpoint/02-http-dispatch.t`
- Modify: `t/endpoint/03-http-to-app.t`

- [ ] **Step 1: Update test for dispatch to use $ctx**

Modify `t/endpoint/02-http-dispatch.t`. Replace the MockRequest/MockResponse + old-signature pattern with Context-based tests. The test currently calls `dispatch($req, $res)` directly — change to `dispatch($ctx)`.

Replace the entire file content with:

```perl
#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use Future;

use lib 'lib';
use PAGI::Endpoint::HTTP;
use PAGI::Context;

package TestEndpoint {
    use parent 'PAGI::Endpoint::HTTP';
    use Future::AsyncAwait;

    async sub get {
        my ($self, $ctx) = @_;
        await $ctx->response->text("GET response");
    }

    async sub post {
        my ($self, $ctx) = @_;
        await $ctx->response->text("POST response");
    }
}

my $make_ctx = sub {
    my ($method) = @_;
    my @sent;
    my $send = sub { push @sent, $_[0]; Future->done };
    my $receive = sub { Future->done({ type => 'http.request', body => '' }) };
    my $scope = {
        type    => 'http',
        method  => $method,
        path    => '/test',
        headers => [],
    };
    my $ctx = PAGI::Context->new($scope, $receive, $send);
    return ($ctx, \@sent);
};

subtest 'dispatches GET to get method' => sub {
    my ($ctx, $sent) = $make_ctx->('GET');
    my $endpoint = TestEndpoint->new;

    $endpoint->dispatch($ctx)->get;

    is($sent->[1]{body}, 'GET response', 'GET dispatched correctly');
};

subtest 'dispatches POST to post method' => sub {
    my ($ctx, $sent) = $make_ctx->('POST');
    my $endpoint = TestEndpoint->new;

    $endpoint->dispatch($ctx)->get;

    is($sent->[1]{body}, 'POST response', 'POST dispatched correctly');
};

subtest 'returns 405 for unimplemented method' => sub {
    my ($ctx, $sent) = $make_ctx->('PUT');
    my $endpoint = TestEndpoint->new;

    $endpoint->dispatch($ctx)->get;

    is($sent->[0]{status}, 405, '405 status for unimplemented');
};

subtest 'HEAD dispatches to get if no head method' => sub {
    my ($ctx, $sent) = $make_ctx->('HEAD');
    my $endpoint = TestEndpoint->new;

    $endpoint->dispatch($ctx)->get;

    is($sent->[1]{body}, 'GET response', 'HEAD falls back to GET');
};

done_testing;
```

- [ ] **Step 2: Update test for to_app with $ctx handler signature**

Modify `t/endpoint/03-http-to-app.t`. Replace the entire file:

```perl
#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use Future;

use lib 'lib';
use PAGI::Endpoint::HTTP;

package HelloEndpoint {
    use parent 'PAGI::Endpoint::HTTP';
    use Future::AsyncAwait;

    async sub get {
        my ($self, $ctx) = @_;
        my $name = $ctx->request->query_param('name') // 'World';
        await $ctx->response->text("Hello, $name");
    }
}

subtest 'to_app returns PAGI-compatible coderef' => sub {
    my $app = HelloEndpoint->to_app;

    ref_ok($app, 'CODE', 'to_app returns coderef');
};

subtest 'app handles full request cycle' => sub {
    my $app = HelloEndpoint->to_app;

    my @sent;
    my $scope = {
        type => 'http',
        method => 'GET',
        path => '/hello',
        query_string => 'name=PAGI',
        headers => [],
    };
    my $receive = sub { Future->done({ type => 'http.request' }) };
    my $send = sub { push @sent, $_[0]; Future->done };

    $app->($scope, $receive, $send)->get;

    ok(@sent >= 1, 'sent response events');
    is($sent[0]{type}, 'http.response.start', 'starts with response.start');
};

subtest 'context_class defaults to PAGI::Context' => sub {
    is(HelloEndpoint->context_class, 'PAGI::Context', 'default context class');
};

done_testing;
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.40.0@default && prove -l t/endpoint/02-http-dispatch.t t/endpoint/03-http-to-app.t'`
Expected: FAIL — `dispatch` still expects `($req, $res)`, no `context_class` method

- [ ] **Step 4: Implement Endpoint::HTTP changes**

Replace the full content of `lib/PAGI/Endpoint/HTTP.pm`:

```perl
package PAGI::Endpoint::HTTP;

use strict;
use warnings;

use Future::AsyncAwait;
use Carp qw(croak);

# Factory class method - override in subclass for customization
sub context_class { 'PAGI::Context' }

sub new {
    my ($class, %args) = @_;
    return bless \%args, $class;
}

# HTTP methods we support
our @HTTP_METHODS = qw(get post put patch delete head options);

sub allowed_methods {
    my ($self) = @_;
    my @allowed;
    for my $method (@HTTP_METHODS) {
        push @allowed, uc($method) if $self->can($method);
    }
    # HEAD is allowed if GET is defined
    push @allowed, 'HEAD' if $self->can('get') && !$self->can('head');
    # OPTIONS is always allowed
    push @allowed, 'OPTIONS' unless grep { $_ eq 'OPTIONS' } @allowed;
    return sort @allowed;
}

async sub dispatch {
    my ($self, $ctx) = @_;
    my $http_method = lc($ctx->method // 'GET');

    # OPTIONS - return allowed methods
    if ($http_method eq 'options') {
        if ($self->can('options')) {
            return await $self->options($ctx);
        }
        my $allow = join(', ', $self->allowed_methods);
        await $ctx->response->header('Allow', $allow)->empty;
        return;
    }

    # HEAD falls back to GET if not explicitly defined
    if ($http_method eq 'head' && !$self->can('head') && $self->can('get')) {
        $http_method = 'get';
    }

    # Check if we have a handler for this method
    if ($self->can($http_method)) {
        return await $self->$http_method($ctx);
    }

    # 405 Method Not Allowed
    my $allow = join(', ', $self->allowed_methods);
    await $ctx->response->header('Allow', $allow)
              ->status(405)
              ->text("405 Method Not Allowed");
}

sub to_app {
    my ($class) = @_;
    my $context_class = $class->context_class;

    return async sub {
        my ($scope, $receive, $send) = @_;

        my $type = $scope->{type} // 'http';
        croak "Expected http scope, got '$type'" unless $type eq 'http';

        require PAGI::Context;
        my $endpoint = $class->new;
        my $ctx = $context_class->new($scope, $receive, $send);

        await $endpoint->dispatch($ctx);
    };
}

1;

__END__

=head1 NAME

PAGI::Endpoint::HTTP - Class-based HTTP endpoint handler

=head1 SYNOPSIS

    package MyApp::UserAPI;
    use parent 'PAGI::Endpoint::HTTP';
    use Future::AsyncAwait;

    async sub get {
        my ($self, $ctx) = @_;
        my $users = get_all_users();
        await $ctx->response->json($users);
    }

    async sub post {
        my ($self, $ctx) = @_;
        my $data = await $ctx->request->json;
        my $user = create_user($data);
        await $ctx->response->status(201)->json($user);
    }

    async sub delete {
        my ($self, $ctx) = @_;
        my $id = $ctx->request->path_param('id');
        delete_user($id);
        await $ctx->response->status(204)->empty;
    }

    # Use with PAGI server
    my $app = MyApp::UserAPI->to_app;

=head1 DESCRIPTION

PAGI::Endpoint::HTTP provides a Starlette-inspired class-based approach
to handling HTTP requests. Define methods named after HTTP verbs (get,
post, put, patch, delete, head, options) and the endpoint automatically
dispatches to them.

=head2 Features

=over 4

=item * Automatic method dispatch based on HTTP verb

=item * 405 Method Not Allowed for undefined methods

=item * OPTIONS handling with Allow header

=item * HEAD falls back to GET if not defined

=item * Customizable context class for framework integration

=back

=head1 HTTP METHODS

Define any of these async methods to handle requests:

    async sub get { my ($self, $ctx) = @_; ... }
    async sub post { my ($self, $ctx) = @_; ... }
    async sub put { my ($self, $ctx) = @_; ... }
    async sub patch { my ($self, $ctx) = @_; ... }
    async sub delete { my ($self, $ctx) = @_; ... }
    async sub head { my ($self, $ctx) = @_; ... }
    async sub options { my ($self, $ctx) = @_; ... }

Each receives:

=over 4

=item C<$self> - The endpoint instance

=item C<$ctx> - A L<PAGI::Context::HTTP> instance

=back

Use C<< $ctx->request >> for request data and C<< $ctx->response >> for
building responses.

=head1 CLASS METHODS

=head2 to_app

    my $app = MyEndpoint->to_app;

Returns a PAGI-compatible async coderef that can be used directly
with PAGI::Server or composed with middleware.

=head2 context_class

    sub context_class { 'PAGI::Context' }

Override to use a custom context class.

=head1 INSTANCE METHODS

=head2 dispatch

    await $endpoint->dispatch($ctx);

Dispatches the request to the appropriate HTTP method handler.
Called automatically by C<to_app>.

=head2 allowed_methods

    my @methods = $endpoint->allowed_methods;

Returns list of HTTP methods this endpoint handles.

=head1 FRAMEWORK INTEGRATION

Framework designers can subclass and customize via context:

    package MyFramework::Endpoint;
    use parent 'PAGI::Endpoint::HTTP';

    sub context_class { 'MyFramework::Context' }

=head1 SEE ALSO

L<PAGI::Context>, L<PAGI::Endpoint::WebSocket>, L<PAGI::Endpoint::SSE>,
L<PAGI::Request>, L<PAGI::Response>

=cut
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.40.0@default && prove -l t/endpoint/02-http-dispatch.t t/endpoint/03-http-to-app.t'`
Expected: All tests PASS

- [ ] **Step 6: Also run the HTTP constructor and OPTIONS tests to check for regressions**

Run: `bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.40.0@default && prove -l t/endpoint/01-http-constructor.t t/endpoint/04-http-options.t'`

If `01-http-constructor.t` tests for `request_class`/`response_class`, update those tests to check for `context_class` instead. If `04-http-options.t` uses old handler signatures, update them.

- [ ] **Step 7: Commit**

```bash
git add lib/PAGI/Endpoint/HTTP.pm t/endpoint/02-http-dispatch.t t/endpoint/03-http-to-app.t t/endpoint/01-http-constructor.t t/endpoint/04-http-options.t
git commit -m "feat: update Endpoint::HTTP to use PAGI::Context"
```

---

### Task 2: PAGI::Endpoint::WebSocket — context_class, handle, callbacks

**Files:**
- Modify: `lib/PAGI/Endpoint/WebSocket.pm`
- Modify: `t/endpoint/06-websocket-lifecycle.t`

- [ ] **Step 1: Update lifecycle test to use $ctx**

The current test at `t/endpoint/06-websocket-lifecycle.t` calls `handle($ws)` directly with a MockWebSocket. With Context, `handle` receives `$ctx` and gets `$ws` via `$ctx->websocket`. The mock objects won't work through Context's lazy accessor since it calls `PAGI::WebSocket->new(...)`.

The cleanest approach: test through `to_app` (full integration) and keep unit tests that call `handle($ctx)` with a real scope that produces a real `PAGI::WebSocket` from the Context. Since `PAGI::WebSocket->new` requires scope type `'websocket'`, receive, and send coderefs, we can build a Context from those.

Replace `t/endpoint/06-websocket-lifecycle.t`:

```perl
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
    my $ctx_class;

    {
        package CheckCtxEndpoint;
        use parent 'PAGI::Endpoint::WebSocket';
        use Future::AsyncAwait;

        async sub on_connect {
            my ($self, $ctx) = @_;
            $ctx_class = ref($ctx);
            await $ctx->websocket->accept;
        }
    }

    my $app = CheckCtxEndpoint->to_app;
    my @sent;
    my $send = sub { push @sent, $_[0]; Future->done };
    my $receive = sub { Future->done({ type => 'websocket.disconnect', code => 1000 }) };

    $app->({ type => 'websocket', path => '/ws', headers => [] },
           $receive, $send)->get;

    is($ctx_class, 'PAGI::Context::WebSocket', 'ctx is WebSocket context');
};

done_testing;
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.40.0@default && prove -l t/endpoint/06-websocket-lifecycle.t'`
Expected: FAIL — `handle` still expects `($ws, $scope, $send)`, no `context_class`

- [ ] **Step 3: Implement Endpoint::WebSocket changes**

Replace the full content of `lib/PAGI/Endpoint/WebSocket.pm`:

```perl
package PAGI::Endpoint::WebSocket;

use strict;
use warnings;

use Future::AsyncAwait;
use Carp qw(croak);

# Factory class method - override in subclass for customization
sub context_class { 'PAGI::Context' }

# Encoding: 'text', 'bytes', or 'json'
sub encoding { 'text' }

sub to_app {
    my ($class) = @_;
    my $context_class = $class->context_class;

    return async sub {
        my ($scope, $receive, $send) = @_;

        my $type = $scope->{type} // '';
        croak "Expected websocket scope, got '$type'" unless $type eq 'websocket';

        require PAGI::Context;
        my $endpoint = $class->new;
        my $ctx = $context_class->new($scope, $receive, $send);

        await $endpoint->handle($ctx);
    };
}

sub new {
    my ($class, %args) = @_;
    return bless \%args, $class;
}

async sub handle {
    my ($self, $ctx) = @_;
    my $ws = $ctx->websocket;

    # Call on_connect if defined
    if ($self->can('on_connect')) {
        await $self->on_connect($ctx);
    } else {
        # Default: accept the connection
        await $ws->accept;
    }

    # Register disconnect callback
    if ($self->can('on_disconnect')) {
        $ws->on_close(sub {
            my ($code, $reason) = @_;
            $self->on_disconnect($ctx, $code, $reason);
        });
    }

    # Handle messages based on encoding
    eval {
        if ($self->can('on_receive')) {
            my $encoding = $self->encoding;

            if ($encoding eq 'json') {
                await $ws->each_json(async sub {
                    my ($data) = @_;
                    await $self->on_receive($ctx, $data);
                });
            } elsif ($encoding eq 'bytes') {
                await $ws->each_bytes(async sub {
                    my ($data) = @_;
                    await $self->on_receive($ctx, $data);
                });
            } else {
                # Default: text
                await $ws->each_text(async sub {
                    my ($data) = @_;
                    await $self->on_receive($ctx, $data);
                });
            }
        } else {
            # No on_receive, just wait for disconnect
            await $ws->run;
        }
    };
    die $@ if $@;
}

1;

__END__

=head1 NAME

PAGI::Endpoint::WebSocket - Class-based WebSocket endpoint handler

=head1 SYNOPSIS

    package MyApp::Chat;
    use parent 'PAGI::Endpoint::WebSocket';
    use Future::AsyncAwait;

    sub encoding { 'json' }  # or 'text', 'bytes'

    async sub on_connect {
        my ($self, $ctx) = @_;
        await $ctx->websocket->accept;
        await $ctx->websocket->send_json({ type => 'welcome' });
    }

    async sub on_receive {
        my ($self, $ctx, $data) = @_;
        await $ctx->websocket->send_json({ type => 'echo', message => $data });
    }

    sub on_disconnect {
        my ($self, $ctx, $code) = @_;
        cleanup_user($ctx->stash->get('user_id'));
    }

    # Use with PAGI server
    my $app = MyApp::Chat->to_app;

=head1 DESCRIPTION

PAGI::Endpoint::WebSocket provides a Starlette-inspired class-based
approach to handling WebSocket connections with lifecycle hooks.

=head1 LIFECYCLE METHODS

=head2 on_connect

    async sub on_connect {
        my ($self, $ctx) = @_;
        await $ctx->websocket->accept;
    }

Called when a client connects. You should call C<< $ctx->websocket->accept >>
to accept the connection. If not defined, connection is auto-accepted.

=head2 on_receive

    async sub on_receive {
        my ($self, $ctx, $data) = @_;
        await $ctx->websocket->send_text("Got: $data");
    }

Called for each message received. The C<$data> format depends on
the C<encoding()> setting.

=head2 on_disconnect

    sub on_disconnect {
        my ($self, $ctx, $code, $reason) = @_;
        # Cleanup
    }

Called when connection closes. This is synchronous (not async).

=head1 CLASS METHODS

=head2 encoding

    sub encoding { 'json' }  # 'text', 'bytes', or 'json'

Controls how B<incoming> messages are decoded before being passed to
C<on_receive>. This does B<not> affect outgoing messages - you always
explicitly choose the send method (C<send_json>, C<send_text>, C<send_bytes>).

=head2 context_class

    sub context_class { 'PAGI::Context' }

Override to use a custom context class.

=head2 to_app

    my $app = MyEndpoint->to_app;

Returns a PAGI-compatible async coderef.

=head1 SEE ALSO

L<PAGI::Context>, L<PAGI::WebSocket>, L<PAGI::Endpoint::HTTP>,
L<PAGI::Endpoint::SSE>

=cut
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.40.0@default && prove -l t/endpoint/06-websocket-lifecycle.t'`
Expected: All tests PASS

- [ ] **Step 5: Run WebSocket constructor and to_app tests for regressions**

Run: `bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.40.0@default && prove -l t/endpoint/05-websocket-constructor.t t/endpoint/07-websocket-to-app.t'`

If any test uses old handler signatures or references `websocket_class`, update them.

- [ ] **Step 6: Commit**

```bash
git add lib/PAGI/Endpoint/WebSocket.pm t/endpoint/05-websocket-constructor.t t/endpoint/06-websocket-lifecycle.t t/endpoint/07-websocket-to-app.t
git commit -m "feat: update Endpoint::WebSocket to use PAGI::Context"
```

---

### Task 3: PAGI::Endpoint::SSE — context_class, handle, callbacks

**Files:**
- Modify: `lib/PAGI/Endpoint/SSE.pm`
- Modify: `t/endpoint/09-sse-lifecycle.t`

- [ ] **Step 1: Update lifecycle test to use $ctx**

Replace `t/endpoint/09-sse-lifecycle.t`:

```perl
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
    my $ctx_class;

    {
        package CheckSSECtx;
        use parent 'PAGI::Endpoint::SSE';
        use Future::AsyncAwait;

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

    is($ctx_class, 'PAGI::Context::SSE', 'ctx is SSE context');
};

subtest 'to_app returns PAGI-compatible coderef' => sub {
    my $app = MetricsEndpoint->to_app;
    ref_ok($app, 'CODE', 'to_app returns coderef');
};

done_testing;
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.40.0@default && prove -l t/endpoint/09-sse-lifecycle.t'`
Expected: FAIL — `handle` still expects `($sse)`, no `context_class`

- [ ] **Step 3: Implement Endpoint::SSE changes**

Replace the full content of `lib/PAGI/Endpoint/SSE.pm`:

```perl
package PAGI::Endpoint::SSE;

use strict;
use warnings;

use Future::AsyncAwait;
use Carp qw(croak);

# Factory class method - override in subclass for customization
sub context_class { 'PAGI::Context' }

# Keepalive interval in seconds (0 = disabled)
sub keepalive_interval { 0 }

sub new {
    my ($class, %args) = @_;
    return bless \%args, $class;
}

async sub handle {
    my ($self, $ctx) = @_;
    my $sse = $ctx->sse;

    # Configure keepalive if specified
    my $keepalive = $self->keepalive_interval;
    if ($keepalive > 0) {
        $sse->keepalive($keepalive);
    }

    # Register disconnect callback
    if ($self->can('on_disconnect')) {
        $sse->on_close(sub {
            $self->on_disconnect($ctx);
        });
    }

    # Call on_connect if defined
    if ($self->can('on_connect')) {
        await $self->on_connect($ctx);
    } else {
        # Default: just start the stream
        await $sse->start;
    }

    # Wait for disconnect
    await $sse->run;
}

sub to_app {
    my ($class) = @_;
    my $context_class = $class->context_class;

    return async sub {
        my ($scope, $receive, $send) = @_;

        my $type = $scope->{type} // '';
        croak "Expected sse scope, got '$type'" unless $type eq 'sse';

        require PAGI::Context;
        my $endpoint = $class->new;
        my $ctx = $context_class->new($scope, $receive, $send);

        await $endpoint->handle($ctx);
    };
}

1;

__END__

=head1 NAME

PAGI::Endpoint::SSE - Class-based Server-Sent Events endpoint handler

=head1 SYNOPSIS

    package MyApp::Notifications;
    use parent 'PAGI::Endpoint::SSE';
    use Future::AsyncAwait;

    sub keepalive_interval { 30 }

    async sub on_connect {
        my ($self, $ctx) = @_;
        my $user_id = $ctx->stash->get('user_id');

        await $ctx->sse->send_event(
            event => 'connected',
            data  => { user_id => $user_id },
        );
    }

    sub on_disconnect {
        my ($self, $ctx) = @_;
        # Cleanup subscriptions
    }

    # Use with PAGI server
    my $app = MyApp::Notifications->to_app;

=head1 DESCRIPTION

PAGI::Endpoint::SSE provides a class-based approach to handling
Server-Sent Events connections with lifecycle hooks.

=head1 LIFECYCLE METHODS

=head2 on_connect

    async sub on_connect {
        my ($self, $ctx) = @_;
        await $ctx->sse->send_event(data => 'Hello!');
    }

Called when a client connects. The SSE stream is automatically
started before this is called. Use this to send initial events
and set up subscriptions.

=head2 on_disconnect

    sub on_disconnect {
        my ($self, $ctx) = @_;
        # Cleanup subscriptions
    }

Called when connection closes. This is synchronous (not async).

=head1 CLASS METHODS

=head2 keepalive_interval

    sub keepalive_interval { 30 }

Seconds between keepalive pings. Set to 0 to disable (default).

=head2 context_class

    sub context_class { 'PAGI::Context' }

Override to use a custom context class.

=head2 to_app

    my $app = MyEndpoint->to_app;

Returns a PAGI-compatible async coderef.

=head1 RECIPES

=head2 Multi-Process Broadcasting with Redis

The simple in-memory subscriber pattern only works with a single process:

    my %subscribers;  # Lost when worker dies, not shared between workers

For multi-process deployments (e.g., C<pagi-server --workers 4>), use Redis
pub/sub as a message bus between workers. Each worker keeps its own local
subscriber hash with real connection objects, and Redis broadcasts messages
between workers.

    package MyApp::Events;
    use parent 'PAGI::Endpoint::SSE';
    use Future::AsyncAwait;
    use JSON::MaybeXS qw(encode_json decode_json);

    my %subscribers;  # Local to this process
    my $redis;        # Redis connection

    # Call this once at server startup (e.g., in lifespan handler)
    sub setup_redis {
        my ($redis_url) = @_;
        $redis = Redis::Async->new(server => $redis_url);

        # Subscribe to channel - forward to local connections
        $redis->subscribe('events', sub {
            my ($message) = @_;
            my $data = decode_json($message);
            _local_broadcast($data);
        });
    }

    # Broadcast to local process connections only
    sub _local_broadcast {
        my ($message) = @_;
        for my $sse (values %subscribers) {
            $sse->try_send_json($message);
        }
    }

    # Public API: publish to Redis (all workers receive it)
    sub broadcast {
        my ($message) = @_;
        $redis->publish('events', encode_json($message));
    }

    # Track local connections
    my $sub_id = 0;

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
        delete $subscribers{$ctx->stash->get('sub_id')};
    }

Now when any worker calls C<broadcast()>, the message goes to Redis, and
every worker (including itself) receives it and forwards to their local
SSE connections.

Setup Redis in your lifespan handler:

    my $app = async sub {
        my ($scope, $receive, $send) = @_;

        if ($scope->{type} eq 'lifespan') {
            my $event = await $receive->();
            if ($event->{type} eq 'lifespan.startup') {
                MyApp::Events::setup_redis('redis://localhost:6379');
                await $send->({ type => 'lifespan.startup.complete' });
            }
            # ... shutdown handling
            return;
        }

        # ... route to SSE endpoint
    };

=head1 SEE ALSO

L<PAGI::Context>, L<PAGI::SSE>, L<PAGI::Endpoint::HTTP>,
L<PAGI::Endpoint::WebSocket>

=cut
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.40.0@default && prove -l t/endpoint/09-sse-lifecycle.t'`
Expected: All tests PASS

- [ ] **Step 5: Run SSE constructor test for regressions**

Run: `bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.40.0@default && prove -l t/endpoint/08-sse-constructor.t'`

If it references `sse_class`, update it to check `context_class`.

- [ ] **Step 6: Commit**

```bash
git add lib/PAGI/Endpoint/SSE.pm t/endpoint/08-sse-constructor.t t/endpoint/09-sse-lifecycle.t
git commit -m "feat: update Endpoint::SSE to use PAGI::Context"
```

---

### Task 4: Integration Test and Endpoint Demo Example

**Files:**
- Modify: `t/endpoint/10-integration.t`
- Modify: `examples/endpoint-demo/app.pl`

- [ ] **Step 1: Check and update integration test**

Read `t/endpoint/10-integration.t`. Update any handler signatures from old `($req, $res)` / `($ws)` / `($sse)` patterns to `($ctx)`. The pattern for each protocol type:

HTTP: `my ($self, $ctx) = @_; ... $ctx->response->...`
WebSocket: `my ($self, $ctx) = @_; my $ws = $ctx->websocket; ...`
SSE: `my ($self, $ctx) = @_; my $sse = $ctx->sse; ...`

- [ ] **Step 2: Update endpoint-demo example**

Modify `examples/endpoint-demo/app.pl`. Changes:

**MessageAPI** (HTTP):
```perl
async sub get {
    my ($self, $ctx) = @_;
    await $ctx->response->json(\@messages);
}

async sub post {
    my ($self, $ctx) = @_;
    my $data = await $ctx->request->json;
    my $message = { id => $next_id++, text => $data->{text} };
    push @messages, $message;
    MessageEvents::broadcast($message);
    await $ctx->response->status(201)->json($message);
}
```

**EchoWS** (WebSocket):
```perl
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
```

**MessageEvents** (SSE):
```perl
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
```

Also remove `use PAGI::Stash;` from the imports since `$ctx->stash` is used instead of `PAGI::Stash->new(...)`.

- [ ] **Step 3: Verify syntax**

Run: `bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.40.0@default && perl -Ilib -c examples/endpoint-demo/app.pl'`
Expected: `syntax OK`

- [ ] **Step 4: Run integration test**

Run: `bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.40.0@default && prove -l t/endpoint/10-integration.t'`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add t/endpoint/10-integration.t examples/endpoint-demo/app.pl
git commit -m "docs: update integration test and endpoint-demo to use PAGI::Context"
```

---

### Task 5: Full Test Suite Validation

**Files:** None (validation only)

- [ ] **Step 1: Run all endpoint tests**

Run: `bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.40.0@default && prove -l t/endpoint/'`
Expected: All tests PASS

- [ ] **Step 2: Run full test suite**

Run: `bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.40.0@default && RELEASE_TESTING=1 prove -l t/'`
Expected: Same 3 pre-existing failures only (t/31-memory-leak.t, t/42-file-response.t, t/app-file.t). No new failures.

- [ ] **Step 3: Final verification checklist**

Verify:
- `PAGI::Endpoint::HTTP` has `context_class`, no `request_class`/`response_class`
- `PAGI::Endpoint::WebSocket` has `context_class`, no `websocket_class`
- `PAGI::Endpoint::SSE` has `context_class`, no `sse_class`
- All handler signatures in tests and examples use `($self, $ctx)` pattern
- POD documentation updated on all three modules
- No `use Module::Load` remaining in the three endpoint files
- No references to old factory methods in tests

- [ ] **Step 4: Fix any issues found, commit**

If fixes needed:
```bash
git add -u
git commit -m "fix: address issues from final validation"
```
