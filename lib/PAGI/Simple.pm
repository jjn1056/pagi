package PAGI::Simple;

use strict;
use warnings;
use experimental 'signatures';

our $VERSION = '0.01';

use Future::AsyncAwait;
use Scalar::Util qw(blessed);
use PAGI::Simple::Router;
use PAGI::Simple::Context;
use PAGI::Simple::WebSocket;
use PAGI::Simple::SSE;
use PAGI::App::Directory;

=encoding UTF-8

=head1 NAME

PAGI::Simple - A micro web framework built on PAGI

=head1 SYNOPSIS

    use PAGI::Simple;

    my $app = PAGI::Simple->new;

    $app->get('/' => sub ($c) {
        $c->text("Hello, World!");
    });

    $app->get('/users/:id' => sub ($c) {
        my $id = $c->param('id');
        $c->json({ user_id => $id });
    });

    $app->post('/users' => sub ($c) {
        my $data = $c->req->json_body;
        $c->json({ created => $data }, 201);
    });

    # Run with pagi-server
    $app->to_app;

=head1 DESCRIPTION

PAGI::Simple is a lightweight micro web framework built on top of PAGI
(Perl Asynchronous Gateway Interface). It provides a simple, expressive
API for building web applications with support for:

=over 4

=item * HTTP routing with path parameters

=item * WebSocket connections with pub/sub

=item * Server-Sent Events (SSE)

=item * Middleware (global and per-route)

=item * Request/Response helpers

=back

