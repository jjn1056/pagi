# PAGI Tutorial Plan

> **Target Audience:** Web developers who want to build async web applications with PAGI. Not server implementers.

**Goal:** Create a comprehensive POD tutorial (`lib/PAGI/Tutorial.pod`) that takes developers from zero to productive with PAGI.

**Format:** Single POD file with clear sections, runnable code examples, and progressive complexity.

---

## Proposed Structure

### Part 1: Getting Started

#### 1.1 Introduction
- What is PAGI? (Perl Asynchronous Gateway Interface)
- Why async? (WebSocket, SSE, streaming, high concurrency)
- PAGI vs PSGI comparison (async vs sync, scope vs env)
- Prerequisites: Perl 5.16+, Future::AsyncAwait, IO::Async

#### 1.2 Installation
```bash
cpanm PAGI
# or from source
cpanm --installdeps .
```

#### 1.3 Your First PAGI App
```perl
# hello.pl
use strict;
use warnings;
use Future::AsyncAwait;

async sub app {
    my ($scope, $receive, $send) = @_;

    await $send->({
        type => 'http.response.start',
        status => 200,
        headers => [['content-type', 'text/plain']],
    });

    await $send->({
        type => 'http.response.body',
        body => 'Hello, World!',
    });
}

\&app;
```

Running it:
```bash
pagi-server hello.pl --port 5000
curl http://localhost:5000/
```

---

### Part 2: Understanding Raw PAGI

#### 2.1 The Three Arguments
- `$scope` - Connection metadata (type, method, path, headers, query_string)
- `$receive` - Async coderef to receive client events
- `$send` - Async coderef to send responses

#### 2.2 Scope Types
- `http` - Standard HTTP requests
- `websocket` - WebSocket connections
- `sse` - Server-Sent Events (PAGI extension)
- `lifespan` - Application lifecycle events

#### 2.3 HTTP Request/Response Cycle (Raw)
```perl
async sub app {
    my ($scope, $receive, $send) = @_;

    # Read request body
    my $body = '';
    while (1) {
        my $event = await $receive->();
        $body .= $event->{body} // '';
        last if $event->{more_body} // 1 == 0;
    }

    # Send response
    await $send->({
        type => 'http.response.start',
        status => 200,
        headers => [
            ['content-type', 'application/json'],
            ['x-custom', 'header'],
        ],
    });

    await $send->({
        type => 'http.response.body',
        body => '{"message": "Got ' . length($body) . ' bytes"}',
    });
}
```

#### 2.4 WebSocket (Raw)
```perl
async sub app {
    my ($scope, $receive, $send) = @_;
    return unless $scope->{type} eq 'websocket';

    # Accept the connection
    await $send->({ type => 'websocket.accept' });

    # Echo loop
    while (1) {
        my $event = await $receive->();
        last if $event->{type} eq 'websocket.disconnect';

        if ($event->{type} eq 'websocket.receive') {
            await $send->({
                type => 'websocket.send',
                text => "Echo: $event->{text}",
            });
        }
    }
}
```

#### 2.5 SSE (Raw)
```perl
async sub app {
    my ($scope, $receive, $send) = @_;
    return unless $scope->{type} eq 'sse';

    await $send->({ type => 'sse.response.start' });

    for my $i (1..5) {
        await $send->({
            type => 'sse.response.body',
            data => "Event $i",
            event => 'tick',
        });
        await IO::Async::Loop->new->delay_future(after => 1);
    }
}
```

---

### Part 3: The Helper Classes

#### 3.1 PAGI::Response - Fluent Response Builder
```perl
use PAGI::Response;

async sub app {
    my ($scope, $receive, $send) = @_;
    my $res = PAGI::Response->new($send);

    # Simple responses
    await $res->text('Hello!');
    await $res->html('<h1>Hello!</h1>');
    await $res->json({ message => 'Hello!' });

    # With status and headers
    await $res->status(201)
              ->header('X-Custom' => 'value')
              ->json({ created => 1 });

    # Redirects
    await $res->redirect('/new-location');
    await $res->redirect('/permanent', 301);

    # Errors
    await $res->error(404, 'Not Found');
    await $res->error(500);  # Uses default message

    # Streaming
    my $writer = await $res->stream('text/plain');
    await $writer->write("chunk 1\n");
    await $writer->write("chunk 2\n");
    await $writer->close();

    # File downloads
    await $res->send_file('/path/to/file.pdf');
    await $res->send_file('/path/to/file.pdf',
        filename => 'download.pdf',
        inline => 0,
    );
}
```

