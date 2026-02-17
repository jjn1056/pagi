package PAGI::App::Router;

use strict;
use warnings;
use Future::AsyncAwait;
use Scalar::Util qw(blessed);
use Carp qw(croak);

=head1 NAME

PAGI::App::Router - Unified routing for HTTP, WebSocket, and SSE

=head1 SYNOPSIS

    use PAGI::App::Router;

    my $router = PAGI::App::Router->new;

    # HTTP routes (method + path)
    $router->get('/users/:id' => $get_user);
    $router->post('/users' => $create_user);
    $router->delete('/users/:id' => $delete_user);

    # Routes with middleware
    $router->get('/admin' => [$auth_mw, $log_mw] => $admin_handler);
    $router->post('/api/data' => [$rate_limit] => $data_handler);

    # WebSocket routes (path only)
    $router->websocket('/ws/chat/:room' => $chat_handler);

    # SSE routes (path only)
    $router->sse('/events/:channel' => $events_handler);

    # Mount with middleware (applies to all sub-routes)
    $router->mount('/api' => [$auth_mw] => $api_router->to_app);

    # Static files as fallback
    $router->mount('/' => $static_files);

    # Named routes for URL generation
    $router->get('/users/:id' => $get_user)->name('users.get');
    $router->post('/users' => $create_user)->name('users.create');

    my $url = $router->uri_for('users.get', { id => 42 });
    # Returns: "/users/42"

    # Namespace mounted routers
    $router->mount('/api/v1' => $api_router)->as('api');
    $router->uri_for('api.users.get', { id => 42 });
    # Returns: "/api/v1/users/42"

    my $app = $router->to_app;  # Handles all scope types

=cut

sub new {
    my ($class, %args) = @_;

    return bless {
        routes           => [],
        websocket_routes => [],
        sse_routes       => [],
        mounts           => [],
        not_found        => $args{not_found},
        _named_routes    => {},   # name => route info
        _last_route      => undef, # for ->name() chaining
        _last_mount      => undef, # for ->as() chaining
    }, $class;
}

sub mount {
    my ($self, $prefix, @rest) = @_;
    $prefix =~ s{/$}{};  # strip trailing slash
    my ($middleware, $app_or_router) = $self->_parse_route_args(@rest);

    # Check if it's a router object (has named_routes method)
    my $sub_router;
    my $app;
    if (blessed($app_or_router) && $app_or_router->isa('PAGI::App::Router')) {
        $sub_router = $app_or_router;
        $app = $sub_router->to_app;
    } else {
        $app = $app_or_router;
    }

    my $mount = {
        prefix      => $prefix,
        app         => $app,
        middleware  => $middleware,
        sub_router  => $sub_router,  # Keep reference for ->as()
    };
    push @{$self->{mounts}}, $mount;
    $self->{_last_mount} = $mount;
    $self->{_last_route} = undef;  # Clear route tracking

    return $self;
}

sub get     { my ($self, $path, @rest) = @_; $self->route('GET', $path, @rest) }
sub post    { my ($self, $path, @rest) = @_; $self->route('POST', $path, @rest) }
sub put     { my ($self, $path, @rest) = @_; $self->route('PUT', $path, @rest) }
sub patch   { my ($self, $path, @rest) = @_; $self->route('PATCH', $path, @rest) }
sub delete  { my ($self, $path, @rest) = @_; $self->route('DELETE', $path, @rest) }
sub head    { my ($self, $path, @rest) = @_; $self->route('HEAD', $path, @rest) }
sub options { my ($self, $path, @rest) = @_; $self->route('OPTIONS', $path, @rest) }

sub any {
    my ($self, $path, @rest) = @_;

    # Parse optional trailing key-value args (method => [...])
    my %opts;
    if (@rest >= 2 && !ref($rest[-2]) && $rest[-2] eq 'method') {
        %opts = splice(@rest, -2);
    }

    my $method = $opts{method} // '*';
    if (ref($method) eq 'ARRAY') {
        $method = [map { uc($_) } @$method];
    }

    $self->route($method, $path, @rest);
}

