package PAGI::Simple::Context;

use strict;
use warnings;
use experimental 'signatures';

our $VERSION = '0.01';

use Future::AsyncAwait;
use Hash::MultiValue;
use Scalar::Util qw(blessed);
use Encode qw(encode decode FB_CROAK LEAVE_SRC);
use Carp qw(croak);
use PAGI::Simple::Request;
use PAGI::Simple::Response;
use PAGI::Simple::CookieUtil;
use PAGI::Simple::StructuredParams;
use PAGI::Simple::Negotiate;
use PAGI::Simple::StreamWriter;
use PAGI::Util::AsyncFile;
use File::Basename ();
use File::Spec;

=head1 NAME

PAGI::Simple::Context - Request context for PAGI::Simple handlers

=head1 SYNOPSIS

    # In a route handler:
    $app->get('/users/:id' => sub ($c) {
        my $id = $c->param('id');

        # Access raw PAGI primitives
        my $scope = $c->scope;
        my $method = $scope->{method};

        # Per-request storage
        $c->stash->{user} = load_user($id);

        $c->json({ user_id => $id });
    });

=head1 DESCRIPTION

PAGI::Simple::Context is the request context object passed to route handlers.
It provides convenient access to request data, response helpers, and per-request
storage while still allowing access to raw PAGI primitives when needed.

=head1 METHODS

=cut

=head2 new

    my $c = PAGI::Simple::Context->new(
        app     => $app,
        scope   => $scope,
        receive => $receive,
        send    => $send,
    );

Create a new context. This is called internally by PAGI::Simple when
dispatching to route handlers.

=cut

sub new ($class, %args) {
    my $self = bless {
        app     => $args{app},
        scope   => $args{scope},
        receive => $args{receive},
        send    => $args{send},
        stash   => {},
        _response_started => 0,
        _req     => undef,  # Lazy-built Request object
        _status  => 200,    # Response status code
        _headers => [],     # Response headers (array of pairs)
        _path_params => $args{path_params} // {},
        _response_size => 0,    # Track response body size
        _request_start => undef, # For timing (set by logging)
    }, $class;

    return $self;
}

=head2 app

    my $app = $c->app;

Returns the PAGI::Simple application instance. Useful for accessing
application-level stash or configuration.

=cut

sub app ($self) {
    return $self->{app};
}

=head2 scope

    my $scope = $c->scope;

Returns the raw PAGI scope hashref. Contains connection metadata like
method, path, headers, query_string, etc.

=cut

sub scope ($self) {
    return $self->{scope};
}

=head2 receive

    my $receive = $c->receive;
    my $event = await $receive->();

Returns the raw PAGI receive coderef. Call it to receive events
from the client (request body chunks, WebSocket messages, etc.).

=cut

sub receive ($self) {
    return $self->{receive};
}

=head2 body_stream

    my $stream = $c->body_stream(%opts);

Shortcut to C<< $c->req->body_stream >> for streaming request bodies. Accepts
the same options: C<max_bytes> (defaults to Content-Length), C<decode>
(e.g., C<'UTF-8'>), C<strict> for decode errors, and optional C<loop> for
file piping helpers. Buffered helpers (body/body_params/json_body/uploads)
are unavailable once streaming starts.

=cut

=head2 send

    my $send = $c->send;
    await $send->({ type => 'http.response.start', status => 200, ... });

Returns the raw PAGI send coderef. Use for low-level response control.

=cut

sub send ($self) {
    return $self->{send};
}

=head2 mount_path

    my $prefix = $c->mount_path;  # e.g., '/api/v1'

Returns the mount path prefix if this request was dispatched through a
mounted sub-application. Returns an empty string if not mounted.

This is useful for generating absolute URLs that include the mount prefix.

=cut

sub mount_path ($self) {
    return $self->{scope}{_mount_path} // '';
}

=head2 local_path

    my $path = $c->local_path;  # e.g., '/users/123'

Returns the request path relative to the mount point. If the app is mounted
at C</api/v1> and the full request path is C</api/v1/users/123>, this
returns C</users/123>.

If not mounted, this is the same as C<< $c->req->path >>.

=cut

sub local_path ($self) {
    # If we have a mount path, the scope's path is already the local path
    # (it was rewritten during dispatch)
    return $self->{scope}{path} // '/';
}

=head2 full_path

    my $path = $c->full_path;  # e.g., '/api/v1/users/123'

Returns the full original request path, including any mount prefix.
This is useful when you need the complete path as the client requested it.

=cut

sub full_path ($self) {
    return $self->{scope}{_full_path} // $self->{scope}{path} // '/';
}

=head2 loop

    my $loop = $c->loop;

Returns the IO::Async::Loop instance for this request. This is a shortcut
for accessing C<< $c->app->loop >> or C<< $scope->{pagi}{loop} >>.

Useful for async file operations or setting up timers:

    $app->get('/download/:file' => async sub ($c) {
        my $file = $c->param('file');
        my $loop = $c->loop;

        if ($loop) {
            my $content = await PAGI::Util::AsyncFile->read_file($loop, "/files/$file");
            $c->text($content);
        }
    });

=cut

sub loop ($self) {
    return $self->{scope}{pagi}{loop} // ($self->{app} ? $self->{app}->loop : undef);
}

=head2 log

    $c->log->info("Processing request");
    $c->log->debug("User ID: $id");
    $c->log->warn("Rate limit approaching");
    $c->log->error("Database connection failed");

Returns a logger instance for this request. Log messages are written to
STDERR with a consistent format including timestamp, level, and request path.

The logger is request-aware and includes context like the request path
in each message. Available log levels: debug, info, warn, error.

=cut

sub log ($self) {
    $self->{_logger} //= PAGI::Simple::Context::Logger->new(context => $self);
    return $self->{_logger};
}

=head2 stash

    $c->stash->{user} = $user;
    my $user = $c->stash->{user};

Returns a per-request storage hashref. Data stored here is isolated
to this request and will not leak to other requests.