#### 3.2 PAGI::Request - Request Parsing
```perl
use PAGI::Request;

async sub app {
    my ($scope, $receive, $send) = @_;
    my $req = PAGI::Request->new($scope, $receive);
    my $res = PAGI::Response->new($send);

    # Basic properties
    my $method = $req->method;           # GET, POST, etc.
    my $path = $req->path;               # /users/123
    my $query = $req->query_string;      # foo=bar&baz=qux

    # Headers
    my $ct = $req->content_type;
    my $auth = $req->header('Authorization');

    # Query parameters
    my $page = $req->param('page');      # Single value
    my @tags = $req->param('tags');      # Multiple values
    my $params = $req->params;           # Hashref of all

    # Body parsing (async)
    my $body = await $req->body;         # Raw bytes
    my $json = await $req->json;         # Parsed JSON
    my $form = await $req->form;         # URL-encoded form

    # File uploads (multipart)
    my $uploads = await $req->uploads;
    for my $upload (@$uploads) {
        my $filename = $upload->filename;
        my $content = $upload->content;
        # or save: $upload->save_to('/path/to/dir');
    }

    # Cookies
    my $session = $req->cookies->{session_id};

    # Per-request stash (shared with middleware)
    $req->stash->{user} = $current_user;

    await $res->json({ method => $method, path => $path });
}
```

#### 3.3 PAGI::WebSocket - WebSocket Helper
```perl
use PAGI::WebSocket;

async sub app {
    my ($scope, $receive, $send) = @_;
    return unless $scope->{type} eq 'websocket';

    my $ws = PAGI::WebSocket->new($scope, $receive, $send);

    await $ws->accept;
    await $ws->send_text('Welcome!');

    # Iteration helpers
    await $ws->each_text(sub {
        my ($text) = @_;
        $ws->try_send_text("Echo: $text");
    });

    # Or manual loop
    while (my $msg = await $ws->receive) {
        last if $msg->{type} eq 'websocket.disconnect';
        await $ws->send_text("Got: $msg->{text}");
    }

    # JSON convenience
    await $ws->send_json({ type => 'greeting', msg => 'hi' });
    my $data = await $ws->receive_json;

    # Close with code/reason
    await $ws->close(1000, 'Goodbye');
}
```

#### 3.4 PAGI::SSE - Server-Sent Events Helper
```perl
use PAGI::SSE;

async sub app {
    my ($scope, $receive, $send) = @_;
    return unless $scope->{type} eq 'sse';

    my $sse = PAGI::SSE->new($scope, $receive, $send);

    await $sse->start;

    # Send events
    await $sse->send_event('Hello!');
    await $sse->send_event('Update', event => 'status');
    await $sse->send_event('{"count":1}', event => 'data', id => '1');

    # JSON convenience
    await $sse->send_json({ count => 1 }, event => 'update');

    # Keepalive (prevents connection timeout)
    $sse->keepalive(15);  # Send comment every 15 seconds

    # Periodic updates
    await $sse->every(1, async sub {
        await $sse->send_json({ time => time() });
    });
}
```

---

### Part 4: Routing