sub websocket {
    my ($self, $path, @rest) = @_;
    my ($middleware, $app) = $self->_parse_route_args(@rest);
    my ($regex, $names, $constraints) = $self->_compile_path($path);
    my $route = {
        path        => $path,
        regex       => $regex,
        names       => $names,
        constraints => $constraints,
        app         => $app,
        middleware  => $middleware,
    };
    push @{$self->{websocket_routes}}, $route;
    $self->{_last_route} = $route;
    $self->{_last_mount} = undef;

    return $self;
}

sub sse {
    my ($self, $path, @rest) = @_;
    my ($middleware, $app) = $self->_parse_route_args(@rest);
    my ($regex, $names, $constraints) = $self->_compile_path($path);
    my $route = {
        path        => $path,
        regex       => $regex,
        names       => $names,
        constraints => $constraints,
        app         => $app,
        middleware  => $middleware,
    };
    push @{$self->{sse_routes}}, $route;
    $self->{_last_route} = $route;
    $self->{_last_mount} = undef;

    return $self;
}

sub route {
    my ($self, $method, $path, @rest) = @_;

    my ($middleware, $app) = $self->_parse_route_args(@rest);
    my ($regex, $names, $constraints) = $self->_compile_path($path);
    my $route = {
        method      => ref($method) eq 'ARRAY' ? $method : ($method eq '*' ? '*' : uc($method)),
        path        => $path,
        regex       => $regex,
        names       => $names,
        constraints => $constraints,
        app         => $app,
        middleware  => $middleware,
    };
    push @{$self->{routes}}, $route;
    $self->{_last_route} = $route;
    $self->{_last_mount} = undef;  # Clear mount tracking

    return $self;
}

sub _compile_path {
    my ($self, $path) = @_;

    my @names;
    my @constraints;
    my $regex = '';

    # Tokenize the path
    my $remaining = $path;
    while (length $remaining) {
        # {name:pattern} — constrained parameter
        if ($remaining =~ s/^\{(\w+):([^}]+)\}//) {
            push @names, $1;
            push @constraints, [$1, $2];
            $regex .= "([^/]+)";
        }
        # {name} — unconstrained parameter (same as :name)
        elsif ($remaining =~ s/^\{(\w+)\}//) {
            push @names, $1;
            $regex .= "([^/]+)";
        }
        # *name — wildcard/splat
        elsif ($remaining =~ s/^\*(\w+)//) {
            push @names, $1;
            $regex .= "(.+)";
        }
        # :name — named parameter (legacy syntax)
        elsif ($remaining =~ s/^:(\w+)//) {
            push @names, $1;
            $regex .= "([^/]+)";
        }
        # Literal text up to next special token
        elsif ($remaining =~ s/^([^{:*]+)//) {
            $regex .= quotemeta($1);
        }
        # Safety: consume one character to avoid infinite loop
        else {
            $regex .= quotemeta(substr($remaining, 0, 1, ''));
        }
    }

    return (qr{^$regex$}, \@names, \@constraints);
}

sub _check_constraints {
    my ($self, $route, $params) = @_;
    my $constraints = $route->{constraints} // [];
    for my $c (@$constraints) {
        my ($name, $pattern) = @$c;
        my $value = $params->{$name} // return 0;
        return 0 unless $value =~ m/^(?:$pattern)$/;
    }
    return 1;
}

# ============================================================
# Named Routes
# ============================================================

sub name {
    my ($self, $name) = @_;

    croak "name() called without a preceding route" unless $self->{_last_route};
    croak "Route name required" unless defined $name && length $name;

    my $route = $self->{_last_route};
    $route->{name} = $name;
    $self->{_named_routes}{$name} = {
        path   => $route->{path},
        names  => $route->{names},
        prefix => '',
    };

    return $self;
}

sub constraints {
    my ($self, %new_constraints) = @_;

    croak "constraints() called without a preceding route" unless $self->{_last_route};

    my $route = $self->{_last_route};
    my $existing = $route->{constraints} // [];

    for my $name (keys %new_constraints) {
        my $pattern = $new_constraints{$name};
        croak "Constraint for '$name' must be a Regexp (qr//), got " . ref($pattern)
            unless ref($pattern) eq 'Regexp';
        push @$existing, [$name, $pattern];
    }
    $route->{constraints} = $existing;

    return $self;
}

