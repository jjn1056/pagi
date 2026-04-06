package PAGI::Endpoint::Router;

use strict;
use warnings;

use Future::AsyncAwait;
use Carp qw(croak);
use Scalar::Util qw(blessed);
use Module::Load qw(load);


sub new {
    my ($class, %args) = @_;
    return bless {
        _state => {},
    }, $class;
}

# Worker-local state (NOT shared across workers)
sub state {
    my ($self) = @_;
    return $self->{_state};
}

# Override in subclass to use a custom context class
sub context_class { 'PAGI::Context' }

# Override in subclass to define routes
sub routes {
    my ($self, $r) = @_;
    # Default: no routes
}


sub to_app {
    my ($class) = @_;

    # Create instance that lives for app lifetime
    my $instance = blessed($class) ? $class : $class->new;

    # Build internal router
    load('PAGI::App::Router');
    my $internal_router = PAGI::App::Router->new;

    # Let subclass define routes
    $instance->_build_routes($internal_router);

    my $app = $internal_router->to_app;
    my $state = $instance->{_state};

    return async sub {
        my ($scope, $receive, $send) = @_;

        # Inject instance state into scope (allows $req->state to work)
        $scope->{state} //= $state;

        # Dispatch to internal router
        await $app->($scope, $receive, $send);
    };
}

sub _build_routes {
    my ($self, $r) = @_;

    # Create a wrapper router that intercepts route registration
    my $wrapper = PAGI::Endpoint::Router::RouteBuilder->new($self, $r);
    $self->routes($wrapper);
}

# Internal route builder that wraps handlers
package PAGI::Endpoint::Router::RouteBuilder;

use strict;
use warnings;
use Future::AsyncAwait;
use Scalar::Util qw(blessed);

sub new {
    my ($class, $endpoint, $router) = @_;
    return bless {
        endpoint => $endpoint,
        router   => $router,
    }, $class;
}

# HTTP methods
sub get     { shift->_add_http_route('GET', @_) }
sub post    { shift->_add_http_route('POST', @_) }
sub put     { shift->_add_http_route('PUT', @_) }
sub patch   { shift->_add_http_route('PATCH', @_) }
sub delete  { shift->_add_http_route('DELETE', @_) }
sub head    { shift->_add_http_route('HEAD', @_) }
sub options { shift->_add_http_route('OPTIONS', @_) }

sub _add_http_route {
    my ($self, $method, $path, @rest) = @_;

    my ($middleware, $handler) = $self->_parse_route_args(@rest);

    # Wrap middleware
    my @wrapped_mw = map { $self->_wrap_middleware($_) } @$middleware;

    # Wrap handler
    my $wrapped = $self->_wrap_http_handler($handler);

    # Register with internal router using the appropriate HTTP method
    my $router_method = lc($method);
    $self->{router}->$router_method($path, @wrapped_mw ? (\@wrapped_mw, $wrapped) : $wrapped);

    return $self;
}

sub _parse_route_args {
    my ($self, @args) = @_;

    if (@args == 2 && ref($args[0]) eq 'ARRAY') {
        return ($args[0], $args[1]);
    }
    elsif (@args == 1) {
        return ([], $args[0]);
    }
    else {
        die "Invalid route arguments";
    }
}

sub _wrap_http_handler {
    my ($self, $handler) = @_;

    my $endpoint = $self->{endpoint};
    my $context_class = $endpoint->context_class;

    # If handler is a string, it's a method name
    if (!ref($handler)) {
        my $method_name = $handler;
        my $method = $endpoint->can($method_name)
            or die "No such method: $method_name in " . ref($endpoint);

        return async sub {
            my ($scope, $receive, $send) = @_;

            require PAGI::Context;

            my $ctx = $context_class->new($scope, $receive, $send);

            await $endpoint->$method($ctx);
        };
    }

    # Already a coderef - wrap it
    return async sub {
        my ($scope, $receive, $send) = @_;

        require PAGI::Context;

        my $ctx = $context_class->new($scope, $receive, $send);

        await $handler->($ctx);
    };
}

sub websocket {
    my ($self, $path, @rest) = @_;

    my ($middleware, $handler) = $self->_parse_route_args(@rest);
    my @wrapped_mw = map { $self->_wrap_middleware($_) } @$middleware;
    my $wrapped = $self->_wrap_websocket_handler($handler);

    $self->{router}->websocket($path, @wrapped_mw ? (\@wrapped_mw, $wrapped) : $wrapped);

    return $self;
}

sub _wrap_websocket_handler {
    my ($self, $handler) = @_;

    my $endpoint = $self->{endpoint};
    my $context_class = $endpoint->context_class;

    if (!ref($handler)) {
        my $method_name = $handler;
        my $method = $endpoint->can($method_name)
            or die "No such method: $method_name";

        return async sub {
            my ($scope, $receive, $send) = @_;

            require PAGI::Context;

            my $ctx = $context_class->new($scope, $receive, $send);

            await $endpoint->$method($ctx);
        };
    }

    return async sub {
        my ($scope, $receive, $send) = @_;

        require PAGI::Context;

        my $ctx = $context_class->new($scope, $receive, $send);

        await $handler->($ctx);
    };
}

