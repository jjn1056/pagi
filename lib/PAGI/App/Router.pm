package PAGI::App::Router;

use strict;
use warnings;
use Future::AsyncAwait;

=head1 NAME

PAGI::App::Router - URL routing with path parameters and mounting

=head1 SYNOPSIS

    use PAGI::App::Router;

    my $router = PAGI::App::Router->new;
    $router->get('/users/:id' => $get_user);
    $router->post('/users' => $create_user);
    $router->delete('/users/:id' => $delete_user);
    my $app = $router->to_app;

    # Nested routers with mount
    my $api = PAGI::App::Router->new;
    $api->get('/users' => $list_users);
    $api->get('/users/:id' => $get_user);
    $api->post('/users' => $create_user);

    my $main = PAGI::App::Router->new;
    $main->get('/' => $home);
    $main->mount('/api' => $api->to_app);
    # Routes: /, /api/users, /api/users/:id

=cut

sub new {
    my ($class, %args) = @_;

    return bless {
        routes           => [],
        websocket_routes => [],
        sse_routes       => [],
        mounts           => [],
        not_found        => $args{not_found},
    }, $class;
}

sub mount {
    my ($self, $prefix, $app) = @_;
    $prefix =~ s{/$}{};  # strip trailing slash
    push @{$self->{mounts}}, { prefix => $prefix, app => $app };
    return $self;
}

sub get {
    my ($self, $path, $app) = @_;
 $self->route('GET', $path, $app) }
sub post {
    my ($self, $path, $app) = @_;
 $self->route('POST', $path, $app) }
sub put {
    my ($self, $path, $app) = @_;
 $self->route('PUT', $path, $app) }
sub patch {
    my ($self, $path, $app) = @_;
 $self->route('PATCH', $path, $app) }
sub delete {
    my ($self, $path, $app) = @_;
 $self->route('DELETE', $path, $app) }
sub head {
    my ($self, $path, $app) = @_;
 $self->route('HEAD', $path, $app) }
sub options {
    my ($self, $path, $app) = @_;
 $self->route('OPTIONS', $path, $app) }

sub websocket {
    my ($self, $path, $app) = @_;
    my ($regex, @names) = $self->_compile_path($path);
    push @{$self->{websocket_routes}}, {
        path  => $path,
        regex => $regex,
        names => \@names,
        app   => $app,
    };
    return $self;
}

sub sse {
    my ($self, $path, $app) = @_;
    my ($regex, @names) = $self->_compile_path($path);
    push @{$self->{sse_routes}}, {
        path  => $path,
        regex => $regex,
        names => \@names,
        app   => $app,
    };
    return $self;
}

sub route {
    my ($self, $method, $path, $app) = @_;

    my ($regex, @names) = $self->_compile_path($path);
    push @{$self->{routes}}, {
        method => uc($method),
        path   => $path,
        regex  => $regex,
        names  => \@names,
        app    => $app,
    };
    return $self;
}

sub _compile_path {
    my ($self, $path) = @_;

    my @names;
    my $regex = $path;

    # Handle wildcard/splat
    if ($regex =~ s{\*(\w+)}{(.+)}g) {
        push @names, $1;
    }

    # Handle named parameters
    while ($regex =~ s{:(\w+)}{([^/]+)}) {
        push @names, $1;
    }

    return (qr{^$regex$}, @names);
}