sub as {
    my ($self, $namespace) = @_;

    croak "as() called without a preceding mount" unless $self->{_last_mount};
    croak "Namespace required" unless defined $namespace && length $namespace;

    my $mount = $self->{_last_mount};
    my $sub_router = $mount->{sub_router};

    croak "as() requires mounting a router object, not an app coderef"
        unless $sub_router;

    # Import all named routes from sub-router with namespace prefix
    my $prefix = $mount->{prefix};
    for my $name (keys %{$sub_router->{_named_routes}}) {
        my $info = $sub_router->{_named_routes}{$name};
        my $full_name = "$namespace.$name";
        $self->{_named_routes}{$full_name} = {
            path   => $info->{path},
            names  => $info->{names},
            prefix => $prefix . ($info->{prefix} // ''),
        };
    }

    return $self;
}

sub named_routes {
    my ($self) = @_;
    return { %{$self->{_named_routes}} };
}

sub uri_for {
    my ($self, $name, $path_params, $query_params) = @_;

    $path_params  //= {};
    $query_params //= {};

    my $info = $self->{_named_routes}{$name}
        or croak "Unknown route name: '$name'";

    my $path = $info->{path};
    my $prefix = $info->{prefix} // '';

    # Substitute path parameters
    for my $param_name (@{$info->{names}}) {
        unless (exists $path_params->{$param_name}) {
            croak "Missing required path parameter '$param_name' for route '$name'";
        }
        my $value = $path_params->{$param_name};
        $path =~ s/:$param_name\b/$value/
            || $path =~ s/\{$param_name(?::[^}]*)?\}/$value/
            || $path =~ s/\*$param_name\b/$value/;
    }

    # Prepend mount prefix
    $path = $prefix . $path if $prefix;

    # Add query string if any
    if (%$query_params) {
        my @pairs;
        for my $key (sort keys %$query_params) {
            my $value = $query_params->{$key};
            # Simple URL encoding
            $key   =~ s/([^A-Za-z0-9\-_.~])/sprintf("%%%02X", ord($1))/ge;
            $value =~ s/([^A-Za-z0-9\-_.~])/sprintf("%%%02X", ord($1))/ge;
            push @pairs, "$key=$value";
        }
        $path .= '?' . join('&', @pairs);
    }

    return $path;
}

sub _parse_route_args {
    my ($self, @args) = @_;

    if (@args == 2 && ref($args[0]) eq 'ARRAY') {
        # (\@middleware, $app)
        my ($middleware, $app) = @args;
        $self->_validate_middleware($middleware);
        return ($middleware, $app);
    }
    elsif (@args == 1) {
        # ($app) - no middleware
        return ([], $args[0]);
    }
    else {
        croak 'Invalid route arguments: expected ($app) or (\@middleware => $app)';
    }
}

sub _validate_middleware {
    my ($self, $middleware) = @_;

    for my $mw (@$middleware) {
        if (ref($mw) eq 'CODE') {
            # Coderef is valid
            next;
        }
        elsif (blessed($mw) && $mw->can('call')) {
            # PAGI::Middleware instance with call() method
            next;
        }
        else {
            my $type = ref($mw) || 'scalar';
            croak "Invalid middleware: expected coderef or object with ->call method, got $type";
        }
    }
}

sub _build_middleware_chain {
    my ($self, $middlewares, $app) = @_;

    return $app unless $middlewares && @$middlewares;

    my $chain = $app;

    for my $mw (reverse @$middlewares) {
        my $next = $chain;

        if (ref($mw) eq 'CODE') {
            # Coderef with $next signature
            $chain = async sub {
                my ($scope, $receive, $send) = @_;
                await $mw->($scope, $receive, $send, async sub {
                    await $next->($scope, $receive, $send);
                });
            };
        }
        else {
            # PAGI::Middleware instance - use existing call()
            $chain = async sub {
                my ($scope, $receive, $send) = @_;
                await $mw->call($scope, $receive, $send, $next);
            };
        }
    }

    return $chain;
}