sub sse {
    my ($self, $path, @rest) = @_;

    my ($middleware, $handler) = $self->_parse_route_args(@rest);
    my @wrapped_mw = map { $self->_wrap_middleware($_) } @$middleware;
    my $wrapped = $self->_wrap_sse_handler($handler);

    $self->{router}->sse($path, @wrapped_mw ? (\@wrapped_mw, $wrapped) : $wrapped);

    return $self;
}

sub _wrap_sse_handler {
    my ($self, $handler) = @_;

    my $endpoint = $self->{endpoint};
    my $context_class = $endpoint->context_class;

    if (!ref($handler)) {
        my $method_name = $handler;
        my $method = $endpoint->can($method_name)
            or die "No such method: $method_name";

        return async sub {
            my ($scope, $receive, $send) = @_;

            require PAGI::Context;

            my $ctx = $context_class->new($scope, $receive, $send);

            await $endpoint->$method($ctx);
        };
    }

    return async sub {
        my ($scope, $receive, $send) = @_;

        require PAGI::Context;

        my $ctx = $context_class->new($scope, $receive, $send);

        await $handler->($ctx);
    };
}

sub _wrap_middleware {
    my ($self, $mw) = @_;

    my $endpoint = $self->{endpoint};
    my $context_class = $endpoint->context_class;

    # String = method name
    if (!ref($mw)) {
        my $method = $endpoint->can($mw)
            or die "No such middleware method: $mw";

        return async sub {
            my ($scope, $receive, $send, $next) = @_;

            require PAGI::Context;

            my $ctx = $context_class->new($scope, $receive, $send);

            await $endpoint->$method($ctx, $next);
        };
    }

    # Already a coderef or object - pass through
    return $mw;
}

# Pass through mount to internal router
sub mount {
    my ($self, @args) = @_;
    $self->{router}->mount(@args);
    return $self;
}

# Pass through name() to internal router
sub name {
    my ($self, $name) = @_;
    $self->{router}->name($name);
    return $self;
}

# Pass through as() to internal router
sub as {
    my ($self, $namespace) = @_;
    $self->{router}->as($namespace);
    return $self;
}

# Pass through uri_for() to internal router
sub uri_for {
    my ($self, @args) = @_;
    return $self->{router}->uri_for(@args);
}

# Pass through named_routes() to internal router
sub named_routes {
    my ($self) = @_;
    return $self->{router}->named_routes;
}

1;

__END__

=head1 NAME

PAGI::Endpoint::Router - Class-based router with wrapped handlers

=head1 SYNOPSIS

    package MyApp;
    use parent 'PAGI::Endpoint::Router';
    use Future::AsyncAwait;

    sub routes {
        my ($self, $r) = @_;

        # Initialize state (or use PAGI::Lifespan wrapper for startup/shutdown)
        $self->state->{db} = DBI->connect(...);
        $self->state->{cache} = MyApp::Cache->new;

        # HTTP routes with middleware
        $r->get('/users' => ['require_auth'] => 'list_users');
        $r->get('/users/:id' => 'get_user');

        # WebSocket and SSE
        $r->websocket('/ws/chat/:room' => 'chat_handler');
        $r->sse('/events' => 'events_handler');

        # Mount sub-routers
        $r->mount('/api' => MyApp::API->to_app);
    }

    # Middleware sets stash - visible to ALL downstream handlers
    async sub require_auth {
        my ($self, $ctx, $next) = @_;
        my $user = verify_token($ctx->header('Authorization'));
        $ctx->stash->set(user => $user);  # Flows to handler and subrouters!
        await $next->();
    }

    async sub list_users {
        my ($self, $ctx) = @_;
        my $db = $self->state->{db};                 # Worker state via $self
        my $user = $ctx->stash->get('user');          # Set by middleware
        my $users = $db->get_users;
        await $ctx->response->json($users);
    }

    async sub get_user {
        my ($self, $ctx) = @_;
        my $id = $ctx->request->path_param('id');    # Route parameter
        await $ctx->response->json({ id => $id });
    }

    async sub chat_handler {
        my ($self, $ctx) = @_;
        my $ws = $ctx->websocket;
        await $ws->accept;
        await $ws->keepalive(25);
        await $ws->each_json(async sub {
            my ($data) = @_;
            await $ws->send_json({ echo => $data });
        });
    }

    # Wrap with PAGI::Lifespan for startup/shutdown hooks
    use PAGI::Lifespan;
    my $app = PAGI::Lifespan->new(
        startup => async sub ($state) {
            $state->{db} = DBI->connect(...);
        },
        shutdown => async sub ($state) {
            $state->{db}->disconnect;
        },
        app => MyApp->to_app,
    )->to_app;

=head1 DESCRIPTION

PAGI::Endpoint::Router provides a Starlette/Rails-style class-based approach
to building PAGI applications. It combines:

=over 4