#### 4.1 PAGI::App::Router - Functional Routing
```perl
use PAGI::App::Router;
use PAGI::Response;

my $router = PAGI::App::Router->new;

# HTTP routes
$router->get('/' => async sub {
    my ($scope, $receive, $send) = @_;
    my $res = PAGI::Response->new($send);
    await $res->text('Home');
});

$router->post('/users' => async sub {
    my ($scope, $receive, $send) = @_;
    my $req = PAGI::Request->new($scope, $receive);
    my $res = PAGI::Response->new($send);
    my $data = await $req->json;
    await $res->status(201)->json({ id => 1, %$data });
});

# Path parameters
$router->get('/users/:id' => async sub {
    my ($scope, $receive, $send) = @_;
    my $id = $scope->{'pagi.params'}{id};
    my $res = PAGI::Response->new($send);
    await $res->json({ id => $id });
});

# Wildcards
$router->get('/files/*path' => async sub {
    my ($scope, $receive, $send) = @_;
    my $path = $scope->{'pagi.params'}{path};
    # ...
});

# WebSocket route
$router->websocket('/ws' => async sub {
    my ($scope, $receive, $send) = @_;
    my $ws = PAGI::WebSocket->new($scope, $receive, $send);
    await $ws->accept;
    # ...
});

# SSE route
$router->sse('/events' => async sub {
    my ($scope, $receive, $send) = @_;
    my $sse = PAGI::SSE->new($scope, $receive, $send);
    await $sse->start;
    # ...
});

# Mount sub-applications
$router->mount('/api' => $api_router);

$router->to_app;
```

#### 4.2 PAGI::Endpoint::Router - Class-Based Routing
```perl
package MyApp;
use parent 'PAGI::Endpoint::Router';
use Future::AsyncAwait;

# Lifecycle hooks
async sub on_startup {
    my ($self) = @_;
    $self->state->{db} = DBI->connect(...);
}

async sub on_shutdown {
    my ($self) = @_;
    $self->state->{db}->disconnect;
}

# Define routes
sub routes {
    my ($self, $r) = @_;

    $r->get('/' => 'home');
    $r->get('/users/:id' => 'get_user');
    $r->post('/users' => 'create_user');

    # With middleware
    $r->get('/admin' => ['require_admin'] => 'admin_page');

    # WebSocket
    $r->websocket('/ws' => 'handle_ws');
}

# Handlers receive $req and $res (or $ws for WebSocket)
async sub home {
    my ($self, $req, $res) = @_;
    await $res->text('Welcome!');
}

async sub get_user {
    my ($self, $req, $res) = @_;
    my $id = $req->param('id');
    my $db = $self->state->{db};
    my $user = $db->get_user($id);
    await $res->json($user);
}

async sub require_admin {
    my ($self, $req, $res, $next) = @_;
    return await $res->error(403) unless $req->stash->{user}{admin};
    await $next->();
}

async sub handle_ws {
    my ($self, $ws) = @_;
    await $ws->accept;
    await $ws->each_text(sub { $ws->try_send_text("Echo: $_[0]") });
}

1;

# app.pl
use MyApp;
MyApp->to_app;
```

---

### Part 5: Middleware

#### 5.1 Using Middleware with Router
```perl
use PAGI::App::Router;
use PAGI::Middleware::AccessLog;
use PAGI::Middleware::CORS;
use PAGI::Middleware::GZip;

my $router = PAGI::App::Router->new;

# Global middleware (applied to all routes)
$router->use(PAGI::Middleware::AccessLog->new(format => 'combined'));
$router->use(PAGI::Middleware::CORS->new(
    origins => ['https://example.com'],
    methods => ['GET', 'POST', 'PUT', 'DELETE'],
));
$router->use(PAGI::Middleware::GZip->new(min_size => 1024));

# Routes...
$router->get('/' => async sub { ... });

$router->to_app;
```

#### 5.2 Route-Level Middleware
```perl
# Middleware only for specific routes
$router->get('/admin' => [
    PAGI::Middleware::RateLimit->new(rate => 10, period => 60),
] => async sub {
    my ($scope, $receive, $send) = @_;
    # ...
});
```

#### 5.3 Essential Middleware Reference

**Logging & Debugging:**
```perl
# Access logging
use PAGI::Middleware::AccessLog;
$router->use(PAGI::Middleware::AccessLog->new(
    format => 'combined',  # or 'common', 'tiny'
));

# Request IDs for tracing
use PAGI::Middleware::RequestId;
$router->use(PAGI::Middleware::RequestId->new);

# Response timing
use PAGI::Middleware::Runtime;
$router->use(PAGI::Middleware::Runtime->new);
```