=cut

sub stash ($self) {
    return $self->{stash};
}

=head2 _register_service_for_cleanup

    $c->_register_service_for_cleanup($service);

Internal method called by PerRequest services to register for cleanup.
At the end of the request, C<on_request_end> is called on all registered
services.

=cut

sub _register_service_for_cleanup ($self, $service) {
    push @{$self->{_cleanup_services}}, $service;
}

=head2 _call_service_cleanups

    $c->_call_service_cleanups();

Internal method called at request end to invoke C<on_request_end> on
all registered services. Called automatically by the framework.

=cut

sub _call_service_cleanups ($self) {
    my $services = $self->{_cleanup_services} // [];
    for my $service (@$services) {
        eval { $service->on_request_end($self) };
        if ($@) {
            warn "[PAGI::Simple] Service cleanup error: $@\n";
        }
    }
}

=head2 service

    my $poll = $c->service('Poll');
    my $poll = $c->service('Poll', active => 1);  # With runtime args

Get a service instance from the service registry. Services are initialized
at application startup via C<init_service> and available via this method.

    # With namespace => 'MyApp' (or app name 'My App')
    $c->service('Poll')       # Returns Poll service
    $c->service('User')       # Returns User service

Service scopes determine instantiation behavior:

=over 4

=item * L<PAGI::Simple::Service::Factory> - New instance every call

=item * L<PAGI::Simple::Service::PerRequest> - Cached per request

=item * L<PAGI::Simple::Service::PerApp> - Singleton at app level

=back

For Factory and PerRequest services, any C<%args> passed are given to the
factory coderef. For PerApp services (which are singletons), args are ignored.

B<Note:> Services must be registered before app startup, either via auto-discovery
(classes in C<${namespace}::Service::>) or via C<< $app->add_service() >>.

=cut

sub service ($self, $name, %args) {
    my $app = $self->{app};
    my $registry = $app->service_registry;

    # Look up in registry
    my $entry = $registry->{$name};
    croak("Unknown service '$name' - not found in service registry") unless defined $entry;

    # If it's a coderef (Factory or PerRequest), call it
    if (ref($entry) eq 'CODE') {
        return $entry->($self, \%args);
    }

    # Otherwise it's a PerApp singleton instance
    return $entry;
}

=head2 run_blocking

    my $result = await $c->run_blocking(sub {
        # Blocking code here (no arguments)
        return $computed_value;
    });

    # With arguments (recommended for passing request data)
    my $result = await $c->run_blocking(sub {
        my ($id, $query) = @_;  # Use @_, not signatures
        my $dbh = DBI->connect(...);
        return $dbh->selectrow_hashref(
            "SELECT * FROM users WHERE id = ? AND name LIKE ?",
            {}, $id, "%$query%"
        );
    }, $id, $query);

Execute blocking code in a worker process without blocking the event loop.
Returns a Future that resolves with the return value of the code block.

B<Arguments>: You can pass arguments after the code block. These are serialized
and passed to the code block via C<@_>. This is the recommended way to pass
request data to workers:

    my $user_id = $c->path_params->{id};
    my $filters = { status => 'active', limit => 10 };

    my $result = await $c->run_blocking(sub {
        my ($id, $opts) = @_;
        my $dbh = DBI->connect($ENV{DB_DSN});
        return $dbh->selectall_arrayref(
            "SELECT * FROM orders WHERE user_id = ? AND status = ? LIMIT ?",
            { Slice => {} },
            $id, $opts->{status}, $opts->{limit}
        );
    }, $user_id, $filters);

B<Note>: Due to a B::Deparse limitation, subroutine signatures (C<sub ($a, $b)>)
do not work correctly. Use traditional C<my (...) = @_> argument handling.

B<IMPORTANT>: The code block runs in a separate process. It cannot access:

=over 4

=item * Lexical variables from the enclosing scope (pass them as arguments)

=item * The event loop or async features

=item * Open filehandles or database connections (create them inside the block)

=back

Arguments must be serializable (scalars, arrays, hashes). Complex objects,
coderefs, and filehandles cannot be passed.

Requires C<workers> configuration in PAGI::Simple->new():

    my $app = PAGI::Simple->new(
        workers => { max_workers => 4 },
    );

Throws an exception if workers are not configured.

=cut

sub run_blocking ($self, $code, @args) {
    my $app = $self->{app};
    my $pool = $app->worker_pool;

    unless ($pool) {
        croak "run_blocking() requires worker configuration. " .
              "Add 'workers => { max_workers => N }' to PAGI::Simple->new()";
    }

    # Serialize the coderef using B::Deparse since IO::Async::Channel
    # uses Sereal which doesn't support coderefs
    my $code_string = $app->_serialize_code_for_worker($code);

    # Pass arguments as an arrayref - these are serialized by Sereal
    return $pool->call(args => [$code_string, \@args]);
}

=head2 param

    my $id = await $c->param('id');

Returns a parameter value by searching in order: path params, query params,
then body params. Returns the first value found.

This is an async method because body params may need to be read.

Values are decoded as UTF-8 with replacement characters. Use the request's
raw/strict accessors (e.g., C<raw_query_param>, C<body_param(strict =E<gt> 1)>)
if you need byte-level access or strict decoding.

For path-only params (sync), use C<< $c->path_params->{name} >>.

=cut

async sub param ($self, $name) {
    # Check path params first (highest priority)
    if (exists $self->{_path_params}{$name}) {
        return $self->{_path_params}{$name};
    }

    # Check query params
    my $query_val = $self->req->query_param($name);
    if (defined $query_val) {
        return $query_val;
    }

    # Check body params (async)
    my $body_val = await $self->req->body_param($name);
    return $body_val;
}

=head2 path_params

    my $params = $c->path_params;

Returns a hashref of all captured path parameters.

=cut

sub path_params ($self) {
    return $self->{_path_params};
}

=head2 params

    my $all = await $c->params;  # Hash::MultiValue