=item * B<Method-based handlers> - Define handlers as class methods

=item * B<Context objects> - Handlers receive a L<PAGI::Context> with
protocol-specific accessors (request/response, websocket, sse)

=item * B<Middleware as methods> - Define middleware that can set L<PAGI::Stash>
values visible to all downstream handlers

=item * B<Worker-local state> - C<$self-E<gt>state> hashref for storing resources
like database connections, accessible via C<$ctx-E<gt>state>

=back

For lifecycle management (startup/shutdown hooks), wrap your router with
C<PAGI::Lifespan>. This separation allows routers to be freely composable
without lifecycle conflicts.

=head1 STATE VS STASH

PAGI::Endpoint::Router provides two separate storage mechanisms with
different scopes and lifetimes.

=head2 state - Worker-Local Instance State

    $self->state->{db} = $connection;

The C<state> hashref is attached to the router instance. Use it for
resources initialized in C<on_startup> like database connections,
cache clients, or configuration.

B<IMPORTANT: Worker Isolation>

In a multi-worker or clustered deployment, each worker process has its
own isolated copy of C<state>:

    Master Process
      fork() --> Worker 1 (own $self->state)
             --> Worker 2 (own $self->state)
             --> Worker 3 (own $self->state)

Changes to C<state> in one worker do NOT affect other workers. For
truly shared application state (counters, sessions, feature flags),
use external storage:

=over 4

=item * B<Redis> - Fast in-memory shared state

=item * B<Database> - Persistent shared state

=item * B<Memcached> - Distributed caching

=back

=head2 Per-Request Shared State (PAGI::Stash)

    $ctx->stash->set(user => $current_user);

L<PAGI::Stash> provides per-request shared state that is accessible across
all handlers, middleware, and subrouters processing the same request.

    Middleware A
        sets $ctx->stash->set(user => ...)
            Middleware B
                reads $ctx->stash->get('user')
                    Subrouter Handler
                        reads $ctx->stash->get('user')  <-- Still visible!

This enables middleware to pass data downstream:

    # Auth middleware
    async sub require_auth {
        my ($self, $ctx, $next) = @_;
        my $user = verify_token($ctx->header('Authorization'));
        $ctx->stash->set(user => $user);  # Available to ALL downstream
        await $next->();
    }

    # Handler in subrouter - sees stash from parent middleware
    async sub get_profile {
        my ($self, $ctx) = @_;
        my $user = $ctx->stash->get('user');  # Set by middleware above
        await $ctx->response->json($user);
    }

=head1 HANDLER SIGNATURES

All handlers receive a L<PAGI::Context> as the second argument.
The context subclass depends on route type:

    # HTTP routes: get, post, put, patch, delete, head, options
    async sub handler ($self, $ctx) { }
    # $ctx isa PAGI::Context::HTTP
    # $ctx->request, $ctx->response

    # WebSocket routes
    async sub handler ($self, $ctx) { }
    # $ctx isa PAGI::Context::WebSocket
    # $ctx->websocket

    # SSE routes
    async sub handler ($self, $ctx) { }
    # $ctx isa PAGI::Context::SSE
    # $ctx->sse

    # Middleware
    async sub middleware ($self, $ctx, $next) { }

=head1 METHODS

=head2 to_app

    my $app = MyRouter->to_app;

Returns a PAGI application coderef. Creates a single instance that
persists for the worker lifetime.

=head2 context_class

    sub context_class { 'MyApp::Context' }

Returns the class name used to construct context objects for handlers.
Defaults to C<'PAGI::Context'>. Override in a subclass to use a custom
context class (must be a subclass of L<PAGI::Context>).

=head2 state

    $self->state->{db} = $connection;

Returns the worker-local state hashref. Initialize resources in the
C<routes> method or via C<PAGI::Lifespan> wrapper. Access via
C<$self-E<gt>state> in handlers or C<$ctx-E<gt>state> in context objects.

B<Note:> This is NOT shared across workers. See L</STATE VS STASH>.

=head2 routes

    sub routes {
        my ($self, $r) = @_;
        $r->get('/path' => 'handler_method');
    }

Override to define routes. The C<$r> parameter is a route builder.

=head1 ROUTE BUILDER METHODS

=head2 HTTP Methods

    $r->get($path => 'handler');
    $r->get($path => ['middleware'] => 'handler');
    $r->post($path => ...);
    $r->put($path => ...);
    $r->patch($path => ...);
    $r->delete($path => ...);
    $r->head($path => ...);
    $r->options($path => ...);

=head2 websocket

    $r->websocket($path => 'handler');

=head2 sse

    $r->sse($path => 'handler');

=head2 mount

    $r->mount($prefix => $other_app);

Mount another PAGI app at a prefix. L<PAGI::Stash> data flows through to mounted apps.

=head1 SEE ALSO

L<PAGI::Context>, L<PAGI::Stash>, L<PAGI::App::Router>, L<PAGI::Request>,
L<PAGI::Response>, L<PAGI::WebSocket>, L<PAGI::SSE>

=cut