sub to_app {
    my ($self) = @_;
    my $self_ref = $self;

    my @routes           = @{$self->{routes}};
    my @websocket_routes = @{$self->{websocket_routes}};
    my @sse_routes       = @{$self->{sse_routes}};
    my @mounts           = @{$self->{mounts}};
    my $not_found        = $self->{not_found};

    # Pre-build middleware chains for efficiency
    for my $route (@routes, @websocket_routes, @sse_routes) {
        $route->{_handler} = $self->_build_middleware_chain($route->{middleware}, $route->{app});
    }
    for my $m (@mounts) {
        $m->{_handler} = $self->_build_middleware_chain($m->{middleware}, $m->{app});
    }

    # Helper to check mounts
    my $check_mounts = async sub {
        my ($scope, $receive, $send, $path) = @_;
        for my $m (sort { length($b->{prefix}) <=> length($a->{prefix}) } @mounts) {
            my $prefix = $m->{prefix};
            if ($path eq $prefix || $path =~ m{^\Q$prefix\E(/.*)$}) {
                my $sub_path = $1 // '/';
                my $new_scope = {
                    %$scope,
                    path      => $sub_path,
                    root_path => ($scope->{root_path} // '') . $prefix,
                };
                await $m->{_handler}->($new_scope, $receive, $send);
                return 1;  # Matched
            }
        }
        return 0;  # No match
    };

    return async sub {
        my ($scope, $receive, $send) = @_;
        my $type   = $scope->{type} // 'http';
        my $method = uc($scope->{method} // '');
        my $path   = $scope->{path} // '/';

        # Ignore lifespan events
        return if $type eq 'lifespan';

        # WebSocket routes (path-only matching) - check before mounts
        if ($type eq 'websocket') {
            for my $route (@websocket_routes) {
                if ($path =~ $route->{regex}) {
                    my @captures = ($path =~ $route->{regex});
                    my %params;
                    for my $i (0 .. $#{$route->{names}}) {
                        $params{$route->{names}[$i]} = $captures[$i];
                    }

                    # Check constraints — skip route if any fail
                    next unless $self_ref->_check_constraints($route, \%params);

                    my $new_scope = {
                        %$scope,
                        path_params => \%params,
                        'pagi.router' => { route => $route->{path} },
                    };
                    await $route->{_handler}->($new_scope, $receive, $send);
                    return;
                }
            }
            # No websocket route matched - try mounts as fallback
            if (await $check_mounts->($scope, $receive, $send, $path)) {
                return;
            }
            # No mount matched either - 404
            if ($not_found) {
                await $not_found->($scope, $receive, $send);
            } else {
                await $send->({
                    type => 'http.response.start',
                    status => 404,
                    headers => [['content-type', 'text/plain']],
                });
                await $send->({ type => 'http.response.body', body => 'Not Found', more => 0 });
            }
            return;
        }

        # SSE routes (path-only matching) - check before mounts
        if ($type eq 'sse') {
            for my $route (@sse_routes) {
                if ($path =~ $route->{regex}) {
                    my @captures = ($path =~ $route->{regex});
                    my %params;
                    for my $i (0 .. $#{$route->{names}}) {
                        $params{$route->{names}[$i]} = $captures[$i];
                    }

                    # Check constraints — skip route if any fail
                    next unless $self_ref->_check_constraints($route, \%params);

                    my $new_scope = {
                        %$scope,
                        path_params => \%params,
                        'pagi.router' => { route => $route->{path} },
                    };
                    await $route->{_handler}->($new_scope, $receive, $send);
                    return;
                }
            }
            # No SSE route matched - try mounts as fallback
            if (await $check_mounts->($scope, $receive, $send, $path)) {
                return;
            }
            # No mount matched either - 404
            if ($not_found) {
                await $not_found->($scope, $receive, $send);
            } else {
                await $send->({
                    type => 'http.response.start',
                    status => 404,
                    headers => [['content-type', 'text/plain']],
                });
                await $send->({ type => 'http.response.body', body => 'Not Found', more => 0 });
            }
            return;
        }

        # HTTP routes (method + path matching) - check routes first
        # HEAD should match GET routes
        my $match_method = $method eq 'HEAD' ? 'GET' : $method;

        my @method_matches;

        for my $route (@routes) {
            if ($path =~ $route->{regex}) {
                my @captures = ($path =~ $route->{regex});

                # Build params FIRST (needed for constraint checking)
                my %params;
                for my $i (0 .. $#{$route->{names}}) {
                    $params{$route->{names}[$i]} = $captures[$i];
                }

                # Check constraints — skip route if any fail
                next unless $self_ref->_check_constraints($route, \%params);

                # Check method
                my $route_method = $route->{method};
                my $method_match = ref($route_method) eq 'ARRAY'
                    ? (grep { $_ eq $match_method || $_ eq $method } @$route_method)
                    : ($route_method eq '*' || $route_method eq $match_method || $route_method eq $method);

                if ($method_match) {
                    my $new_scope = {
                        %$scope,
                        path_params => \%params,
                        'pagi.router' => { route => $route->{path} },
                    };

                    await $route->{_handler}->($new_scope, $receive, $send);
                    return;
                }

                if (ref($route->{method}) eq 'ARRAY') {
                    push @method_matches, @{$route->{method}};
                } elsif ($route->{method} ne '*') {
                    push @method_matches, $route->{method};
                }
            }
        }

        # Path matched but method didn't - 405
        if (@method_matches) {
            my $allowed = join ', ', sort keys %{{ map { $_ => 1 } @method_matches }};
            await $send->({
                type => 'http.response.start',
                status => 405,
                headers => [
                    ['content-type', 'text/plain'],
                    ['allow', $allowed],
                ],
            });
            await $send->({ type => 'http.response.body', body => 'Method Not Allowed', more => 0 });
            return;
        }

        # No HTTP route matched - try mounts as fallback
        if (await $check_mounts->($scope, $receive, $send, $path)) {
            return;
        }

        # No mount matched either - 404
        if ($not_found) {
            await $not_found->($scope, $receive, $send);
        } else {
            await $send->({
                type => 'http.response.start',
                status => 404,
                headers => [['content-type', 'text/plain']],
            });
            await $send->({ type => 'http.response.body', body => 'Not Found', more => 0 });
        }
    };
}

1;

__END__

=head1 DESCRIPTION

Unified router supporting HTTP, WebSocket, and SSE in a single declarative
interface. Routes requests based on scope type first, then path pattern.
HTTP routes additionally match on method. Returns 404 for unmatched paths
and 405 for unmatched HTTP methods. Lifespan events are automatically ignored.

=head1 OPTIONS

=over 4

=item * C<not_found> - Custom app to handle unmatched routes (all scope types)

=back

=head1 METHODS

=head2 HTTP Route Methods

    $router->get($path => $app);
    $router->post($path => $app);
    $router->put($path => $app);
    $router->patch($path => $app);
    $router->delete($path => $app);
    $router->head($path => $app);
    $router->options($path => $app);

Register a route for the given HTTP method. Returns C<$self> for chaining.

=head2 websocket

    $router->websocket('/ws/chat/:room' => $chat_handler);

Register a WebSocket route. Matches requests where C<< $scope->{type} >>
is C<'websocket'>. Path parameters work the same as HTTP routes.

=head2 sse

    $router->sse('/events/:channel' => $events_handler);

Register an SSE (Server-Sent Events) route. Matches requests where
C<< $scope->{type} >> is C<'sse'>. Path parameters work the same as
HTTP routes.

=head2 mount

    $router->mount('/api' => $api_app);
    $router->mount('/admin' => $admin_router->to_app);

Mount a PAGI app under a path prefix. The mounted app receives requests
with the prefix stripped from the path and added to C<root_path>.

When a request for C</api/users/42> hits a router with C</api> mounted:

=over 4

=item * The mounted app sees C<< $scope->{path} >> as C</users/42>

=item * C<< $scope->{root_path} >> becomes C</api> (or appends to existing)

=back

Mounts are checked before regular routes. Longer prefixes match first,
so C</api/v2> takes priority over C</api>.

B<Example: Organizing a large application>

    # API routes
    my $api = PAGI::App::Router->new;
    $api->get('/users' => $list_users);
    $api->get('/users/:id' => $get_user);
    $api->post('/users' => $create_user);

    # Admin routes
    my $admin = PAGI::App::Router->new;
    $admin->get('/dashboard' => $dashboard);
    $admin->get('/settings' => $settings);

    # Main router
    my $main = PAGI::App::Router->new;
    $main->get('/' => $home);
    $main->mount('/api' => $api->to_app);
    $main->mount('/admin' => $admin->to_app);

    # Resulting routes:
    # GET /           -> $home
    # GET /api/users  -> $list_users (path=/users, root_path=/api)
    # GET /admin/dashboard -> $dashboard (path=/dashboard, root_path=/admin)

=head2 to_app

    my $app = $router->to_app;

Returns a PAGI application coderef that dispatches requests.

=head1 ROUTE-LEVEL MIDDLEWARE

All route methods accept an optional middleware arrayref before the app:

    $router->get('/path' => \@middleware => $app);
    $router->post('/path' => \@middleware => $app);
    $router->mount('/prefix' => \@middleware => $sub_app);
    $router->websocket('/ws' => \@middleware => $handler);
    $router->sse('/events' => \@middleware => $handler);

=head2 Middleware Types

=over 4

=item * B<PAGI::Middleware instance>

Any object with a C<call($scope, $receive, $send, $app)> method:

    use PAGI::Middleware::RateLimit;

    my $rate_limit = PAGI::Middleware::RateLimit->new(limit => 100);
    $router->get('/api/data' => [$rate_limit] => $handler);

=item * B<Coderef with $next signature>

    my $timing = async sub ($scope, $receive, $send, $next) {
        my $start = time;
        await $next->();  # Call next middleware or app
        warn sprintf "Request took %.3fs", time - $start;
    };
    $router->get('/api/data' => [$timing] => $handler);

=back

=head2 Execution Order

Middleware executes in array order for requests, reverse order for responses
(onion model):

    $router->get('/' => [$mw1, $mw2, $mw3] => $app);

    # Request flow:  mw1 -> mw2 -> mw3 -> app
    # Response flow: mw1 <- mw2 <- mw3 <- app

=head2 Short-Circuiting

Middleware can skip calling C<$next> to short-circuit the chain:

    my $auth = async sub ($scope, $receive, $send, $next) {
        unless ($scope->{user}) {
            await $send->({
                type    => 'http.response.start',
                status  => 401,
                headers => [['content-type', 'text/plain']],
            });
            await $send->({
                type => 'http.response.body',
                body => 'Unauthorized',
            });
            return;  # Don't call $next
        }
        await $next->();
    };

=head2 Stacking with Mount

Mount middleware runs before any sub-router middleware:

    my $api = PAGI::App::Router->new;
    $api->get('/users' => [$rate_limit] => $list_users);

    $router->mount('/api' => [$auth] => $api->to_app);

    # Request to /api/users runs: $auth -> $rate_limit -> $list_users

=head1 PATH PATTERNS

=over 4

=item * C</users/:id> - Named parameter, captured as C<params-E<gt>{id}>

=item * C</files/*path> - Wildcard, captures rest of path as C<params-E<gt>{path}>

=back

=head1 SCOPE ADDITIONS

The router adds the following to scope when a route matches:

    $scope->{path_params}            # Captured path parameters (hashref)
    $scope->{'pagi.router'}{route}   # Matched route pattern

Path parameters use a router-agnostic key (C<path_params>) so that
L<PAGI::Request>, L<PAGI::Response>, L<PAGI::WebSocket>, and L<PAGI::SSE>
can access them via C<< ->path_param('name') >> regardless of which
router implementation populated them.

For mounted apps, C<root_path> is updated to include the mount prefix.

=head1 NAMED ROUTES

Routes can be named for URL generation using the C<name()> method:

    $router->get('/users/:id' => $handler)->name('users.get');
    $router->post('/users' => $handler)->name('users.create');

=head2 name

    $router->get('/path' => $handler)->name('route.name');

Assign a name to the most recently added route. Returns C<$self> for chaining.
Croaks if called without a preceding route or with an empty name.

=head2 uri_for

    my $path = $router->uri_for($name, \%path_params, \%query_params);

Generate a URL path for a named route.

    $router->uri_for('users.get', { id => 42 });
    # Returns: "/users/42"

    $router->uri_for('users.list', {}, { page => 2, limit => 10 });
    # Returns: "/users?limit=10&page=2"

Croaks if the route name is unknown or if a required path parameter is missing.

=head2 named_routes

    my $routes = $router->named_routes;

Returns a hashref of all named routes for inspection.

=head2 as

    $router->mount('/api' => $sub_router)->as('api');

Assign a namespace to a mounted router's named routes. This imports all
named routes from the sub-router into the parent with the namespace prefix.

    my $api = PAGI::App::Router->new;
    $api->get('/users/:id' => $h)->name('users.get');

    my $main = PAGI::App::Router->new;
    $main->mount('/api/v1' => $api)->as('api');

    $main->uri_for('api.users.get', { id => 42 });
    # Returns: "/api/v1/users/42"

Croaks if called without a preceding mount or if the mount target is an
app coderef rather than a router object.

=cut