Returns all parameters merged from path, query, and body as a Hash::MultiValue.
Path params take precedence over query, which takes precedence over body.

This is an async method because body params may need to be read.
Values are decoded as UTF-8 with replacement characters. For raw or strict
decoding, access the request helpers directly (C<raw_query>, C<raw_body_params>,
or pass C<strict =E<gt> 1>).

=cut

async sub params ($self) {
    # Get body params first (async)
    my $body = await $self->req->body_params;

    # Start with body params
    my @pairs = $body->flatten;

    # Add query params (overrides body)
    my $query = $self->req->query;
    push @pairs, $query->flatten;

    # Add path params (highest priority)
    for my $key (keys %{$self->{_path_params}}) {
        push @pairs, $key, $self->{_path_params}{$key};
    }

    return Hash::MultiValue->new(@pairs);
}

=head2 structured_body

    my $sp = await $c->structured_body;
    my $data = $sp->namespace('order')->permitted('name', 'email')->to_hash;

Returns a L<PAGI::Simple::StructuredParams> object for the request body.
This is an async method because it needs to read the body.

The StructuredParams object provides Rails-style strong parameters:

    my $data = (await $c->structured_body)
        ->namespace('my_app_model_order')
        ->permitted('customer_name', 'email', +{line_items => ['product', 'quantity']})
        ->skip('_destroy')
        ->to_hash;

=cut

async sub structured_body ($self) {
    my $body = await $self->req->body_params;
    return PAGI::Simple::StructuredParams->new(
        source_type => 'body',
        multi_value => $body,
        context     => $self,
    );
}

=head2 structured_query

    my $sp = $c->structured_query;
    my $data = $sp->permitted('page', 'per_page')->to_hash;

Returns a L<PAGI::Simple::StructuredParams> object for query string parameters.
This is a synchronous method (query params are available immediately).

=cut

sub structured_query ($self) {
    return PAGI::Simple::StructuredParams->new(
        source_type => 'query',
        multi_value => $self->req->query,
        context     => $self,
    );
}

=head2 structured_data

    my $sp = await $c->structured_data;
    my $data = $sp->namespace('form')->permitted('name')->to_hash;

Returns a L<PAGI::Simple::StructuredParams> object for merged body + query params.
Body parameters take precedence over query parameters.
This is an async method because it needs to read the body.

=cut

async sub structured_data ($self) {
    my $body = await $self->req->body_params;
    my $query = $self->req->query;

    # Merge: query first, then body (body takes precedence)
    my @pairs = ($query->flatten, $body->flatten);
    my $merged = Hash::MultiValue->new(@pairs);

    return PAGI::Simple::StructuredParams->new(
        source_type => 'data',
        multi_value => $merged,
        context     => $self,
    );
}

=head2 req

    my $req = $c->req;

Returns a L<PAGI::Simple::Request> object wrapping the current scope.
The Request object is created lazily and cached.

=cut

sub req ($self) {
    unless ($self->{_req}) {
        $self->{_req} = PAGI::Simple::Request->new(
            $self->{scope},
            $self->{receive},
            $self->{_path_params},
        );
    }
    return $self->{_req};
}

=head2 body_stream

    my $stream = $c->body_stream(%opts);

Shortcut to C<< $c->req->body_stream >> (see that method for options and
mutual exclusion rules). Handy for streaming uploads (C<stream_to_file>) or
UTF-8 decoding without buffering.

=cut

sub body_stream ($self, %opts) {
    return $self->req->body_stream(%opts);
}

=head2 response_started

    if ($c->response_started) { ... }

Returns true if the response has already been started (http.response.start
has been sent). Useful for middleware and error handlers.

=cut

sub response_started ($self) {
    return $self->{_response_started};
}

=head2 mark_response_started

    $c->mark_response_started;

Internal method to mark that the response has started. Called by
response helpers.

=cut

sub mark_response_started ($self) {
    $self->{_response_started} = 1;
    return $self;
}

=head1 CONVENIENCE ACCESSORS

These methods provide quick access to common scope values.

=cut

=head2 method

    my $method = $c->method;  # GET, POST, etc.

Returns the HTTP method.

=cut

sub method ($self) {
    return $self->{scope}{method};
}

=head2 path

    my $path = $c->path;  # /users/123

Returns the request path (without query string).

=cut

sub path ($self) {
    return $self->{scope}{path};
}

=head2 query_string

    my $qs = $c->query_string;  # foo=bar&baz=qux

Returns the raw query string (without the leading ?).

=cut

sub query_string ($self) {
    return $self->{scope}{query_string} // '';
}

=head1 RESPONSE BUILDER METHODS

These methods configure the response and return $c for chaining.

=cut

=head2 status

    $c->status(201)->json({ id => 1 });

Set the HTTP response status code. Returns $c for chaining.

=cut

sub status ($self, $code) {
    $self->{_status} = $code;
    return $self;
}

=head2 res_header

    $c->res_header('X-Custom' => 'value');
    $c->res_header('Set-Cookie' => 'session=abc');

Add a response header. Can be called multiple times for the same
header name. Returns $c for chaining.

=cut

sub res_header ($self, $name, $value) {
    push @{$self->{_headers}}, [$name, $value];
    return $self;
}

=head2 content_type

    $c->content_type('application/xml');

Set the Content-Type response header. Returns $c for chaining.

=cut

sub content_type ($self, $type) {
    return $self->res_header('content-type', $type);
}

=head2 cookie

    # Set a simple cookie
    $c->cookie('theme' => 'dark');

    # Set a cookie with options
    $c->cookie('session_id' => $id,
        expires  => time() + 3600,  # 1 hour from now
        path     => '/',
        secure   => 1,
        httponly => 1,
        samesite => 'Lax',
    );

Set a response cookie. Returns $c for chaining.

Supported options:

=over 4

=item * expires - Expiration time as epoch timestamp

=item * max_age - Cookie lifetime in seconds

=item * domain - Cookie domain

=item * path - Cookie path (default: '/')

=item * secure - Only send over HTTPS