sub to_app {
    my ($self) = @_;

    my @routes           = @{$self->{routes}};
    my @websocket_routes = @{$self->{websocket_routes}};
    my @sse_routes       = @{$self->{sse_routes}};
    my @mounts           = @{$self->{mounts}};
    my $not_found        = $self->{not_found};

    return async sub {
        my ($scope, $receive, $send) = @_;
        my $type   = $scope->{type} // 'http';
        my $method = uc($scope->{method} // '');
        my $path   = $scope->{path} // '/';

        # Ignore lifespan events
        return if $type eq 'lifespan';

        # Check mounts first (longest prefix first for proper matching)
        for my $m (sort { length($b->{prefix}) <=> length($a->{prefix}) } @mounts) {
            my $prefix = $m->{prefix};
            if ($path eq $prefix || $path =~ m{^\Q$prefix\E(/.*)$}) {
                my $sub_path = $1 // '/';
                my $new_scope = {
                    %$scope,
                    path      => $sub_path,
                    root_path => ($scope->{root_path} // '') . $prefix,
                };
                await $m->{app}->($new_scope, $receive, $send);
                return;
            }
        }

        # WebSocket routes (path-only matching)
        if ($type eq 'websocket') {
            for my $route (@websocket_routes) {
                if ($path =~ $route->{regex}) {
                    my @captures = ($path =~ $route->{regex});
                    my %params;
                    for my $i (0 .. $#{$route->{names}}) {
                        $params{$route->{names}[$i]} = $captures[$i];
                    }
                    my $new_scope = {
                        %$scope,
                        'pagi.router' => {
                            params => \%params,
                            route  => $route->{path},
                        },
                    };
                    await $route->{app}->($new_scope, $receive, $send);
                    return;
                }
            }
            # No websocket route matched - 404
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

        # SSE routes (path-only matching)
        if ($type eq 'sse') {
            for my $route (@sse_routes) {
                if ($path =~ $route->{regex}) {
                    my @captures = ($path =~ $route->{regex});
                    my %params;
                    for my $i (0 .. $#{$route->{names}}) {
                        $params{$route->{names}[$i]} = $captures[$i];
                    }
                    my $new_scope = {
                        %$scope,
                        'pagi.router' => {
                            params => \%params,
                            route  => $route->{path},
                        },
                    };
                    await $route->{app}->($new_scope, $receive, $send);
                    return;
                }
            }
            # No SSE route matched - 404
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

        # HTTP routes (method + path matching) - existing logic
        # HEAD should match GET routes
        my $match_method = $method eq 'HEAD' ? 'GET' : $method;

        my @method_matches;

        for my $route (@routes) {
            if ($path =~ $route->{regex}) {
                my @captures = ($path =~ $route->{regex});

                # Check method
                if ($route->{method} eq $match_method || $route->{method} eq $method) {
                    # Build params
                    my %params;
                    for my $i (0 .. $#{$route->{names}}) {
                        $params{$route->{names}[$i]} = $captures[$i];
                    }

                    my $new_scope = {
                        %$scope,
                        'pagi.router' => {
                            params => \%params,
                            route  => $route->{path},
                        },
                    };

                    await $route->{app}->($new_scope, $receive, $send);
                    return;
                }

                push @method_matches, $route->{method};
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

        # No match - 404
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

URL router with support for path parameters, wildcards, and sub-router
mounting. Routes requests based on HTTP method and path pattern. Returns
404 for unmatched paths and 405 for unmatched methods.

=head1 OPTIONS

=over 4

=item * C<not_found> - Custom app to handle unmatched routes

=back

=head1 METHODS

=head2 Route Methods

    $router->get($path => $app);
    $router->post($path => $app);
    $router->put($path => $app);
    $router->patch($path => $app);
    $router->delete($path => $app);
    $router->head($path => $app);
    $router->options($path => $app);

Register a route for the given HTTP method. Returns C<$self> for chaining.

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

=head1 PATH PATTERNS

=over 4

=item * C</users/:id> - Named parameter, captured as C<params-E<gt>{id}>

=item * C</files/*path> - Wildcard, captures rest of path as C<params-E<gt>{path}>

=back

=head1 SCOPE ADDITIONS

The matched route adds C<pagi.router> to scope:

    $scope->{'pagi.router'}{params}  # Captured parameters
    $scope->{'pagi.router'}{route}   # Matched route pattern

For mounted apps, C<root_path> is updated to include the mount prefix.

=cut