**Security:**
```perl
# CORS
use PAGI::Middleware::CORS;
$router->use(PAGI::Middleware::CORS->new(
    origins => '*',  # or ['https://example.com']
    methods => ['GET', 'POST', 'PUT', 'DELETE'],
    headers => ['Content-Type', 'Authorization'],
    credentials => 1,
    max_age => 86400,
));

# Security headers
use PAGI::Middleware::SecurityHeaders;
$router->use(PAGI::Middleware::SecurityHeaders->new(
    content_security_policy => "default-src 'self'",
    x_frame_options => 'DENY',
));

# CSRF protection
use PAGI::Middleware::CSRF;
$router->use(PAGI::Middleware::CSRF->new(
    cookie_name => 'csrf_token',
));
```

**Sessions & Cookies:**
```perl
# Cookie parsing
use PAGI::Middleware::Cookie;
$router->use(PAGI::Middleware::Cookie->new);

# Sessions
use PAGI::Middleware::Session;
$router->use(PAGI::Middleware::Session->new(
    secret => 'your-secret-key',
    cookie_name => 'session_id',
    max_age => 86400,
));
```

**Performance:**
```perl
# GZip compression
use PAGI::Middleware::GZip;
$router->use(PAGI::Middleware::GZip->new(
    min_size => 1024,
    types => ['text/*', 'application/json'],
));

# ETag generation
use PAGI::Middleware::ETag;
$router->use(PAGI::Middleware::ETag->new);

# Rate limiting
use PAGI::Middleware::RateLimit;
$router->use(PAGI::Middleware::RateLimit->new(
    rate => 100,
    period => 60,
    by => sub { $_[0]->{client} },
));
```

**Error Handling:**
```perl
use PAGI::Middleware::ErrorHandler;
$router->use(PAGI::Middleware::ErrorHandler->new(
    mode => 'development',  # Shows stack traces
    # mode => 'production', # Generic error pages
));
```

#### 5.4 Writing Custom Middleware
```perl
package MyApp::Middleware::Auth;
use parent 'PAGI::Middleware';
use Future::AsyncAwait;

sub new {
    my ($class, %args) = @_;
    return bless { secret => $args{secret} }, $class;
}

async sub call {
    my ($self, $scope, $receive, $send, $app) = @_;

    # Extract token from header
    my $auth = $self->get_header($scope, 'Authorization');

    if ($auth && $auth =~ /^Bearer (.+)/) {
        my $token = $1;
        my $user = verify_token($token, $self->{secret});
        $scope->{'pagi.stash'}{user} = $user if $user;
    }

    # Call next middleware/app
    await $app->($scope, $receive, $send);
}

1;
```

---

### Part 6: Built-in Applications

#### 6.1 Static Files
```perl
use PAGI::App::File;

# Serve a directory
my $static = PAGI::App::File->new(root => './public');

# Mount under /static
$router->mount('/static' => $static);

# Or use as middleware
use PAGI::Middleware::Static;
$router->use(PAGI::Middleware::Static->new(
    root => './public',
    urls => ['/css', '/js', '/images'],
));
```

#### 6.2 Health Checks
```perl
use PAGI::App::Healthcheck;

my $health = PAGI::App::Healthcheck->new(
    checks => {
        database => sub { $db->ping ? 1 : 0 },
        cache => sub { $redis->ping ? 1 : 0 },
    },
);

$router->mount('/health' => $health);
# Returns: {"status":"healthy","checks":{"database":true,"cache":true}}
```

#### 6.3 URL Mapping
```perl
use PAGI::App::URLMap;

my $app = PAGI::App::URLMap->new;
$app->mount('/api' => $api_app);
$app->mount('/admin' => $admin_app);
$app->mount('/' => $main_app);

$app->to_app;
```

#### 6.4 Cascade (Try Multiple Apps)
```perl
use PAGI::App::Cascade;

# Try apps in order until one doesn't return 404
my $app = PAGI::App::Cascade->new(
    apps => [$api_app, $static_app, $default_app],
);
```

#### 6.5 PSGI Compatibility
```perl
use PAGI::App::WrapPSGI;

# Use existing PSGI apps with PAGI
my $psgi_app = sub { ... };  # Your PSGI app
my $pagi_app = PAGI::App::WrapPSGI->new(app => $psgi_app);

$router->mount('/legacy' => $pagi_app);
```