=item * httponly - Not accessible via JavaScript

=item * samesite - 'Strict', 'Lax', or 'None' (Note: 'None' requires secure)

=back

=cut

sub cookie ($self, $name, $value, %opts) {
    my $cookie_str = PAGI::Simple::CookieUtil::format_set_cookie($name, $value, %opts);
    return $self->res_header('Set-Cookie', $cookie_str);
}

=head2 remove_cookie

    $c->remove_cookie('session_id');
    $c->remove_cookie('session_id', path => '/', domain => '.example.com');

Remove a cookie by setting it with an expired date.
Returns $c for chaining.

You should specify the same path and domain that were used when setting
the cookie, otherwise the browser may not remove it.

=cut

sub remove_cookie ($self, $name, %opts) {
    my $cookie_str = PAGI::Simple::CookieUtil::format_removal_cookie($name, %opts);
    return $self->res_header('Set-Cookie', $cookie_str);
}

=head2 cors

    # Allow all origins
    $c->cors;
    $c->cors(origin => '*');

    # Allow specific origin
    $c->cors(origin => 'https://example.com');

    # Full configuration
    $c->cors(
        origin      => 'https://example.com',
        methods     => [qw(GET POST PUT DELETE)],
        headers     => [qw(Content-Type Authorization)],
        expose      => [qw(X-Custom-Header)],
        credentials => 1,
        max_age     => 86400,
    );

Add CORS headers to the response. Returns $c for chaining.

This is useful for simple CORS setups where you control the response
directly. For automatic CORS handling, see C<< $app->use_cors() >>.

Options:

=over 4

=item * origin - Allowed origin ('*' or specific origin). Default: '*'

=item * methods - Arrayref of allowed methods. Default: GET,POST,PUT,DELETE,PATCH

=item * headers - Arrayref of allowed request headers. Default: Content-Type,Authorization

=item * expose - Arrayref of response headers to expose to client

=item * credentials - Boolean, allow credentials. Default: 0

=item * max_age - Preflight cache time in seconds. Default: 86400

=back

Note: When credentials is true and origin is '*', the actual request
origin will be echoed back instead of '*' (per CORS spec).

=cut

sub cors ($self, %opts) {
    my $origin = $opts{origin} // '*';
    my $credentials = $opts{credentials} // 0;
    my $methods = $opts{methods} // [qw(GET POST PUT DELETE PATCH)];
    my $headers = $opts{headers} // [qw(Content-Type Authorization)];
    my $expose = $opts{expose} // [];
    my $max_age = $opts{max_age} // 86400;

    # Determine what origin to send back
    my $allow_origin;
    if ($origin eq '*' && $credentials) {
        # With credentials, can't use wildcard - echo the request origin
        my $req_origin = $self->req->header('origin');
        $allow_origin = $req_origin // '*';
    } else {
        $allow_origin = $origin;
    }

    $self->res_header('Access-Control-Allow-Origin', $allow_origin);
    $self->res_header('Vary', 'Origin');

    if ($credentials) {
        $self->res_header('Access-Control-Allow-Credentials', 'true');
    }

    if (@$expose) {
        $self->res_header('Access-Control-Expose-Headers', join(', ', @$expose));
    }

    # Preflight headers (useful when manually handling OPTIONS)
    if ($self->method eq 'OPTIONS') {
        $self->res_header('Access-Control-Allow-Methods', join(', ', @$methods));
        $self->res_header('Access-Control-Allow-Headers', join(', ', @$headers));
        $self->res_header('Access-Control-Max-Age', $max_age);
    }

    return $self;
}

=head2 respond_to

    $c->respond_to(
        json => sub { $c->json({ data => 'value' }) },
        html => sub { $c->html('<h1>Hello</h1>') },
        xml  => sub { $c->content_type('application/xml')->text('<data>value</data>') },
        any  => sub { $c->text('Fallback') },
    );

    # Or with hash references for simple cases:
    $c->respond_to(
        json => { json => { status => 'ok' } },
        html => { html => '<h1>OK</h1>' },
        any  => { text => 'OK', status => 200 },
    );

Automatically select the best response format based on the client's Accept
header and execute the appropriate handler.

The format is determined by:
1. The Accept header
2. Matching against the provided format handlers

If no acceptable format is found and no C<any> handler is provided, a 406
Not Acceptable response is sent.

Supported format shortcuts: html, json, xml, text, etc.

=cut

sub respond_to ($self, %handlers) {
    # Get list of supported formats (excluding 'any')
    my @formats = grep { $_ ne 'any' } keys %handlers;

    # Find best matching format
    my $format = $self->req->preferred_type(@formats);

    # Use 'any' fallback if no match
    $format //= 'any' if exists $handlers{any};

    unless ($format) {
        # No acceptable format - send 406
        $self->status(406)->text('Not Acceptable');
        return;
    }

    my $handler = $handlers{$format};

    if (ref($handler) eq 'CODE') {
        # Execute callback
        $handler->();
    }
    elsif (ref($handler) eq 'HASH') {
        # Hash with response options
        my %opts = %$handler;

        $self->status($opts{status}) if defined $opts{status};

        if (defined $opts{json}) {
            $self->json($opts{json});
        }
        elsif (defined $opts{html}) {
            $self->html($opts{html});
        }
        elsif (defined $opts{text}) {
            $self->text($opts{text});
        }
        elsif (defined $opts{data}) {
            $self->send_response($opts{data});
        }
    }
}

=head2 url_for

    my $url = $c->url_for('user_show', id => 42);
    my $url = $c->url_for('search', query => { q => 'perl' });

Generate a URL for a named route with the given parameters.

This is a convenience wrapper around C<< $c->app->url_for() >>.

=cut

sub url_for ($self, $name, %params) {
    return $self->{app}->url_for($name, %params);
}

=head2 redirect_to

    await $c->redirect_to('user_show', id => 42);
    await $c->redirect_to('home');
    await $c->redirect_to('search', query => { q => 'perl' }, status => 301);