=head1 FEATURE OVERVIEW

    Feature              Description                          See Also
    ─────────────────────────────────────────────────────────────────────
    Routing              GET, POST, PUT, DELETE, PATCH        get(), post(), etc.
    Path Parameters      /users/:id, /files/*path             path_params
    Route Groups         Prefix & middleware inheritance       group()
    Named Routes         URL generation from route names       name(), url_for()
    Mounting             Sub-application composition           mount()

    Views/Templates      Embedded Perl templates               views(), render()
    Layouts              Nested layout inheritance             extends(), content()
    Partials             Reusable template fragments           include()

    Middleware           Before/after request processing       middleware(), use()
    Hooks                Lifecycle events                      before(), after()
    Error Handlers       Custom error pages                    error()

    Cookies              Read/write with attributes            cookie(), req->cookie()
    Content Negotiation  Accept header parsing                 accepts(), respond_to()
    File Uploads         Multipart form handling               upload(), uploads()
    Streaming            Chunked responses                     stream(), send_file()
    CORS                 Cross-origin requests                 cors(), use_cors()
    Logging              Request logging                       enable_logging()

    WebSocket            Real-time bidirectional               websocket()
    SSE                  Server-sent events                    sse()
    PubSub               In-memory message passing             PubSub->instance

=head1 GETTING STARTED

=head2 Creating Your First App

    #!/usr/bin/env perl
    use PAGI::Simple;

    my $app = PAGI::Simple->new;

    # Simple text response
    $app->get('/' => sub ($c) {
        $c->text('Hello, World!');
    });

    # JSON API endpoint
    $app->get('/api/status' => sub ($c) {
        $c->json({ status => 'ok', version => '1.0' });
    });

    # Path parameters
    $app->get('/users/:id' => sub ($c) {
        my $id = $c->path_params->{id};
        $c->json({ user_id => $id });
    });

    # POST with JSON body
    $app->post('/users' => sub ($c) {
        my $data = $c->req->json_body->get;
        # Create user...
        $c->status(201)->json({ created => 1 });
    });

    $app->to_app;

Run with: C<pagi-server --port 3000 app.pl>

=head2 Adding Middleware

    # Define reusable middleware
    $app->middleware(auth => sub ($c, $next) {
        my $token = $c->req->header('Authorization');
        if (valid_token($token)) {
            $c->stash->{user} = get_user($token);
            return $next->();
        }
        $c->status(401)->json({ error => 'Unauthorized' });
    });

    # Apply to specific routes
    $app->get('/profile' => [qw(auth)] => sub ($c) {
        $c->json({ user => $c->stash->{user} });
    });

=head2 Route Groups

    $app->group('/api' => sub ($app) {
        $app->group('/v1' => [qw(auth)] => sub ($app) {
            $app->get('/users' => sub ($c) { ... });
            $app->post('/users' => sub ($c) { ... });
        });
    });

=head2 WebSocket Support

    $app->websocket('/chat' => sub ($ws) {
        $ws->join('chat:lobby');

        $ws->on(message => sub ($data) {
            $ws->broadcast('chat:lobby', $data);
        });
    });

=head2 Server-Sent Events

    $app->sse('/notifications' => sub ($sse) {
        $sse->subscribe('user:notifications');
    });

=head2 Views and Templates

    # Configure views (relative to app file)
    my $app = PAGI::Simple->new(
        name  => 'My App',
        views => 'templates',
    );

    # Render a template with variables
    $app->get('/' => sub ($c) {
        $c->render('index', title => 'Home', items => \@items);
    });

    # templates/index.html.ep
    <% extends('layouts/default', title => $v->{title}) %>
    <ul>
    <% for my $item (@{$v->{items}}) { %>
        <li><%= $item %></li>
    <% } %>
    </ul>

Templates use embedded Perl syntax. Layouts can be nested (admin layout
extends base layout). Use C<content_for()> to inject scripts/styles into
layout slots, and C<include()> for partials. See L<PAGI::Simple::View>
for full documentation.

=head1 COMPARISON WITH RAW PAGI

PAGI::Simple provides a higher-level abstraction over raw PAGI:

    ┌─────────────────────────────────────────────────────────────────┐
    │ Raw PAGI                        │ PAGI::Simple                  │
    ├─────────────────────────────────┼───────────────────────────────┤
    │ Manual scope parsing            │ $c->req->path, params, etc.   │
    │ Manual response building        │ $c->json(), $c->html()        │
    │ Manual header management        │ $c->header(), $c->status()    │
    │ No routing                      │ Built-in router with params   │
    │ Manual WebSocket protocol       │ $ws->on(), $ws->send()        │
    │ Manual SSE formatting           │ $sse->send_event()            │
    │ No middleware                   │ Composable middleware chain   │
    └─────────────────────────────────┴───────────────────────────────┘

Raw PAGI example:

    sub ($scope, $receive, $send) {
        my $path = $scope->{path};
        my $method = $scope->{method};

        await $send->({
            type => 'http.response.start',
            status => 200,
            headers => [['content-type', 'application/json']],
        });
        await $send->({
            type => 'http.response.body',
            body => '{"message":"hello"}',
        });
    }

PAGI::Simple equivalent:

    $app->get('/' => sub ($c) {
        $c->json({ message => 'hello' });
    });

=head1 MIGRATING FROM OTHER FRAMEWORKS

=head2 From Mojolicious

    # Mojolicious                       # PAGI::Simple
    get '/' => sub ($c) {               $app->get('/' => sub ($c) {
        $c->render(text => 'Hi');           $c->text('Hi');
    };                                  });

    get '/user/:id' => sub ($c) {       $app->get('/user/:id' => sub ($c) {
        my $id = $c->param('id');           my $id = $c->path_params->{id};
        $c->render(json => {...});          $c->json({...});
    };                                  });

=head2 From Dancer2

    # Dancer2                           # PAGI::Simple
    get '/' => sub {                    $app->get('/' => sub ($c) {
        return 'Hello';                     $c->text('Hello');
    };                                  });

    post '/user' => sub {               $app->post('/user' => sub ($c) {
        my $data = decode_json(             my $data = $c->req->json_body->get;
            request->body);                 $c->json({...});
        return to_json({...});          });
    };

=head2 From Plack/PSGI

PAGI is conceptually similar to PSGI but async-native. Main differences:

=over 4

=item * PAGI uses async/await instead of callbacks

=item * Responses are sent via the C<send> coderef, not returned

=item * WebSocket and SSE are first-class citizens

=back

=head1 PERFORMANCE CONSIDERATIONS

=head2 Async/Await

PAGI::Simple uses L<Future::AsyncAwait> for async operations. Database
queries, HTTP clients, and I/O should use async-compatible libraries:

    # Good: Non-blocking database query
    $app->get('/users' => sub ($c) {
        my $users = await $db->query('SELECT * FROM users');
        $c->json($users);
    });

    # Avoid: Blocking operations
    # These block the entire event loop
    $app->get('/slow' => sub ($c) {
        my $result = LWP::UserAgent->new->get($url);  # BLOCKING!
        $c->json($result);
    });

=head2 Memory Usage

=over 4

=item * Use C<< $c->stream() >> for large responses instead of buffering

=item * Use C<< $c->send_file() >> for file downloads

=item * File uploads spool to disk above 64KB by default

=item * WebSocket/SSE connections consume memory per connection

=back

=head2 Connection Limits

Each WebSocket and SSE connection holds resources. For high-concurrency:

=over 4

=item * Monitor connection counts per channel

=item * Implement connection timeouts

=item * Consider external message brokers for multi-process scaling

=back

=head1 BLOCKING OPERATIONS

PAGI::Simple runs on an async event loop. Blocking operations (DBI queries,
file I/O, CPU-intensive code) will freeze all concurrent requests. Use
C<run_blocking()> to offload blocking work to worker processes.

=head2 Enabling Workers

    my $app = PAGI::Simple->new(
        name    => 'My App',
        workers => { max_workers => 4 },
    );

=head2 Using run_blocking

    $app->get('/search' => async sub ($c) {
        my $query = $c->query_params->{q};
        my $limit = 100;

        # Pass arguments after the coderef
        my $results = await $c->run_blocking(sub {
            my ($search, $max) = @_;  # Receive via @_
            my $dbh = DBI->connect($ENV{DB_DSN}, $ENV{DB_USER}, $ENV{DB_PASS});
            return $dbh->selectall_arrayref(
                "SELECT * FROM items WHERE name LIKE ? LIMIT ?",
                { Slice => {} },
                "%$search%", $max
            );
        }, $query, $limit);

        $c->json({ results => $results });
    });

=head2 Passing Arguments

Pass data to workers as arguments after the coderef. Arguments are serialized
and available via C<@_> in the worker:

    my $id = $c->path_params->{id};
    my $opts = { status => 'active', limit => 10 };

    my $result = await $c->run_blocking(sub {
        my ($user_id, $options) = @_;
        # Use $user_id and $options here
    }, $id, $opts);

B<Note>: Due to a B::Deparse limitation, subroutine signatures (C<sub ($a, $b)>)
do not work. Use traditional C<my (...) = @_> argument handling.

=head2 Error Handling

Exceptions in workers propagate back as Future failures:

    my $result = eval {
        await $c->run_blocking(sub {
            die "Something went wrong" if $error;
            return compute_result();
        });
    };

    if ($@) {
        $c->status(500)->json({ error => "$@" });
        return;
    }

    $c->json($result);

=head2 When to Use

Use C<run_blocking> for:

=over 4

=item * Database queries (DBI is blocking)

=item * File I/O (especially large files)

=item * CPU-intensive computations

=item * Legacy libraries without async support

=item * External command execution

=back

Do NOT use for operations that already support async (HTTP::Tiny::Async,
async database drivers, etc.) - using workers adds IPC overhead.

=head1 METHODS

=cut

=head2 new

    my $app = PAGI::Simple->new(%options);

Create a new PAGI::Simple application.

Options:

=over 4

=item * C<name> - Application name (default: 'PAGI::Simple')

=item * C<views> - Configure template rendering. Can be:

=over 4

=item * A string (directory path): C<< views => 'templates' >>

=item * A hashref with options: C<< views => { directory => 'templates', prepend => '...' } >>

=item * C<undef> to use the default C<./templates> directory

=back

Relative paths are resolved relative to the directory containing the file
that creates the PAGI::Simple app. See L</views> for available options.

=item * C<share> - Mount PAGI's bundled assets. Can be:

=over 4

=item * A string (single asset): C<< share => 'htmx' >>

=item * An arrayref (multiple assets): C<< share => ['htmx', 'alpine'] >>

=back

This is equivalent to calling C<< $app->share(...) >> after construction.
See L</share> for available assets and details.

=item * C<workers> - Configure worker pool for blocking operations (optional).

If provided, enables C<< $c->run_blocking() >> in route handlers. The pool
is created lazily on first use, so there's no overhead if not used.

    workers => {
        max_workers  => 4,     # Maximum worker processes (default: 4)
        min_workers  => 1,     # Minimum workers to keep alive (default: 1)
        idle_timeout => 30,    # Kill idle workers after N seconds (default: 30)
    }

See L</BLOCKING OPERATIONS> for usage examples.

=back

Examples:

    # Simple app with views and htmx
    my $app = PAGI::Simple->new(
        name  => 'My App',
        views => 'templates',
        share => 'htmx',
    );

    # Multiple shared assets (future)
    my $app = PAGI::Simple->new(
        name  => 'My App',
        views => 'templates',
        share => ['htmx', 'alpine'],
    );

    # With view options
    my $app = PAGI::Simple->new(
        name  => 'My App',
        views => {
            directory => 'templates',
            prepend   => 'use experimental "signatures";',
            cache     => 0,
        },
    );

    # Default templates directory (./templates)
    my $app = PAGI::Simple->new(
        views => undef,
    );

=cut

# TODO: Add optional conf.pl support. If a conf.pl file exists in the app directory,
# load it and merge with constructor args. This would allow:
#
#   # conf.pl
#   {
#       name      => 'My App',
#       namespace => 'MyApp',
#       share     => 'htmx',
#       views     => { directory => './templates', ... },
#   }
#
#   # app.pl
#   my $app = PAGI::Simple->new();  # Automatically loads conf.pl
#
# Constructor args should override conf.pl values. Could also support conf.pl
# returning a coderef for dynamic config: sub { my ($caller_dir) = @_; ... }

sub new ($class, %args) {
    # Capture caller's file location for default template directory
    my ($caller_file) = (caller(0))[1];
    require File::Basename;
    require File::Spec;
    my $caller_dir = File::Basename::dirname(File::Spec->rel2abs($caller_file));

    my $name = $args{name} // 'PAGI::Simple';

    # Handle namespace: explicit, or generate from name
    my $namespace;
    if (exists $args{namespace}) {
        $namespace = $args{namespace};
    }
    else {
        # Generate namespace from app name
        $namespace = _generate_namespace($name);
    }

    # Handle lib directory: explicit, or default to 'lib'
    my $lib_dir;
    if (exists $args{lib}) {
        if (defined $args{lib}) {
            $lib_dir = $args{lib};
            # Make relative paths relative to caller dir
            unless (File::Spec->file_name_is_absolute($lib_dir)) {
                $lib_dir = File::Spec->catdir($caller_dir, $lib_dir);
            }
        }
        # lib => undef means don't add anything to @INC
    }
    else {
        # Default: 'lib' relative to caller dir
        $lib_dir = File::Spec->catdir($caller_dir, 'lib');
    }

    # Add lib to @INC if specified and not already there
    if (defined $lib_dir && !grep { $_ eq $lib_dir } @INC) {
        unshift @INC, $lib_dir;
    }

    my $self = bless {
        name       => $name,
        router     => PAGI::Simple::Router->new,
        ws_router  => PAGI::Simple::Router->new,  # WebSocket routes
        sse_router => PAGI::Simple::Router->new,  # SSE routes
        middleware => {},
        hooks      => { before => [], after => [] },
        error_handlers => {},
        stash      => {},
        _startup_hooks   => [],
        _shutdown_hooks  => [],
        _static_handlers => [],           # Static file handlers [(prefix, app), ...]
        _mounted_apps    => [],           # Mounted sub-applications [(prefix, app, middleware), ...]
        _prefix          => '',           # Current route group prefix
        _group_middleware => [],          # Current group middleware stack
        _loop            => undef,        # Event loop (set when server starts)
        _view            => undef,        # View instance for template rendering
        _view_config     => undef,        # Deferred view configuration
        _caller_dir      => $caller_dir,  # Directory of the file creating the app
        _namespace       => $namespace,   # App namespace for services, etc.
        _lib_dir         => $lib_dir,     # Lib directory added to @INC
        service_config   => $args{service_config} // {},  # Per-service configuration
        _service_registry => {},          # Initialized services (instance or coderef)
        _pending_services => [],          # Services to init at startup [(class, name), ...]
        _worker_config   => $args{workers},    # Worker pool config (undef = disabled)
        _worker_pool     => undef,             # Lazy IO::Async::Function instance
    }, $class;

    # Handle views configuration in constructor
    if (exists $args{views}) {
        $self->_configure_views($args{views});
    }

    # Handle share configuration in constructor
    if (exists $args{share}) {
        my $share = $args{share};
        # Accept string or arrayref
        my @assets = ref($share) eq 'ARRAY' ? @$share : ($share);
        $self->share(@assets);
    }

    return $self;
}

# Internal: Generate a valid Perl package namespace from app name
sub _generate_namespace ($name) {
    return 'App' unless defined $name && length $name;

    # Split on word boundaries (spaces, hyphens, underscores, colons)
    my @words = split /[\s\-_:]+/, $name;

    # Title case each word and remove invalid characters
    my @parts;
    for my $word (@words) {
        # Remove non-alphanumeric characters
        $word =~ s/[^A-Za-z0-9]//g;
        next unless length $word;
        # Title case
        push @parts, ucfirst(lc($word));
    }

    my $namespace = join('', @parts);

    # Ensure we have something
    $namespace = 'App' unless length $namespace;

    # Ensure starts with letter (prepend 'App' if starts with number)
    $namespace = "App$namespace" if $namespace =~ /^[0-9]/;

    return $namespace;
}

# Internal: Configure views from constructor or views() method
sub _configure_views ($self, $config) {
    require PAGI::Simple::View;

    my ($template_dir, %options);

    if (!defined $config) {
        # views => undef means use default directory (./templates)
        $template_dir = File::Spec->catdir($self->{_caller_dir}, 'templates');
    }
    elsif (!ref($config)) {
        # Shorthand: views => './templates' or views => 'templates'
        $template_dir = $config;
        # Make relative paths relative to caller dir
        unless (File::Spec->file_name_is_absolute($template_dir)) {
            $template_dir = File::Spec->catdir($self->{_caller_dir}, $template_dir);
        }
    }
    elsif (ref($config) eq 'HASH') {
        # Full syntax: views => { directory => './templates', prepend => '...' }
        %options = %$config;
        $template_dir = delete $options{directory};

        # Default directory is ./templates relative to caller
        $template_dir //= 'templates';

        # Make relative paths relative to caller dir
        unless (File::Spec->file_name_is_absolute($template_dir)) {
            $template_dir = File::Spec->catdir($self->{_caller_dir}, $template_dir);
        }
    }
    else {
        die "Invalid views configuration: expected string or hashref";
    }

    $self->{_view} = PAGI::Simple::View->new(
        template_dir => $template_dir,
        app          => $self,
        %options,
    );

    return $self;
}

=head2 router

    my $router = $app->router;

Returns the application's Router instance.

=cut

sub router ($self) {
    return $self->{router};
}

=head2 name

    my $name = $app->name;

Returns the application name.

=cut

sub name ($self) {
    return $self->{name};
}

=head2 stash

    my $stash = $app->stash;
    $app->stash->{db} = $dbh;

Application-level storage hashref. Useful for storing shared resources
like database connections that are initialized at startup.

=cut

sub stash ($self) {
    return $self->{stash};
}

=head2 views

    # Simple form - directory relative to app file
    $app->views('templates');

    # With options
    $app->views('templates', prepend => '...', cache => 0);

    # Absolute path
    $app->views('/var/www/templates');

Configure template rendering for the application. Creates a PAGI::Simple::View
instance that can be used by $c->render() in route handlers.

Relative paths are resolved relative to the directory containing the file
that created the PAGI::Simple app (not the current working directory).

This method can also be called to override views configured in the constructor.

Options:

=over 4

=item * auto_escape - HTML escape by default (default: 1)

=item * extension - Template file extension (default: '.html.ep')

=item * cache - Cache compiled templates in memory (default: 1)

=item * helpers - Hashref of custom template helpers

=item * roles - Arrayref of role names to compose into view

=item * development - Development mode (no cache, verbose errors)

=item * prepend - Extra Perl code added at start of each template subroutine

=item * preamble - Package-level Perl code (use statements). To enable
subroutine signatures in templates: C<< preamble => 'use experimental "signatures";' >>

=back

Returns $app for chaining.

=cut

sub views ($self, $template_dir = undef, @args) {
    # Build config hashref for _configure_views
    my $config;

    # Handle backward compatibility: views($dir, \%hashref)
    my %options;
    if (@args == 1 && ref($args[0]) eq 'HASH') {
        %options = %{$args[0]};
    }
    elsif (@args) {
        %options = @args;
    }

    if (defined $template_dir && !%options) {
        # Simple form: views('templates')
        $config = $template_dir;
    }
    elsif (defined $template_dir) {
        # With options: views('templates', prepend => '...') or views('templates', \%opts)
        $config = { directory => $template_dir, %options };
    }
    else {
        # No args: views() - use default directory
        $config = undef;
    }

    return $self->_configure_views($config);
}

=head2 view

    my $view = $app->view;

Returns the PAGI::Simple::View instance configured by views().
Returns undef if views() has not been called.

=cut

sub view ($self) {
    return $self->{_view};
}

=head2 loop

    my $loop = $app->loop;

Returns the IO::Async::Loop instance when running under a PAGI server.
Returns undef if not yet running or if the server doesn't provide a loop.

This is useful for advanced async operations like timers, custom IO::Async
notifiers, or direct use of PAGI::Util::AsyncFile.

    $app->on(startup => sub ($app) {
        # Set up a periodic timer
        my $loop = $app->loop;
        $loop->add(IO::Async::Timer::Periodic->new(
            interval => 60,
            on_tick => sub { cleanup_stale_sessions() },
        )->start) if $loop;
    });

=cut

sub loop ($self) {
    return $self->{_loop};
}

=head2 worker_pool

    my $pool = $app->worker_pool;

Returns the IO::Async::Function worker pool instance, or undef if workers
are not configured. The pool is created lazily on first access.

This is primarily for internal use. Most users should use
C<< $c->run_blocking() >> instead.

Requires C<workers> configuration in the constructor:

    my $app = PAGI::Simple->new(
        workers => { max_workers => 4 },
    );

=cut

sub worker_pool ($self) {
    return $self->_get_worker_pool;
}

# Internal: Lazily create the worker pool
sub _get_worker_pool ($self) {
    return $self->{_worker_pool} if $self->{_worker_pool};

    # Feature not enabled
    return undef unless $self->{_worker_config};

    # Need event loop
    my $loop = $self->{_loop};
    die "Worker pool requires event loop (are you running under pagi-server?)"
        unless $loop;

    require IO::Async::Function;

    my $config = $self->{_worker_config};
    # Normalize config - accept simple hashref or just 'true'
    $config = {} if !ref($config);

    # Worker code receives serialized code string and arguments
    # We use B::Deparse to serialize coderefs since IO::Async::Channel
    # uses Sereal which doesn't support coderefs. Arguments are serialized
    # normally by Sereal and passed to the reconstructed coderef.
    my $pool = IO::Async::Function->new(
        code => sub {
            my ($code_string, $args) = @_;
            # Reconstruct the coderef from its deparsed string
            # We need to enable signatures since B::Deparse preserves them
            my $coderef = eval "use experimental 'signatures'; $code_string";
            die "Failed to reconstruct code: $@" if $@;
            # Execute with the provided arguments
            return $coderef->(@$args);
        },
        max_workers   => $config->{max_workers}   // 4,
        min_workers   => $config->{min_workers}   // 1,
        idle_timeout  => $config->{idle_timeout}  // 30,
    );

    $loop->add($pool);
    $self->{_worker_pool} = $pool;

    return $pool;
}

# Internal: Serialize a coderef for worker execution
sub _serialize_code_for_worker ($self, $code) {
    require B::Deparse;
    my $deparser = B::Deparse->new('-p', '-sC');
    my $code_string = $deparser->coderef2text($code);
    # Wrap in sub to make it a valid coderef when evaled
    return "sub $code_string";
}

=head2 pubsub

    my $pubsub = $app->pubsub;
    $pubsub->publish('notifications', { message => 'Hello!' });

Returns the PAGI::Simple::PubSub singleton instance for publishing messages
to SSE and WebSocket subscribers.

B<Why is this on $app and not $c?>

PubSub is an application-level service, not a request-scoped resource. The
singleton manages all subscriptions across all connections in the process.
Accessing it via C<< $app->pubsub >> makes this architecture clear.

SSE and WebSocket contexts already have C<< $sse->publish() >> and
C<< $ws->broadcast() >> for convenience since they're inherently connected
to the pub/sub system. HTTP handlers use C<< $app->pubsub >> when they need
to notify real-time subscribers (e.g., broadcasting that a resource was
created, updated, or deleted).

B<Common patterns:>

    # In an HTTP handler - notify SSE/WebSocket subscribers
    $app->post('/messages' => async sub ($c) {
        my $msg = await $c->req->json_body;
        save_message($msg);

        # Broadcast to all subscribers on the 'chat' channel
        $app->pubsub->publish('chat', $msg);

        $c->status(201)->json($msg);
    });

    # In an SSE handler - subscribe uses callback, publish is built-in
    $app->sse('/events' => sub ($sse) {
        $sse->subscribe('chat', sub ($msg) {
            $sse->send_event(event => 'message', data => $msg);
        });
    });

See L<PAGI::Simple::PubSub> for the full API including subscribe/unsubscribe,
channel management, and subscriber counts.

=cut

sub pubsub ($self) {
    require PAGI::Simple::PubSub;
    return PAGI::Simple::PubSub->instance;
}

=head2 home

    my $home = $app->home;

Returns the home directory of the application as a string. This is the
directory containing the file that created the PAGI::Simple app (typically
your C<app.pl> or main application script).

Useful for locating app-specific files and directories:

    my $config_file = $app->home . '/config.yml';
    my $data_dir = $app->home . '/data';

    # Mount app's own static files
    $app->static('/assets' => $app->home . '/public');

Note: This is different from C<share_dir()> which locates PAGI's bundled
assets. Use C<home> for your application's files, use C<share_dir> for
PAGI's bundled libraries like htmx.

=cut

sub home ($self) {
    return $self->{_caller_dir};
}

=head2 namespace

    my $ns = $app->namespace;  # e.g., 'LivePoll'

Returns the application's namespace. This is used for resolving service classes:
C<< $c->service('Poll') >> becomes C<< ${namespace}::Service::Poll >>.

The namespace is either:

=over 4

=item * Explicitly set via C<< namespace => 'MyApp' >> in the constructor

=item * Auto-generated from the app name (title-cased, special chars removed)

=back

=cut

sub namespace ($self) {
    return $self->{_namespace};
}

=head2 lib_dir

    my $lib = $app->lib_dir;  # e.g., '/path/to/app/lib'

Returns the application's lib directory path, which was added to C<@INC>
at app creation. Returns C<undef> if lib was disabled via C<< lib => undef >>.

=cut

sub lib_dir ($self) {
    return $self->{_lib_dir};
}

=head2 add_service

    # Register a service class manually
    $app->add_service('Cache', 'MyApp::Service::Cache');

    # Register with a factory coderef
    $app->add_service('Redis', sub ($app) {
        return MyRedisConnection->new(host => 'localhost');
    });

Register a service with the application. Services are initialized at startup
(during lifespan.startup) and available via C<< $c->service('Name') >>.

The second argument can be:

=over 4

=item * A class name that inherits from a PAGI::Simple::Service scope class

=item * A coderef that receives C<$app> and returns an instance or factory

=back

Returns C<$app> for chaining.

=cut

sub add_service ($self, $name, $class_or_factory) {
    if (ref($class_or_factory) eq 'CODE') {
        # Factory coderef - will be called at startup
        push @{$self->{_pending_services}}, {
            name => $name,
            factory => $class_or_factory,
        };
    }
    else {
        # Class name - will be loaded and init_service called
        push @{$self->{_pending_services}}, {
            name => $name,
            class => $class_or_factory,
        };
    }
    return $self;
}

=head2 service_registry

    my $registry = $app->service_registry;

Returns the service registry hashref. Each key is a service name, and the
value is either:

=over 4

=item * An instance (for PerApp services)

=item * A coderef factory (for Factory and PerRequest services)

=back

This is primarily for internal use. Use C<< $c->service('Name') >> to access
services from route handlers.

=cut

sub service_registry ($self) {
    return $self->{_service_registry};
}

# Internal: Discover services in ${namespace}::Service::*
sub _discover_services ($self) {
    my $namespace = $self->{_namespace};
    return unless $namespace;

    my $service_ns = "${namespace}::Service";

    # Use Module::Pluggable to find service classes
    eval {
        require Module::Pluggable;
        Module::Pluggable->import(
            search_path => [$service_ns],
            require => 0,
            sub_name => '_service_plugins',
            on_require_error => sub { },  # Silently skip errors
        );
    };
    return if $@;  # Module::Pluggable not available

    # Get all service classes
    my @classes = $self->_service_plugins;

    for my $class (@classes) {
        # Load the class
        my $loaded = eval "require $class; 1";
        next unless $loaded;

        # Must inherit from a Service scope class
        next unless $class->isa('PAGI::Simple::Service::_Base');

        # Extract short name from class (e.g., MyApp::Service::Poll -> Poll)
        my $name = $class;
        $name =~ s/^\Q${service_ns}::\E//;

        # Don't overwrite manually registered services
        next if exists $self->{_service_registry}{$name};
        next if grep { $_->{name} eq $name } @{$self->{_pending_services}};

        # Add to pending list
        push @{$self->{_pending_services}}, {
            name => $name,
            class => $class,
        };
    }
}

# Internal: Initialize all pending services
sub _init_services ($self) {
    # First, discover services
    $self->_discover_services();

    # Then initialize all pending services
    for my $pending (@{$self->{_pending_services}}) {
        my $name = $pending->{name};

        if ($pending->{factory}) {
            # Custom factory - call it and store result
            my $result = $pending->{factory}->($self);
            $self->{_service_registry}{$name} = $result;
            warn "[PAGI::Simple]   Service: $name (factory)\n";
        }
        elsif ($pending->{class}) {
            my $class = $pending->{class};

            # Load the class if not already loaded
            my $loaded = eval "require $class; 1";
            unless ($loaded) {
                warn "[PAGI::Simple] Warning: Failed to load service $class: $@\n";
                next;
            }

            # Get config for this service
            my $config = $self->{service_config}{$name} // {};

            # Call init_service - returns instance or coderef
            my $result = eval { $class->init_service($self, $config) };
            if ($@) {
                warn "[PAGI::Simple] Warning: Failed to init service $name: $@\n";
                next;
            }

            $self->{_service_registry}{$name} = $result;

            # Log what type of service
            my $type = ref($result) eq 'CODE' ? 'factory' : 'singleton';
            warn "[PAGI::Simple]   Service: $name ($type)\n";
        }
    }

    # Clear pending list
    @{$self->{_pending_services}} = ();
}

=head2 share_dir

    my $htmx_dir = $app->share_dir('htmx');

Returns the path to a PAGI bundled asset directory. Works both in development
(from git checkout) and when installed via CPAN.

Available bundled assets:

=over 4

=item * C<htmx> - htmx library and extensions (htmx.min.js, ext/sse.js, ext/ws.js)

=back

This method is useful if you need the raw path. For simply serving bundled
assets as static files, use C<share()> instead which is more convenient.

    # Get the path (for custom use)
    my $path = $app->share_dir('htmx');

    # Or use share() for static mounting (preferred)
    $app->share('htmx');

=cut

sub share_dir ($self, $name) {
    require File::Basename;
    require File::Spec;
    require Cwd;

    # First try development location (share/ relative to lib/PAGI/)
    my $lib_dir = File::Basename::dirname(__FILE__);
    my $dev_dir = File::Spec->catdir($lib_dir, '..', '..', 'share', $name);

    if (-d $dev_dir) {
        # Resolve to absolute path without .. components
        return Cwd::abs_path($dev_dir);
    }

    # Fall back to installed location via File::ShareDir::Dist
    my $dist_dir = eval {
        require File::ShareDir::Dist;
        my $share = File::ShareDir::Dist::dist_share('PAGI-Server');
        $share ? File::Spec->catdir($share, $name) : undef;
    };

    if ($dist_dir && -d $dist_dir) {
        return Cwd::abs_path($dist_dir);
    }

    die "PAGI share directory '$name' not found";
}

=head2 share

    $app->share('htmx');

Mount PAGI's bundled assets as static files. Each asset is mounted at its
predefined URL path to ensure compatibility with PAGI's template helpers.

    # Mount htmx at /static/htmx (required for htmx() helper)
    $app->share('htmx');

    # Mount multiple assets at once
    $app->share('htmx', 'alpine');  # future example

Returns C<$app> for chaining:

    $app->share('htmx')
        ->get('/' => sub ($c) { ... });

B<Available bundled assets:>

=over 4

=item * C<htmx> - htmx library (2.0.8) with SSE and WebSocket extensions, mounted at C</static/htmx>

=back

B<Constructor option:>

You can also configure shared assets in the constructor:

    my $app = PAGI::Simple->new(
        name  => 'My App',
        views => 'templates',
        share => 'htmx',              # single asset
    );

    # Or multiple assets
    my $app = PAGI::Simple->new(
        name  => 'My App',
        views => 'templates',
        share => ['htmx', 'alpine'],  # arrayref for multiple
    );

B<Example with htmx helpers:>

    # Recommended: configure in constructor
    my $app = PAGI::Simple->new(
        name  => 'My App',
        views => 'templates',
        share => 'htmx',
    );

    # In templates, use the htmx() helper
    # <%= htmx() %>
    # <%= htmx_sse() %>

B<Note:> The C<htmx()> and C<htmx_sse()> template helpers require
C<htmx> to be shared first (via constructor or method). This ensures
the htmx JavaScript files are available at the paths the helpers expect.

=cut

# MAINTAINER NOTE: To add a new bundled asset:
# 1. Add the asset files to share/$name/
# 2. Add entry to %SHARE_ASSETS below: 'name' => '/mount/path'
# 3. Update POD above to document the new asset
# 4. If the asset has template helpers, gate them with has_shared() check
#    (see PAGI::Simple::View htmx() for example)

my %SHARE_ASSETS = (
    htmx => '/static/htmx',
);

sub share ($self, @names) {
    for my $name (@names) {
        unless (exists $SHARE_ASSETS{$name}) {
            my $available = join ', ', sort keys %SHARE_ASSETS;
            die "Unknown shared asset '$name'. Available: $available";
        }

        my $prefix = $SHARE_ASSETS{$name};
        my $dir = $self->share_dir($name);
        $self->static($prefix => $dir);

        # Track that this asset has been shared
        $self->{_shared_assets}{$name} = 1;
    }
    return $self;
}

=head2 has_shared

    if ($app->has_shared('htmx')) { ... }

Returns true if the specified asset has been mounted via C<share()>.
This is used internally by template helpers to ensure required assets
are available.

=cut

sub has_shared ($self, $name) {
    return $self->{_shared_assets}{$name} ? 1 : 0;
}

=head2 to_app

    my $pagi_app = $app->to_app;

Returns a PAGI-compatible coderef that can be used with PAGI::Server
or pagi-server CLI.

=cut

sub to_app ($self) {
    return async sub ($scope, $receive, $send) {
        await $self->_handle_request($scope, $receive, $send);
    };
}

# Internal: Main request dispatcher
async sub _handle_request ($self, $scope, $receive, $send) {
    my $type = $scope->{type} // '';

    # Capture the event loop from the scope (provided by PAGI server)
    if (my $loop = $scope->{pagi}{loop}) {
        $self->{_loop} //= $loop;
    }

    if ($type eq 'lifespan') {
        await $self->_handle_lifespan($scope, $receive, $send);
    }
    elsif ($type eq 'http' || $type eq 'websocket' || $type eq 'sse') {
        # Check mounted apps first - they take precedence
        if (@{$self->{_mounted_apps}}) {
            my $dispatched = await $self->_dispatch_to_mounted($scope, $receive, $send);
            return if $dispatched;
        }

        # No mount matched, handle with normal routing
        if ($type eq 'http') {
            await $self->_handle_http($scope, $receive, $send);
        }
        elsif ($type eq 'websocket') {
            await $self->_handle_websocket($scope, $receive, $send);
        }
        else {  # sse
            await $self->_handle_sse($scope, $receive, $send);
        }
    }
    else {
        die "Unsupported scope type: $type";
    }
}

# Internal: Handle lifespan events
async sub _handle_lifespan ($self, $scope, $receive, $send) {
    while (1) {
        my $event = await $receive->();
        my $type = $event->{type} // '';

        if ($type eq 'lifespan.startup') {
            # Debug output on startup
            warn "[PAGI::Simple] Starting '$self->{name}'\n";
            warn "[PAGI::Simple]   Home dir:   $self->{_caller_dir}\n";
            warn "[PAGI::Simple]   Namespace:  $self->{_namespace}\n";

            # Show lib dir status
            if (defined $self->{_lib_dir}) {
                if (-d $self->{_lib_dir}) {
                    warn "[PAGI::Simple]   Lib dir:    $self->{_lib_dir}\n";
                } else {
                    warn "[PAGI::Simple]   Lib dir:    $self->{_lib_dir} (not found)\n";
                }
            } else {
                warn "[PAGI::Simple]   Lib dir:    (none)\n";
            }

            if ($self->{_shared_assets} && %{$self->{_shared_assets}}) {
                for my $asset (sort keys %{$self->{_shared_assets}}) {
                    my $dir = eval { $self->share_dir($asset) } // '(not found)';
                    warn "[PAGI::Simple]   Share dir ($asset): $dir\n";
                }
            }

            # Show view template directory
            if ($self->{_view}) {
                my $tpl_dir = $self->{_view}->template_dir;
                if (-d $tpl_dir) {
                    warn "[PAGI::Simple]   Templates:  $tpl_dir\n";
                } else {
                    warn "[PAGI::Simple]   Templates:  $tpl_dir (not found)\n";
                }
            }

            # Initialize services before startup hooks
            eval {
                $self->_init_services();
            };
            if ($@) {
                await $send->({
                    type    => 'lifespan.startup.failed',
                    message => "Service initialization failed: $@",
                });
                return;
            }

            eval {
                for my $hook (@{$self->{_startup_hooks}}) {
                    $hook->($self);
                }
            };
            if ($@) {
                await $send->({
                    type    => 'lifespan.startup.failed',
                    message => "$@",
                });
                return;
            }
            await $send->({ type => 'lifespan.startup.complete' });
        }
        elsif ($type eq 'lifespan.shutdown') {
            eval {
                for my $hook (@{$self->{_shutdown_hooks}}) {
                    $hook->($self);
                }
            };
            # Clean up worker pool if it was created
            if ($self->{_worker_pool}) {
                eval {
                    $self->{_worker_pool}->stop->get;
                    $self->{_loop}->remove($self->{_worker_pool}) if $self->{_loop};
                };
                $self->{_worker_pool} = undef;
            }
            await $send->({ type => 'lifespan.shutdown.complete' });
            return;
        }
    }
}

# Internal: Get a header value from scope
sub _get_header_from_scope ($scope, $name) {
    $name = lc($name);
    for my $h (@{$scope->{headers} // []}) {
        return $h->[1] if lc($h->[0]) eq $name;
    }
    return;
}

# Internal: Handle HTTP requests
async sub _handle_http ($self, $scope, $receive, $send) {
    my $method = $scope->{method} // 'GET';
    my $path   = $scope->{path} // '/';

    # Handle CORS preflight OPTIONS requests before routing
    if ($method eq 'OPTIONS' && $self->{_cors}) {
        my $origin = _get_header_from_scope($scope, 'origin');
        if ($origin) {
            my $handled = await $self->_handle_cors_preflight($scope, $send, $origin);
            return if $handled;
        }
    }

    # Try to match a route first
    my $match = $self->{router}->match($method, $path);

    if ($match) {
        # Route found - create context with path params
        my $route = $match->{route};
        my $params = $match->{params};

        my $c = PAGI::Simple::Context->new(
            app         => $self,
            scope       => $scope,
            receive     => $receive,
            send        => $send,
            path_params => $params,
        );

        my $error_to_handle;
        eval {
            # Run before hooks
            for my $hook (@{$self->{hooks}{before}}) {
                my $result = $hook->($c);
                # If hook returns a Future, await it
                if (blessed($result) && $result->can('get')) {
                    await $result;
                }
                # If hook sent a response, stop processing
                last if $c->response_started;
            }

            # Run route middleware + handler chain (only if response not started)
            unless ($c->response_started) {
                await $self->_run_middleware_chain($c, $route);
            }
        };
        if (my $err = $@) {
            # Check if this is an abort exception (expected, don't log)
            if (blessed($err) && $err->isa('PAGI::Simple::Abort')) {
                # Send the error response for abort
                unless ($c->response_started) {
                    await $self->_send_error($c, $err->code, $err->message);
                }
            }
            else {
                # Handler threw a real error - log it!
                warn "PAGI application error: $err\n";
                unless ($c->response_started) {
                    await $self->_send_error($c, 500, $err);
                }
            }
        }

        # Run after hooks (always run, even after abort or error)
        for my $hook (@{$self->{hooks}{after}}) {
            eval {
                my $result = $hook->($c);
                # If hook returns a Future, await it
                if (blessed($result) && $result->can('get')) {
                    await $result;
                }
            };
            # Ignore errors in after hooks
        }

        # Call service cleanup hooks (always run at end of request)
        $c->_call_service_cleanups();
    }
    else {
        # No route matched - check static handlers first
        for my $static (@{$self->{_static_handlers}}) {
            my $prefix = $static->{prefix};

            # Check if path starts with this prefix
            if ($path eq $prefix || $path =~ m{^\Q$prefix\E/}) {
                # Strip the prefix from the path
                my $sub_path = $path;
                $sub_path =~ s{^\Q$prefix\E}{};
                $sub_path = '/' unless $sub_path;

                # Create a modified scope with the adjusted path
                my $static_scope = { %$scope, path => $sub_path };

                # Call the static file handler
                eval {
                    await $static->{app}->($static_scope, $receive, $send);
                };
                if (my $err = $@) {
                    warn "Static file error: $err";
                }
                return;
            }
        }

        # No static match either - create context for error response
        my $c = PAGI::Simple::Context->new(
            app     => $self,
            scope   => $scope,
            receive => $receive,
            send    => $send,
        );

        # Check if path exists with different method
        my ($path_route, $allowed_methods) = $self->{router}->find_path_match($path);

        if ($path_route && @$allowed_methods) {
            # Path exists but method not allowed
            $c->res_header('Allow', join(', ', sort @$allowed_methods));
            await $self->_send_error($c, 405);
        }
        else {
            # Path not found at all
            await $self->_send_error($c, 404);
        }
    }
}

# Internal: Send error response using custom handler if available
async sub _send_error ($self, $c, $code, $error = undef) {
    my $handler = $self->get_error_handler($code);

    if ($handler) {
        my $result = $handler->($c, $error);
        if (blessed($result) && $result->isa('Future')) {
            await $result;
        }
    }
    else {
        # Default response with standard HTTP status text
        my %text = (
            400 => 'Bad Request',
            401 => 'Unauthorized',
            403 => 'Forbidden',
            404 => 'Not Found',
            405 => 'Method Not Allowed',
            409 => 'Conflict',
            410 => 'Gone',
            422 => 'Unprocessable Entity',
            429 => 'Too Many Requests',
            500 => 'Internal Server Error',
            501 => 'Not Implemented',
            502 => 'Bad Gateway',
            503 => 'Service Unavailable',
            504 => 'Gateway Timeout',
        );
        my $status_text = $text{$code} // "Error $code";
        my $message = defined $error ? "$status_text: $error" : $status_text;
        await $c->status($code)->text($message);
    }
}

# Internal: Handle WebSocket connections
async sub _handle_websocket ($self, $scope, $receive, $send) {
    my $path = $scope->{path} // '/';

    # Try to match a WebSocket route
    my $match = $self->{ws_router}->match('GET', $path);

    if ($match) {
        my $route = $match->{route};
        my $params = $match->{params};

        # Create WebSocket context
        my $ws = PAGI::Simple::WebSocket->new(
            app         => $self,
            scope       => $scope,
            receive     => $receive,
            send        => $send,
            path_params => $params,
        );

        eval {
            await $ws->_run($route->handler);
        };
        if (my $err = $@) {
            # Error in WebSocket handler - close connection if not already closed
            unless ($ws->is_closed) {
                await $ws->close(1011, "Internal error");
            }
        }
    }
    else {
        # No WebSocket route matched - close with error
        my $event = await $receive->();  # websocket.connect
        await $send->({ type => 'websocket.close', code => 4004, reason => 'Not Found' });
    }
}

# Internal: Handle SSE connections
async sub _handle_sse ($self, $scope, $receive, $send) {
    my $path = $scope->{path} // '/';

    # Try to match an SSE route
    my $match = $self->{sse_router}->match('GET', $path);

    if ($match) {
        my $route = $match->{route};
        my $params = $match->{params};

        # Create SSE context
        my $sse = PAGI::Simple::SSE->new(
            app         => $self,
            scope       => $scope,
            receive     => $receive,
            send        => $send,
            path_params => $params,
        );

        eval {
            await $sse->_run($route->handler);
        };
        if (my $err = $@) {
            # Error in SSE handler - already started, just log
            warn "SSE handler error: $err";
        }
    }
    else {
        # No SSE route matched - return 404
        await $send->({
            type    => 'sse.start',
            status  => 404,
            headers => [['content-type', 'text/plain']],
        });
        # For SSE, just return (stream ends)
    }
}

# Internal: Run route middleware chain and handler
async sub _run_middleware_chain ($self, $c, $route) {
    my @middleware_names = @{$route->middleware};
    my $handler = $route->handler;

    # If no middleware, just run the handler directly
    if (!@middleware_names) {
        my $result = $handler->($c);
        if (blessed($result) && $result->can('get')) {
            await $result;
        }
        return;
    }

    # Build the chain from inside out (handler is innermost)
    # Start with the handler as the final $next
    my $chain = sub {
        return $handler->($c);
    };

    # Wrap each middleware around the chain, in reverse order
    for my $name (reverse @middleware_names) {
        my $mw = $self->get_middleware($name);
        unless ($mw) {
            die "Unknown middleware: $name";
        }

        my $next = $chain;  # Capture current chain for closure
        $chain = sub {
            return $mw->($c, $next);
        };
    }

    # Execute the chain
    my $result = $chain->();
    if (blessed($result) && $result->can('get')) {
        await $result;
    }
}

=head2 on

    $app->on(startup => sub ($app) {
        # Initialize resources
    });

    $app->on(shutdown => sub ($app) {
        # Cleanup
    });

Register lifecycle hooks.

=cut

sub on ($self, $event, $callback) {
    if ($event eq 'startup') {
        push @{$self->{_startup_hooks}}, $callback;
    }
    elsif ($event eq 'shutdown') {
        push @{$self->{_shutdown_hooks}}, $callback;
    }
    else {
        die "Unknown lifecycle event: $event";
    }
    return $self;
}

=head2 error

    $app->error(404 => sub ($c) {
        $c->json({ error => 'Not found', path => $c->req->path });
    });

    $app->error(500 => sub ($c, $error) {
        warn "Error: $error";
        $c->json({ error => 'Internal error' });
    });

Register custom error handlers for specific HTTP status codes.
The handler receives the context and optionally the error message (for 500 errors).

Returns $app for chaining.

=cut

sub error ($self, $code, $handler) {
    $self->{error_handlers}{$code} = $handler;
    return $self;
}

=head2 get_error_handler

    my $handler = $app->get_error_handler(404);

Returns the error handler for the given status code, or undef if not defined.

=cut

sub get_error_handler ($self, $code) {
    return $self->{error_handlers}{$code};
}

=head1 MIDDLEWARE METHODS

=head2 hook

    $app->hook(before => sub ($c) {
        $c->stash->{start} = time();
    });

    $app->hook(after => sub ($c) {
        my $elapsed = time() - $c->stash->{start};
        warn "Request took ${elapsed}s";
    });

Register global middleware hooks. C<before> hooks run before the route
handler, C<after> hooks run after. Multiple hooks of the same type execute
in the order they were registered.

A C<before> hook can short-circuit request processing by sending a response.
If the response has been started, the route handler will not be called.

=cut

sub hook ($self, $type, $callback) {
    if ($type eq 'before') {
        push @{$self->{hooks}{before}}, $callback;
    }
    elsif ($type eq 'after') {
        push @{$self->{hooks}{after}}, $callback;
    }
    else {
        die "Unknown hook type: $type (expected 'before' or 'after')";
    }
    return $self;
}

=head2 enable_logging

    # Basic usage - combined format to STDERR
    $app->enable_logging;

    # Custom format
    $app->enable_logging(format => 'json');

    # Full configuration
    $app->enable_logging(
        format => 'combined',    # or 'common', 'tiny', 'json', or custom
        output => \*STDERR,      # or filename, or coderef
        skip   => ['/health', '/metrics'],  # paths to skip
    );

Enable request logging with configurable format and output.

Supported formats:

=over 4

=item * combined - Apache/nginx combined log format (default)

=item * common - Apache common log format

=item * tiny - Minimal format (method, path, status, time)

=item * json - Structured JSON for log aggregation

=item * Custom format string with specifiers like C<%h>, C<%t>, C<%r>, C<%\>s>, etc.

=back

Returns $app for chaining.

See L<PAGI::Simple::Logger> for format specifier reference.

=cut

sub enable_logging ($self, %opts) {
    require PAGI::Simple::Logger;
    require Time::HiRes;

    my $logger = PAGI::Simple::Logger->new(%opts);

    # Before hook: record start time
    $self->hook(before => sub ($c) {
        $c->{_request_start} = Time::HiRes::time();
    });

    # After hook: log the request
    $self->hook(after => sub ($c) {
        my $duration = defined $c->{_request_start}
            ? Time::HiRes::time() - $c->{_request_start}
            : 0;

        $logger->log(
            scope            => $c->scope,
            status           => $c->response_status,
            response_size    => $c->response_size,
            duration         => $duration,
            response_headers => $c->response_headers,
        );
    });

    return $self;
}

=head2 use_cors

    # Allow all origins
    $app->use_cors;

    # Specific origins
    $app->use_cors(
        origins     => ['https://app.example.com', 'https://admin.example.com'],
        methods     => [qw(GET POST PUT DELETE)],
        headers     => [qw(Content-Type Authorization X-Request-ID)],
        credentials => 1,
        max_age     => 86400,
    );

Enable CORS handling for the application. This automatically:

=over 4

=item * Responds to OPTIONS preflight requests

=item * Adds CORS headers to all responses

=item * Validates origins if a whitelist is provided

=back

Options:

=over 4

=item * origins - Arrayref of allowed origins, or ['*'] for any. Default: ['*']

=item * methods - Arrayref of allowed methods. Default: GET,POST,PUT,DELETE,PATCH,OPTIONS

=item * headers - Arrayref of allowed request headers. Default: Content-Type,Authorization,X-Requested-With

=item * expose - Arrayref of response headers to expose to client

=item * credentials - Boolean, allow credentials. Default: 0

=item * max_age - Preflight cache time in seconds. Default: 86400

=back

Returns $app for chaining.

=cut

sub use_cors ($self, %opts) {
    my $origins = $opts{origins} // ['*'];
    my $methods = $opts{methods} // [qw(GET POST PUT DELETE PATCH OPTIONS)];
    my $headers = $opts{headers} // [qw(Content-Type Authorization X-Requested-With)];
    my $expose = $opts{expose} // [];
    my $credentials = $opts{credentials} // 0;
    my $max_age = $opts{max_age} // 86400;

    # Store CORS config - this is checked in _handle_http for preflight
    $self->{_cors} = {
        origins     => { map { $_ => 1 } @$origins },
        has_wildcard => (grep { $_ eq '*' } @$origins) ? 1 : 0,
        methods     => $methods,
        headers     => $headers,
        expose      => $expose,
        credentials => $credentials,
        max_age     => $max_age,
    };

    # Before hook: add CORS headers for matched routes
    $self->hook(before => sub ($c) {
        my $method = $c->method;
        my $origin = $c->req->header('origin');

        return unless $origin;  # Not a CORS request

        my $cors = $self->{_cors};

        # Check if origin is allowed
        my $origin_allowed = $cors->{has_wildcard} || $cors->{origins}{$origin};
        return unless $origin_allowed;

        # Determine what to send as Allow-Origin
        my $allow_origin;
        if ($cors->{has_wildcard} && !$cors->{credentials}) {
            $allow_origin = '*';
        } else {
            $allow_origin = $origin;
        }

        # Handle preflight (for routes that explicitly match OPTIONS)
        if ($method eq 'OPTIONS') {
            $c->res_header('Access-Control-Allow-Origin', $allow_origin);
            $c->res_header('Access-Control-Allow-Methods', join(', ', @{$cors->{methods}}));
            $c->res_header('Access-Control-Allow-Headers', join(', ', @{$cors->{headers}}));
            $c->res_header('Access-Control-Max-Age', $cors->{max_age});
            $c->res_header('Vary', 'Origin');

            if ($cors->{credentials}) {
                $c->res_header('Access-Control-Allow-Credentials', 'true');
            }

            # Send 204 No Content for preflight
            $c->status(204)->send_response('');
            return;  # Stop processing
        }

        # For regular requests, add CORS headers
        $c->res_header('Access-Control-Allow-Origin', $allow_origin);
        $c->res_header('Vary', 'Origin');

        if ($cors->{credentials}) {
            $c->res_header('Access-Control-Allow-Credentials', 'true');
        }

        if (@{$cors->{expose}}) {
            $c->res_header('Access-Control-Expose-Headers', join(', ', @{$cors->{expose}}));
        }
    });

    return $self;
}

# Internal: Handle CORS preflight OPTIONS request
async sub _handle_cors_preflight ($self, $scope, $send, $origin) {
    my $cors = $self->{_cors};

    # Check if origin is allowed
    my $origin_allowed = $cors->{has_wildcard} || $cors->{origins}{$origin};
    return 0 unless $origin_allowed;

    # Determine what to send as Allow-Origin
    my $allow_origin;
    if ($cors->{has_wildcard} && !$cors->{credentials}) {
        $allow_origin = '*';
    } else {
        $allow_origin = $origin;
    }

    my @headers = (
        ['Access-Control-Allow-Origin', $allow_origin],
        ['Access-Control-Allow-Methods', join(', ', @{$cors->{methods}})],
        ['Access-Control-Allow-Headers', join(', ', @{$cors->{headers}})],
        ['Access-Control-Max-Age', $cors->{max_age}],
        ['Vary', 'Origin'],
    );

    if ($cors->{credentials}) {
        push @headers, ['Access-Control-Allow-Credentials', 'true'];
    }

    await $send->({
        type    => 'http.response.start',
        status  => 204,
        headers => \@headers,
    });

    await $send->({
        type => 'http.response.body',
        body => '',
        more => 0,
    });

    return 1;  # Handled
}

=head2 middleware

    $app->middleware(auth => sub ($c, $next) {
        return $c->status(401)->text("Unauthorized")
            unless $c->req->header('Authorization');
        $next->();  # Continue to route handler
    });

    $app->middleware(json_only => sub ($c, $next) {
        return $c->status(415)->json({ error => 'JSON required' })
            unless $c->req->content_type =~ /json/;
        $next->();
    });

Define a named middleware that can be applied to specific routes.
The callback receives the context C<$c> and a continuation function C<$next>.

Call C<< $next->() >> to continue to the next middleware or route handler.
If you don't call C<$next>, the chain stops (useful for auth failures, etc.).

Returns $app for chaining.

=cut

sub middleware ($self, $name, $callback) {
    $self->{middleware}{$name} = $callback;
    return $self;
}

=head2 get_middleware

    my $mw = $app->get_middleware('auth');

Returns the middleware callback for the given name, or undef if not found.

=cut

sub get_middleware ($self, $name) {
    return $self->{middleware}{$name};
}

=head2 has_middleware

    if ($app->has_middleware('auth')) { ... }

Returns true if a middleware with the given name is defined.

=cut

sub has_middleware ($self, $name) {
    return exists $self->{middleware}{$name};
}

=head1 ROUTING METHODS

=head2 get

    $app->get('/' => sub ($c) { $c->text("Hello") });
    $app->get('/protected' => [qw(auth)] => sub ($c) { ... });

Register a GET route. Optionally specify middleware as an arrayref
before the handler. Returns a RouteHandle for chaining C<< ->name() >>.

=cut

sub get ($self, $path, @args) {
    return $self->_add_route('GET', $path, @args);
}

=head2 post

    $app->post('/users' => sub ($c) { ... });
    $app->post('/api/users' => [qw(auth json_only)] => sub ($c) { ... });

Register a POST route. Returns a RouteHandle for chaining C<< ->name() >>.

=cut

sub post ($self, $path, @args) {
    return $self->_add_route('POST', $path, @args);
}

=head2 put

    $app->put('/users/:id' => sub ($c) { ... });
    $app->put('/users/:id' => [qw(auth)] => sub ($c) { ... });

Register a PUT route. Returns a RouteHandle for chaining C<< ->name() >>.

=cut

sub put ($self, $path, @args) {
    return $self->_add_route('PUT', $path, @args);
}

=head2 del

    $app->del('/users/:id' => sub ($c) { ... });
    $app->del('/users/:id' => [qw(auth admin)] => sub ($c) { ... });

Register a DELETE route. Named 'del' to avoid conflict with Perl's
built-in delete. Returns a RouteHandle for chaining C<< ->name() >>.

=cut

sub del ($self, $path, @args) {
    return $self->_add_route('DELETE', $path, @args);
}

=head2 patch

    $app->patch('/users/:id' => sub ($c) { ... });
    $app->patch('/users/:id' => [qw(auth)] => sub ($c) { ... });

Register a PATCH route. Returns a RouteHandle for chaining C<< ->name() >>.

=cut

sub patch ($self, $path, @args) {
    return $self->_add_route('PATCH', $path, @args);
}

=head2 delete

    $app->delete('/items/:id' => sub ($c) { ... });
    $app->delete('/items/:id' => [qw(auth)] => sub ($c) { ... });

Register a DELETE route. Returns a RouteHandle for chaining C<< ->name() >>.

=cut

sub delete ($self, $path, @args) {
    return $self->_add_route('DELETE', $path, @args);
}

=head2 any

    $app->any('/ping' => sub ($c) { $c->text("pong") });
    $app->any('/protected' => [qw(auth)] => sub ($c) { ... });

Register a route that matches any HTTP method.
Returns a RouteHandle for chaining C<< ->name() >>.

=cut

sub any ($self, $path, @args) {
    return $self->_add_route('*', $path, @args);
}

=head2 route

    $app->route('OPTIONS', '/resource' => sub ($c) { ... });
    $app->route('OPTIONS', '/resource' => [qw(cors)] => sub ($c) { ... });

Register a route with an explicit HTTP method.
Returns a RouteHandle for chaining C<< ->name() >>.

=cut

sub route ($self, $method, $path, @args) {
    return $self->_add_route($method, $path, @args);
}

=head2 websocket

    $app->websocket('/ws' => sub ($ws) {
        $ws->send("Welcome!");

        $ws->on(message => sub ($data) {
            $ws->send("Echo: $data");
        });

        $ws->on(close => sub {
            # Cleanup
        });
    });

    $app->websocket('/chat/:room' => sub ($ws) {
        my $room = $ws->param('room');
        # ...
    });

Register a WebSocket route. The callback receives a PAGI::Simple::WebSocket
context object instead of the regular HTTP context.

Returns $app for chaining.

=cut

sub websocket ($self, $path, $handler) {
    # Apply group prefix to path
    my $full_path = $self->{_prefix} . $path;

    $self->{ws_router}->add('GET', $full_path, $handler);
    return $self;
}

=head2 sse

    $app->sse('/events' => sub ($sse) {
        $sse->send_event(
            data  => { message => "Hello" },
            event => 'greeting',
            id    => 1,
        );

        $sse->on(close => sub {
            # Client disconnected
        });
    });

    $app->sse('/notifications/:user' => sub ($sse) {
        my $user = $sse->param('user');
        # ...
    });

Register a Server-Sent Events route. The callback receives a PAGI::Simple::SSE
context object instead of the regular HTTP context.

Returns $app for chaining.

=cut

sub sse ($self, $path, $handler) {
    # Apply group prefix to path
    my $full_path = $self->{_prefix} . $path;

    $self->{sse_router}->add('GET', $full_path, $handler);
    return $self;
}

=head2 static

    # Simple form: prefix => directory
    $app->static('/public' => './static');

    # With options
    $app->static('/assets' => {
        root         => './public',
        index        => ['index.html'],
        show_hidden  => 0,
    });

Mount a static file handler under the given URL prefix. Files are served
from the specified directory using PAGI::App::Directory.

Returns $app for chaining.

=cut

sub static ($self, $prefix, $target) {
    # Normalize prefix - ensure it starts with / and doesn't end with /
    $prefix =~ s{/+$}{};
    $prefix = "/$prefix" unless $prefix =~ m{^/};

    my %opts;
    if (ref($target) eq 'HASH') {
        %opts = %$target;
    }
    else {
        # Simple form: target is the root directory
        $opts{root} = $target;
    }

    # Create the PAGI::App::Directory instance
    my $dir_app = PAGI::App::Directory->new(%opts)->to_app;

    # Store the handler with its prefix
    push @{$self->{_static_handlers}}, {
        prefix => $prefix,
        app    => $dir_app,
    };

    return $self;
}

=head2 group

    $app->group('/api' => sub ($app) {
        $app->get('/users' => sub ($c) { ... });   # /api/users
        $app->get('/posts' => sub ($c) { ... });   # /api/posts
    });

    $app->group('/admin' => [qw(auth admin_only)] => sub ($app) {
        $app->get('/dashboard' => sub ($c) { ... });  # /admin/dashboard with auth, admin_only
        $app->get('/settings' => sub ($c) { ... });   # /admin/settings with auth, admin_only
    });

Group routes under a common path prefix with optional shared middleware.
Routes defined inside the callback will have the prefix prepended and
any group middleware applied before route-specific middleware.

Groups can be nested:

    $app->group('/api' => [qw(auth)] => sub ($app) {
        $app->group('/v1' => sub ($app) {
            $app->get('/users' => sub ($c) { ... });  # /api/v1/users with auth
        });
    });

Returns $app for chaining.

=cut

sub group ($self, $prefix, @args) {
    my ($group_middleware, $callback);

    if (@args == 1) {
        # No middleware: ($callback)
        $callback = $args[0];
        $group_middleware = [];
    }
    elsif (@args == 2 && ref($args[0]) eq 'ARRAY') {
        # With middleware: ($middleware_arrayref, $callback)
        $group_middleware = $args[0];
        $callback = $args[1];
    }
    else {
        die 'Invalid group arguments: expected ($callback) or (\@middleware, $callback)';
    }

    # Save current context
    my $saved_prefix = $self->{_prefix};
    my $saved_middleware = $self->{_group_middleware};

    # Update context for this group
    $self->{_prefix} = $saved_prefix . $prefix;
    $self->{_group_middleware} = [@$saved_middleware, @$group_middleware];

    # Call the callback
    $callback->($self);

    # Restore context
    $self->{_prefix} = $saved_prefix;
    $self->{_group_middleware} = $saved_middleware;

    return $self;
}

=head2 mount

    # Mount a PAGI::Simple sub-application under a prefix
    my $api_v1 = PAGI::Simple->new(name => 'API v1');
    $api_v1->get('/users' => sub ($c) { ... });

    my $app = PAGI::Simple->new;
    $app->mount('/api/v1' => $api_v1);  # /api/v1/users

    # Mount with middleware
    $app->mount('/admin' => $admin_app, [qw(auth admin_only)]);

    # Mount a raw PAGI application (coderef)
    $app->mount('/legacy' => $legacy_pagi_app);

Mount a sub-application under a path prefix. The mounted app receives
requests with the prefix stripped from the path. All HTTP methods,
WebSocket connections, and SSE streams are properly routed.

Options:

=over 4

=item * C<$prefix> - The path prefix to mount under (e.g., '/api/v1')

=item * C<$sub_app> - A PAGI::Simple instance or PAGI app coderef

=item * C<@middleware> - Optional arrayref of middleware names to apply

=back

The mounted app has access to C<< $c->mount_path >> (the mount prefix)
and C<< $c->local_path >> (the path without the prefix).

Returns C<$app> for chaining.

=cut

sub mount ($self, $prefix, $sub_app, @args) {
    my $middleware = [];

    # Check if middleware was passed
    if (@args == 1 && ref($args[0]) eq 'ARRAY') {
        $middleware = $args[0];
    }
    elsif (@args) {
        die 'Invalid mount arguments: expected (prefix, app) or (prefix, app, \@middleware)';
    }

    # Normalize prefix - ensure it starts with / and doesn't end with /
    $prefix =~ s{/$}{};  # Remove trailing slash
    $prefix = "/$prefix" unless $prefix =~ m{^/};

    # Get the PAGI app from the sub-application
    my $app;
    if (blessed($sub_app) && $sub_app->can('to_app')) {
        # It's a PAGI::Simple (or similar) - get its to_app
        $app = $sub_app;
    }
    elsif (ref($sub_app) eq 'CODE') {
        # It's already a raw PAGI app (coderef)
        $app = $sub_app;
    }
    else {
        die 'mount() requires a PAGI::Simple app or a PAGI app coderef';
    }

    # Store the mounted app
    push @{$self->{_mounted_apps}}, {
        prefix     => $prefix,
        app        => $app,
        middleware => $middleware,
    };

    return $self;
}

# Internal: Check if a path matches any mounted app and dispatch to it
# Returns 1 if dispatched, 0 if no mount matched
#
# TODO: Consider adding 404 pass-through option. Currently, if a mounted app
# returns 404, the parent app's routes are NOT tried. A future enhancement
# could add a pass_through option: $app->mount('/api' => $sub_app, { pass_through => 1 })
# This would let parent routes handle 404s from mounted apps. Use case: fallback
# routes or catch-all handlers in the parent app.
#
# TODO: Consider sharing services/stash between parent and mounted apps via $scope.
# Currently, mounted apps are isolated. To enable sharing, we could add parent
# app's service_registry and stash to $scope (e.g., $scope->{pagi.services},
# $scope->{pagi.stash}). Mounted apps could then access parent services or share
# request-scoped data. This follows the PSGI convention of using the scope hash
# for framework-specific data.
async sub _dispatch_to_mounted ($self, $scope, $receive, $send) {
    my $path = $scope->{path} // '/';
    my $type = $scope->{type} // '';

    for my $mount (@{$self->{_mounted_apps}}) {
        my $prefix = $mount->{prefix};

        # Check if path matches this mount
        # Path must equal prefix exactly or start with prefix followed by /
        if ($path eq $prefix || $path =~ m{^\Q$prefix\E/}) {
            # Strip the prefix from the path
            my $local_path = $path;
            $local_path =~ s{^\Q$prefix\E}{};
            $local_path = '/' unless length($local_path);

            # Create a modified scope with the adjusted path
            my $sub_scope = {
                %$scope,
                path        => $local_path,
                _mount_path => $prefix,           # Store mount path for context
                _full_path  => $path,             # Store original full path
            };

            # Get the actual PAGI app
            my $app = $mount->{app};
            if (blessed($app) && $app->can('to_app')) {
                $app = $app->to_app;
            }

            # If there's middleware, we need to create a context and run the chain
            if (@{$mount->{middleware}} && $type eq 'http') {
                # Create a wrapper that runs middleware then calls mounted app
                await $self->_dispatch_mounted_with_middleware(
                    $sub_scope, $receive, $send,
                    $app, $mount->{middleware}
                );
            }
            else {
                # No middleware - call mounted app directly
                await $app->($sub_scope, $receive, $send);
            }

            return 1;  # Dispatched to mount
        }
    }

    return 0;  # No mount matched
}

# Internal: Dispatch to mounted app with middleware chain
async sub _dispatch_mounted_with_middleware ($self, $scope, $receive, $send, $app, $middleware_names) {
    # Create a context for running middleware
    my $c = PAGI::Simple::Context->new(
        app     => $self,
        scope   => $scope,
        receive => $receive,
        send    => $send,
    );

    # Build middleware chain with mounted app as the final handler
    my $final_handler = async sub {
        await $app->($scope, $receive, $send);
    };

    my $chain = $final_handler;

    # Wrap each middleware around the chain, in reverse order
    for my $name (reverse @$middleware_names) {
        my $mw = $self->get_middleware($name);
        unless ($mw) {
            die "Unknown middleware: $name";
        }

        my $next = $chain;
        $chain = async sub {
            my $result = $mw->($c, $next);
            if (blessed($result) && $result->can('get')) {
                await $result;
            }
        };
    }

    # Execute the chain
    await $chain->();
}

# Internal: Add a route with optional middleware and name
# Args can be: ($handler) or ($middleware_arrayref, $handler)
# Applies current group prefix and middleware
# Returns a RouteHandle for chained naming
sub _add_route ($self, $method, $path, @args) {
    my ($route_middleware, $handler, $name);

    if (@args == 1) {
        # No middleware: ($handler)
        $handler = $args[0];
        $route_middleware = [];
    }
    elsif (@args == 2 && ref($args[0]) eq 'ARRAY') {
        # With middleware: ($middleware_arrayref, $handler)
        $route_middleware = $args[0];
        $handler = $args[1];
    }
    else {
        die 'Invalid route arguments: expected ($handler) or (\@middleware, $handler)';
    }

    # Apply group prefix to path
    my $full_path = $self->{_prefix} . $path;

    # Combine group middleware + route middleware
    my @combined_middleware = (@{$self->{_group_middleware}}, @$route_middleware);

    my $route = $self->{router}->add($method, $full_path, $handler, middleware => \@combined_middleware);

    # Return a handle that allows chaining ->name() but still returns to $app
    return PAGI::Simple::RouteHandle->new($self, $route);
}

=head2 url_for

    my $url = $app->url_for('user_show', id => 42);
    my $url = $app->url_for('search', query => { q => 'perl', page => 1 });

Generate a URL for a named route with the given parameters.

Path parameters (like C<:id>) are substituted into the route pattern.
Extra parameters or a C<query> hashref are appended as query string.

Returns undef if the route is not found or required parameters are missing.

=cut

sub url_for ($self, $name, %params) {
    return $self->{router}->url_for($name, %params);
}

=head2 named_routes

    my @names = $app->named_routes;

Returns a list of all registered route names.

=cut

sub named_routes ($self) {
    return $self->{router}->named_routes;
}

#---------------------------------------------------------------------------
# PAGI::Simple::RouteHandle - Enables chained route naming
#---------------------------------------------------------------------------
package PAGI::Simple::RouteHandle;

use strict;
use warnings;
use experimental 'signatures';

sub new ($class, $app, $route) {
    return bless { app => $app, route => $route }, $class;
}

=head2 name

    $app->get('/users/:id' => sub {...})->name('user_show');

Assign a name to the route for URL generation.

=cut

sub name ($self, $name) {
    $self->{route}{name} = $name;
    $self->{app}{router}->register_name($name, $self->{route});
    return $self->{app};  # Return app for continued chaining
}

# Allow continued route registration by delegating to app
sub get ($self, @args) { return $self->{app}->get(@args); }
sub post ($self, @args) { return $self->{app}->post(@args); }
sub put ($self, @args) { return $self->{app}->put(@args); }
sub patch ($self, @args) { return $self->{app}->patch(@args); }
sub delete ($self, @args) { return $self->{app}->delete(@args); }
sub any ($self, @args) { return $self->{app}->any(@args); }

package PAGI::Simple;

=head1 UTF-8 HANDLING

=over 4

=item * Input parameters (path, query, form) are decoded as UTF-8 with U+FFFD
replacement. Use C<< strict => 1 >> on C<req->query>, C<req->body_param>, or
C<req->header_utf8> to croak on invalid bytes, and C<raw_query_param> /
C<raw_body_param> for byte access.

=item * Headers are raw by default; C<header_utf8> provides decoding with the
same replacement/strict options.

=item * Responses: C<text>, C<html>, C<json>, and C<send_utf8> encode bodies to
UTF-8 (or the charset already present on Content-Type), ensure a charset is
set, and set C<Content-Length> from the encoded byte size. Use
C<send_response> for raw/byte-oriented replies.

=back

=head1 SEE ALSO

L<PAGI>, L<PAGI::Server>, L<PAGI::Simple::Context>

=head1 AUTHOR

PAGI Contributors

=cut

1;