---

### Part 7: Real-World Patterns

#### 7.1 Complete Application Structure
```
myapp/
├── app.pl                 # Entry point
├── lib/
│   └── MyApp/
│       ├── Main.pm        # Main router
│       ├── API.pm         # API subrouter
│       └── Middleware/
│           └── Auth.pm    # Custom middleware
├── public/                # Static files
│   ├── css/
│   └── js/
└── templates/             # HTML templates (if using)
```

#### 7.2 Background Tasks
```perl
# Fire-and-forget async I/O
send_email($user)->retain();

# Blocking work in subprocess
use IO::Async::Function;
my $worker = IO::Async::Function->new(code => sub { ... });
$res->loop->add($worker);

my $f = $worker->call(args => [$data]);
$f->on_done(sub { ... });
$f->retain();
```

#### 7.3 Error Handling
```perl
use Future::AsyncAwait;
use Syntax::Keyword::Try;

async sub handler {
    my ($scope, $receive, $send) = @_;
    my $res = PAGI::Response->new($send);

    try {
        my $result = await do_something_risky();
        await $res->json($result);
    }
    catch ($e) {
        warn "Error: $e";
        await $res->error(500, 'Something went wrong');
    }
}
```

#### 7.4 Testing
```perl
use Test2::V0;
use PAGI::Test::Client;

my $app = do './app.pl';
my $client = PAGI::Test::Client->new(app => $app);

# HTTP tests
my $res = await $client->get('/');
is($res->status, 200);
like($res->text, qr/Welcome/);

# JSON API tests
$res = await $client->post('/api/users', json => { name => 'Alice' });
is($res->status, 201);
is($res->json->{name}, 'Alice');

# WebSocket tests
my $ws = await $client->websocket('/ws');
await $ws->send_text('hello');
my $msg = await $ws->receive_text;
is($msg, 'Echo: hello');
await $ws->close;

done_testing;
```

---

### Part 8: Reference

#### 8.1 Scope Reference
```perl
# HTTP scope
{
    type         => 'http',
    method       => 'GET',
    path         => '/users/123',
    raw_path     => '/users/123',  # Not URL-decoded
    query_string => 'foo=bar',
    headers      => [['host', 'example.com'], ['accept', '*/*']],
    scheme       => 'https',
    http_version => '1.1',
    client       => '127.0.0.1:12345',
    server       => '127.0.0.1:5000',
}

# WebSocket scope
{
    type         => 'websocket',
    path         => '/ws',
    query_string => '',
    headers      => [...],
    subprotocols => ['graphql', 'json'],
}

# SSE scope
{
    type         => 'sse',
    path         => '/events',
    query_string => '',
    headers      => [...],
}
```

#### 8.2 Event Types Reference
- HTTP: `http.request`, `http.response.start`, `http.response.body`
- WebSocket: `websocket.connect`, `websocket.accept`, `websocket.receive`, `websocket.send`, `websocket.disconnect`, `websocket.close`
- SSE: `sse.response.start`, `sse.response.body`
- Lifespan: `lifespan.startup`, `lifespan.startup.complete`, `lifespan.shutdown`, `lifespan.shutdown.complete`

---

## Implementation Tasks

### Task 1: Create lib/PAGI/Tutorial.pod
- Write Parts 1-3 (Getting Started, Raw PAGI, Helper Classes)
- Include runnable examples
- Add cross-references to module POD

### Task 2: Continue with Parts 4-5
- Routing section with both Router types
- Middleware usage and writing custom middleware

### Task 3: Continue with Parts 6-7
- Built-in applications
- Real-world patterns

### Task 4: Finish with Part 8
- Reference section
- Index of all examples

### Task 5: Review and Polish
- Verify all examples compile and run
- Check cross-references
- Add "See Also" links

---

## Notes

- Each section should be self-contained with a complete runnable example
- Use consistent code style throughout
- Prefer showing the simple case first, then variations
- Link to module POD for detailed API docs
- Include common gotchas and tips