Redirect to a named route. This combines url_for with redirect.

Options:

=over 4

=item * status - HTTP status code (default: 302)

=item * All other parameters are passed to url_for

=back

=cut

async sub redirect_to ($self, $name, %params) {
    my $status = delete $params{status} // 302;
    my $url = $self->url_for($name, %params);

    unless (defined $url) {
        die "Cannot redirect: unknown route '$name' or missing required parameters";
    }

    await $self->redirect($url, $status);
}

=head1 RESPONSE TERMINAL METHODS

These methods send the response. They are async and should be awaited.

=cut

=head2 text

    await $c->text("Hello, World!");
    await $c->text("Created", 201);

Send a plain text response. Optionally specify status code.

=cut

async sub text ($self, $body, $status = undef) {
    $self->{_status} = $status if defined $status;
    $self->content_type('text/plain; charset=utf-8');
    await $self->send_utf8($body);
}

=head2 html

    await $c->html("<h1>Hello</h1>");
    await $c->html($content, 201);

Send an HTML response. Optionally specify status code.

=cut

async sub html ($self, $body, $status = undef) {
    $self->{_status} = $status if defined $status;
    $self->content_type('text/html; charset=utf-8');
    await $self->send_utf8($body);
}

=head2 json

    await $c->json({ message => "Hello" });
    await $c->json({ created => 1 }, 201);

Send a JSON response. Optionally specify status code.

=cut

async sub json ($self, $data, $status = undef) {
    $self->{_status} = $status if defined $status;
    $self->content_type('application/json; charset=utf-8');
    my $body = PAGI::Simple::Response->json_encode($data);
    await $self->send_utf8($body);
}

=head2 render

    await $c->render('template_name', key => $value, ...);
    await $c->render('todos/index', todos => \@todos);

Render a template using the application's view layer (configured via $app->views()).
Variables passed are available in the template via the C<$v> object.

Output is automatically UTF-8 encoded and sent with
C<Content-Type: text/html; charset=utf-8>.

=head3 Auto-Fragment Detection

By default, htmx requests (HX-Request header present) automatically skip the
layout and return just the template content. Browser requests render with
the full layout.

=head3 Layout Control

You can override the auto-detection with the C<layout> option:

    # Force layout ON (for htmx requests that need full page, e.g., hx-boost)
    await $c->render('page', layout => 1, %vars);

    # Force layout OFF (for browser requests, e.g., printable view)
    await $c->render('page', layout => 0, %vars);

    # Auto-detect (default)
    await $c->render('page', %vars);

=cut

async sub render ($self, $template_name, %vars) {
    my $view = $self->{app}->view;
    croak "No view configured. Call \$app->views() first." unless $view;

    # Pass the context so the view can detect htmx requests
    $vars{_context} = $self;

    my $html = $view->render($template_name, %vars);
    await $self->html($html);
}

=head2 render_string

    my $html = $c->render_string('todos/_item', todo => $todo);

Render a template and return the HTML string without sending a response.
Useful for WebSocket/SSE or building up response manually.

=cut

sub render_string ($self, $template_string, %vars) {
    my $view = $self->{app}->view;
    croak "No view configured. Call \$app->views() first." unless $view;

    $vars{_context} = $self;
    return $view->render_string($template_string, %vars);
}

=head2 render_or_redirect

    $c->render_or_redirect('/redirect_url', 'template', %vars);

For htmx requests: renders the template and sends it.
For browser requests: sends a redirect to the given URL.

Useful for form submissions where htmx expects a partial update
but browsers need a redirect for proper navigation.

=cut

async sub render_or_redirect ($self, $redirect_url, $template_name, %vars) {
    if ($self->req->is_htmx) {
        await $self->render($template_name, %vars);
    } else {
        await $self->redirect($redirect_url);
    }
}

=head2 empty_or_redirect

    $c->empty_or_redirect('/redirect_url');

For htmx requests: sends an empty 200 response (for element removal).
For browser requests: sends a redirect.

Useful for delete actions where htmx swaps out the deleted element
but browsers need a redirect.

=cut

async sub empty_or_redirect ($self, $redirect_url) {
    if ($self->req->is_htmx) {
        await $self->html('');
    } else {
        await $self->redirect($redirect_url);
    }
}

=head2 hx_trigger

    $c->hx_trigger('eventName');
    $c->hx_trigger('eventName', key => 'value');

    # Example usage - must still send a response:
    $c->hx_trigger('pollCreated', poll_id => $poll->{id});
    await $c->render('polls/_card', poll => $poll);

Set the HX-Trigger response header to trigger client-side events.
When called with just an event name, triggers a simple event.
When called with key-value pairs, triggers an event with data (JSON encoded).

B<Note:> This method only sets a response header. You must still send
a response using C<render()>, C<json()>, C<text()>, C<html()>, etc.
The HX-Trigger header will be included when the response is sent.

Returns C<$c> for chaining.

=cut

sub hx_trigger ($self, $event, %data) {
    require JSON::MaybeXS;

    if (%data) {
        # Event with data
        my $trigger_data = { $event => \%data };
        $self->res_header('HX-Trigger', JSON::MaybeXS::encode_json($trigger_data));
    } else {
        # Simple event
        $self->res_header('HX-Trigger', $event);
    }
    return $self;
}

=head2 hx_redirect

    $c->hx_redirect('/new-location');
    await $c->html('');  # Must still send a response

Set the HX-Redirect response header for client-side redirect.
htmx will perform a full page navigation to the given URL.

B<Note:> This method only sets a response header. You must still send
a response (even an empty one) for the header to be delivered to the client.

Returns C<$c> for chaining.

=cut

sub hx_redirect ($self, $url) {
    $self->res_header('HX-Redirect', $url);
    return $self;
}

=head2 hx_refresh

    $c->hx_refresh;
    await $c->html('');  # Must still send a response

Set the HX-Refresh response header to trigger a full page refresh.

B<Note:> This method only sets a response header. You must still send
a response (even an empty one) for the header to be delivered to the client.

Returns C<$c> for chaining.

=cut

sub hx_refresh ($self) {
    $self->res_header('HX-Refresh', 'true');
    return $self;
}

=head2 redirect

    await $c->redirect("/other");
    await $c->redirect("/other", 301);

Send a redirect response. Default status is 302 (Found).

=cut

async sub redirect ($self, $url, $status = 302) {
    $self->{_status} = $status;
    $self->res_header('location', $url);
    await $self->send_response('');
}

=head2 stream

    await $c->stream(async sub ($writer) {
        await $writer->write("Starting...\n");
        await $writer->write("More data\n");
        await $writer->close;
    });

    # With content type
    await $c->stream(async sub ($writer) {
        await $writer->writeln('{"items": [');
        for my $item (@items) {
            await $writer->writeln(encode_json($item) . ',');
        }
        await $writer->writeln(']}');
        await $writer->close;
    }, content_type => 'application/json');

Send a streaming chunked response. The callback receives a
L<PAGI::Simple::StreamWriter> object that can be used to write chunks.

The stream is automatically closed if the callback completes without
calling C<< $writer->close >>.

Options:

=over 4

=item * content_type - Content-Type header (default: text/plain)

=back

B<Important:> This method returns a Future and should be awaited. Route handlers
using C<stream> should be declared as C<async sub>:

    $app->get('/events' => async sub ($c) {
        await $c->stream(async sub ($writer) {
            await $writer->writeln("data: hello");
            await $writer->close;
        });
    });

=cut

async sub stream ($self, $callback, %opts) {
    die "Response already started" if $self->{_response_started};
    $self->{_response_started} = 1;

    # Set content type
    my $content_type = $opts{content_type} // 'text/plain; charset=utf-8';
    $self->content_type($content_type);

    # Send response start
    await $self->{send}->({
        type    => 'http.response.start',
        status  => $self->{_status},
        headers => $self->{_headers},
    });

    # Create writer
    my $writer = PAGI::Simple::StreamWriter->new($self);

    # Call the callback
    eval {
        my $result = $callback->($writer);
        if (Scalar::Util::blessed($result) && $result->can('get')) {
            await $result;
        }
    };
    my $err = $@;

    # Ensure stream is closed (even on error)
    unless ($writer->is_closed) {
        await $writer->close;
    }

    # Track response size
    $self->{_response_size} = $writer->bytes_sent;

    # Re-throw error after closing
    die $err if $err;
}

=head2 stream_from

    # From an arrayref
    await $c->stream_from(['chunk1', 'chunk2', 'chunk3']);

    # From a coderef (iterator)
    my $count = 0;
    await $c->stream_from(sub {
        return undef if $count >= 10;  # Return undef to end
        return "chunk " . ++$count . "\n";
    });

    # From a file path (recommended - uses non-blocking I/O)
    await $c->stream_from('/path/to/file.txt', chunk_size => 8192);

    # From a filehandle (blocking I/O - for backward compatibility)
    open my $fh, '<', $file;
    await $c->stream_from($fh, chunk_size => 8192);

    # With delay between chunks (for visible streaming)
    await $c->stream_from(\@chunks, delay => 1);  # 1 second between chunks

Send a streaming response from an iterator source. The source can be:

=over 4

=item * An arrayref - Each element is sent as a chunk

=item * A coderef - Called repeatedly; return undef to end the stream

=item * A file path (string) - Read and stream using non-blocking async I/O (recommended)

=item * A filehandle - Read and stream in chunks (blocking I/O, for backward compatibility)

=back

Options:

=over 4

=item * content_type - Content-Type header (default: text/plain)

=item * chunk_size - Size of chunks when reading from file/filehandle (default: 65536)

=item * delay - Delay in seconds between chunks (default: 0). Use this to make
streaming visible to clients or to rate-limit output. Even a small delay like
0.01 can help ensure chunks are flushed to the client individually.

=back

B<Note:> For best performance with large files, pass a file path string rather
than a filehandle. File paths use non-blocking async I/O which doesn't block
the event loop, while filehandles use blocking I/O for backward compatibility.

B<Important:> This method returns a Future and should be awaited. Route handlers
using C<stream_from> should be declared as C<async sub>:

    $app->get('/stream' => async sub ($c) {
        await $c->stream_from(\@data, delay => 0.5);
    });

=cut

async sub stream_from ($self, $source, %opts) {
    die "Response already started" if $self->{_response_started};

    my $content_type = $opts{content_type} // 'text/plain; charset=utf-8';
    my $chunk_size = $opts{chunk_size} // 65536;
    my $delay = $opts{delay};

    # Get loop for delay and/or async file I/O
    my $loop;
    if (defined $delay && $delay > 0) {
        require IO::Async::Loop;
        $loop = IO::Async::Loop->new;
    }

    # Check if source is a file path (non-ref string that's a file)
    my $is_file_path = !ref($source) && defined($source) && -f $source;

    # For file paths, get the loop from scope for async I/O
    my $async_loop = $self->{scope}{pagi}{loop};

    await $self->stream(async sub ($writer) {
        my $first = 1;  # Don't delay before first chunk

        if (ref($source) eq 'ARRAY') {
            # Array of chunks
            for my $chunk (@$source) {
                if (!$first && $loop) {
                    await $loop->delay_future(after => $delay);
                }
                $first = 0;
                await $writer->write($chunk);
            }
        }
        elsif (ref($source) eq 'CODE') {
            # Iterator coderef
            while (1) {
                my $chunk = $source->();
                last unless defined $chunk;
                if (!$first && $loop) {
                    await $loop->delay_future(after => $delay);
                }
                $first = 0;
                await $writer->write($chunk);
            }
        }
        elsif ($is_file_path && $async_loop) {
            # File path with async I/O (non-blocking)
            await PAGI::Util::AsyncFile->read_file_chunked(
                $async_loop, $source,
                async sub ($buffer) {
                    if (!$first && $loop) {
                        await $loop->delay_future(after => $delay);
                    }
                    $first = 0;
                    await $writer->write($buffer);
                },
                chunk_size => $chunk_size
            );
        }
        elsif ($is_file_path) {
            # File path without async loop - fall back to blocking I/O
            open my $fh, '<:raw', $source or die "Cannot open $source: $!";
            while (1) {
                my $buffer;
                my $bytes = read($fh, $buffer, $chunk_size);
                last unless $bytes;
                if (!$first && $loop) {
                    await $loop->delay_future(after => $delay);
                }
                $first = 0;
                await $writer->write($buffer);
            }
            close $fh;
        }
        elsif (ref($source) eq 'GLOB' || (Scalar::Util::blessed($source) && $source->can('read'))) {
            # Filehandle (blocking I/O for backward compatibility)
            while (1) {
                my $buffer;
                my $bytes = read($source, $buffer, $chunk_size);
                last unless $bytes;
                if (!$first && $loop) {
                    await $loop->delay_future(after => $delay);
                }
                $first = 0;
                await $writer->write($buffer);
            }
        }
        else {
            die "stream_from: unsupported source type " . (ref($source) || 'SCALAR');
        }

        await $writer->close;
    }, content_type => $content_type);
}

=head2 send_file

    await $c->send_file('/path/to/file.pdf');

    # With options
    await $c->send_file('/path/to/report.pdf',
        filename     => 'my-report.pdf',  # Download filename
        content_type => 'application/pdf',
        inline       => 0,                # Force download (default)
        chunk_size   => 65536,            # 64KB chunks (default)
    );

    # Inline display (e.g., images, PDFs in browser)
    await $c->send_file('/path/to/image.jpg', inline => 1);

Stream a file to the client. Automatically sets Content-Type based on
file extension and Content-Disposition for downloads.

Options:

=over 4

=item * filename - Filename for Content-Disposition (default: basename of path)

=item * content_type - Override auto-detected Content-Type

=item * inline - If true, display inline; if false, force download (default: 0)

=item * chunk_size - Chunk size for streaming (default: 65536)

=back

B<Important:> This method returns a Future and should be awaited. Route handlers
using C<send_file> should be declared as C<async sub>:

    $app->get('/download/:file' => async sub ($c) {
        await $c->send_file("/files/" . $c->path_params->{file});
    });

=cut

async sub send_file ($self, $path, %opts) {
    die "Response already started" if $self->{_response_started};
    die "File not found: $path" unless -f $path;
    die "Cannot read file: $path" unless -r $path;

    my $size = -s $path;
    my $content_type = $opts{content_type} // _guess_mime_type($path);
    my $filename = $opts{filename} // File::Basename::basename($path);
    my $inline = $opts{inline} // 0;
    my $chunk_size = $opts{chunk_size} // 65536;

    # Set headers
    $self->content_type($content_type);
    $self->res_header('Content-Length', $size);

    # Set Content-Disposition
    my $disposition = $inline ? 'inline' : 'attachment';
    # Sanitize filename for header
    my $safe_filename = $filename;
    $safe_filename =~ s/["\r\n]//g;  # Remove problematic characters
    $self->res_header('Content-Disposition', qq{$disposition; filename="$safe_filename"});

    $self->{_response_started} = 1;
    $self->{_response_size} = $size;

    # Send response start
    await $self->{send}->({
        type    => 'http.response.start',
        status  => $self->{_status},
        headers => $self->{_headers},
    });

    # Get the event loop for async file I/O
    my $loop = $self->{scope}{pagi}{loop};

    if ($loop) {
        # Use non-blocking async file I/O
        my $total = 0;
        my $send = $self->{send};

        await PAGI::Util::AsyncFile->read_file_chunked(
            $loop, $path,
            async sub ($buffer) {
                $total += length($buffer);
                my $more = $total < $size ? 1 : 0;

                await $send->({
                    type => 'http.response.body',
                    body => $buffer,
                    more => $more,
                });
            },
            chunk_size => $chunk_size
        );
    }
    else {
        # Fallback to blocking I/O if no loop available (e.g., in tests)
        open my $fh, '<:raw', $path or die "Cannot open $path: $!";

        my $total = 0;
        while (my $bytes = read($fh, my $buffer, $chunk_size)) {
            $total += $bytes;
            my $more = $total < $size ? 1 : 0;

            await $self->{send}->({
                type => 'http.response.body',
                body => $buffer,
                more => $more,
            });
        }

        close $fh;
    }
}

# Internal: Guess MIME type from file extension
sub _guess_mime_type ($path) {
    my %mime_types = (
        # Text
        html  => 'text/html; charset=utf-8',
        htm   => 'text/html; charset=utf-8',
        css   => 'text/css; charset=utf-8',
        js    => 'text/javascript; charset=utf-8',
        mjs   => 'text/javascript; charset=utf-8',
        txt   => 'text/plain; charset=utf-8',
        xml   => 'application/xml; charset=utf-8',
        json  => 'application/json; charset=utf-8',
        csv   => 'text/csv; charset=utf-8',

        # Images
        png   => 'image/png',
        jpg   => 'image/jpeg',
        jpeg  => 'image/jpeg',
        gif   => 'image/gif',
        svg   => 'image/svg+xml',
        ico   => 'image/x-icon',
        webp  => 'image/webp',

        # Fonts
        woff  => 'font/woff',
        woff2 => 'font/woff2',
        ttf   => 'font/ttf',
        otf   => 'font/otf',
        eot   => 'application/vnd.ms-fontobject',

        # Documents
        pdf   => 'application/pdf',
        doc   => 'application/msword',
        docx  => 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
        xls   => 'application/vnd.ms-excel',
        xlsx  => 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
        ppt   => 'application/vnd.ms-powerpoint',
        pptx  => 'application/vnd.openxmlformats-officedocument.presentationml.presentation',

        # Archives
        zip   => 'application/zip',
        gz    => 'application/gzip',
        tar   => 'application/x-tar',
        '7z'  => 'application/x-7z-compressed',
        rar   => 'application/vnd.rar',

        # Audio/Video
        mp3   => 'audio/mpeg',
        mp4   => 'video/mp4',
        webm  => 'video/webm',
        ogg   => 'audio/ogg',
        wav   => 'audio/wav',

        # Other
        wasm  => 'application/wasm',
    );

    my ($ext) = $path =~ /\.([^.]+)$/;
    $ext = lc($ext // '');

    return $mime_types{$ext} // 'application/octet-stream';
}

=head2 send_utf8

    await $c->send_utf8($body);
    await $c->send_utf8($body, charset => 'utf-8');

Encode a string body (if needed), ensure the Content-Type header includes a
charset (default utf-8), set Content-Length based on encoded bytes, and send
the response. If Content-Type already specifies a charset, that encoding is
used unless overridden via C<charset>. Callers should pass decoded text
strings; invalid bytes will croak. Use C<send_response> for raw/bytes.

=cut

async sub send_utf8 ($self, $body, %opts) {
    die "Response already started" if $self->{_response_started};

    my $charset = delete $opts{charset};
    croak("Unknown options to send_utf8: " . join(', ', keys %opts)) if %opts;

    my $headers = $self->{_headers};
    my $ct_header;
    for my $header (@$headers) {
        if (lc($header->[0]) eq 'content-type') {
            $ct_header = $header;
            last;
        }
    }

    if (!$charset && $ct_header && $ct_header->[1] =~ /;\s*charset=([^;]+)/i) {
        $charset = lc $1;
    }
    $charset //= 'utf-8';

    my $text = defined $body ? $body : '';
    my $encoded = encode($charset, $text, FB_CROAK | LEAVE_SRC);

    if ($ct_header) {
        if ($ct_header->[1] =~ /;\s*charset=/i) {
            $ct_header->[1] =~ s/(;\s*charset=)[^;]+/$1$charset/i;
        }
        else {
            $ct_header->[1] .= "; charset=$charset";
        }
    }
    else {
        push @$headers, ['content-type', "text/plain; charset=$charset"];
    }

    # Replace any existing Content-Length with the correct byte length
    @$headers = grep { lc($_->[0]) ne 'content-length' } @$headers;
    push @$headers, ['content-length', length($encoded // '')];

    await $self->send_response($encoded);
}

=head2 send_response

    await $c->send_response($body);

Low-level method to send the response with current status and headers.
Most users should use text(), html(), json(), or redirect() instead.

=cut

async sub send_response ($self, $body) {
    die "Response already started" if $self->{_response_started};

    $self->{_response_started} = 1;
    $self->{_response_size} = length($body // '');

    # Send response start
    await $self->{send}->({
        type    => 'http.response.start',
        status  => $self->{_status},
        headers => $self->{_headers},
    });

    # Send body
    await $self->{send}->({
        type => 'http.response.body',
        body => $body,
        more => 0,
    });
}

=head2 response_size

    my $size = $c->response_size;

Returns the size of the response body in bytes (for logging).

=cut

sub response_size ($self) {
    return $self->{_response_size};
}

=head2 response_status

    my $status = $c->response_status;

Returns the response status code (for logging).

=cut

sub response_status ($self) {
    return $self->{_status};
}

=head2 response_headers

    my $headers = $c->response_headers;

Returns the response headers array (for logging).

=cut

sub response_headers ($self) {
    return $self->{_headers};
}

=head2 abort

    $c->abort(403);                          # Forbidden
    $c->abort(404, "Item not found");        # Custom message
    $c->abort(500, "Database error");        # Server error with message

Abort request processing with an error response. This method throws
a PAGI::Simple::Abort exception immediately to stop handler execution.
The framework catches this exception and sends the appropriate error
response (using custom error handler if registered, or default response).

Note: This is a synchronous method that throws immediately. The actual
error response is sent by the framework, not by this method.

=cut

sub abort ($self, $code, $message = undef) {
    # Don't abort if response already started
    if ($self->{_response_started}) {
        die "Cannot abort: response already started";
    }

    # Throw abort exception immediately - framework will handle sending response
    die bless { code => $code, message => $message, context => $self }, 'PAGI::Simple::Abort';
}

# Internal: Get default status text
sub _status_text ($code) {
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
    return $text{$code} // "Error $code";
}

=head1 SEE ALSO

L<PAGI::Simple>, L<PAGI::Simple::Request>, L<PAGI::Simple::Response>

=head1 AUTHOR

PAGI Contributors

=cut

# PAGI::Simple::Abort - Exception class for abort()
package PAGI::Simple::Abort;

sub code ($self) { return $self->{code}; }
sub message ($self) { return $self->{message}; }
sub context ($self) { return $self->{context}; }

# PAGI::Simple::Context::Logger - Request-aware logger
package PAGI::Simple::Context::Logger;

use strict;
use warnings;
use experimental 'signatures';
use Time::HiRes qw(time);
use POSIX qw(strftime);

sub new ($class, %args) {
    my $self = bless {
        context => $args{context},
    }, $class;
    return $self;
}

sub _format_message ($self, $level, $message) {
    my $now = time();
    my $timestamp = strftime("%Y-%m-%d %H:%M:%S", localtime($now));
    my $ms = sprintf(".%03d", ($now - int($now)) * 1000);

    my $c = $self->{context};
    my $method = $c->method // '-';
    my $path = $c->path // '/';

    return "[$timestamp$ms] [$level] $method $path - $message\n";
}

sub _log ($self, $level, @messages) {
    my $message = join(' ', @messages);
    my $formatted = $self->_format_message($level, $message);
    print STDERR $formatted;
}

sub debug ($self, @messages) { $self->_log('DEBUG', @messages); }
sub info  ($self, @messages) { $self->_log('INFO',  @messages); }
sub warn  ($self, @messages) { $self->_log('WARN',  @messages); }
sub error ($self, @messages) { $self->_log('ERROR', @messages); }

1;
