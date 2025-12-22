# PAGI::Test::Client Design

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Provide a TestClient for PAGI apps that enables testing without spinning up a real server, inspired by Starlette's TestClient but adapted for Perl and PAGI's first-class SSE support.

**Architecture:** Direct app invocation - the client constructs `$scope`, `$receive`, `$send` and calls the app directly, capturing responses. No network I/O, no port binding.

**Tech Stack:** Perl 5.16+, Future::AsyncAwait, Test2::V0 compatible

---

## Core Components

### PAGI::Test::Client

Main entry point for testing PAGI applications.

```perl
use PAGI::Test::Client;

my $client = PAGI::Test::Client->new(
    app     => $app,              # Required: PAGI app coderef
    headers => { ... },           # Optional: default headers for all requests
    lifespan => 0,                # Optional: enable lifespan handling (default: off)
);
```

### HTTP Methods

Standard HTTP methods return a `PAGI::Test::Response`:

```perl
$client->get($path, %options);
$client->post($path, %options);
$client->put($path, %options);
$client->patch($path, %options);
$client->delete($path, %options);
$client->head($path, %options);
$client->options($path, %options);
```

**Options:**
- `headers => { ... }` - Request headers
- `json => { ... }` - JSON body (auto-sets Content-Type)
- `form => { ... }` - Form-encoded body (auto-sets Content-Type)
- `body => $bytes` - Raw body bytes
- `query => { ... }` - Query string parameters

**Examples:**

```perl
# Simple GET
my $res = $client->get('/');

# POST with JSON
my $res = $client->post('/api/users', json => { name => 'John' });

# POST with form data
my $res = $client->post('/login', form => { user => 'admin', pass => 'secret' });

# Custom headers
my $res = $client->get('/protected', headers => { Authorization => 'Bearer xyz' });

# Query parameters
my $res = $client->get('/search', query => { q => 'perl', limit => 10 });
```

### PAGI::Test::Response

Wraps HTTP response data with convenient accessors:

```perl
# Status
$res->status;           # 200
$res->is_success;       # true if 2xx
$res->is_redirect;      # true if 3xx
$res->is_error;         # true if 4xx or 5xx

# Headers
$res->header('Content-Type');   # 'application/json'
$res->headers;                  # hashref of all headers

# Body
$res->content;          # raw bytes
$res->text;             # decoded text (uses charset from Content-Type)
$res->json;             # parsed JSON (dies if invalid)

# Convenience
$res->content_type;     # 'application/json'
$res->content_length;   # 42
$res->location;         # Location header (for redirects)
```

---

## WebSocket Support

### PAGI::Test::WebSocket

Two usage styles - callback (auto-close) and explicit:

**Callback style (recommended):**

```perl
$client->websocket('/ws', sub {
    my ($ws) = @_;
    $ws->send_text('hello');
    is $ws->receive_text, 'echo: hello';
});  # auto-closes, exceptions propagate
```

**Explicit style:**

```perl
my $ws = $client->websocket('/ws');
$ws->send_text('hello');
is $ws->receive_text, 'echo: hello';
$ws->close;
```

**Methods:**

```perl
# Send
$ws->send_text($string);
$ws->send_bytes($bytes);
$ws->send_json($data);      # auto-encodes

# Receive (blocks until data arrives)
$ws->receive_text;
$ws->receive_text(timeout => 5);    # dies after 5 seconds
$ws->receive_bytes;
$ws->receive_json;                  # auto-decodes

# Close
$ws->close;
$ws->close($code);
$ws->close($code, $reason);
$ws->close_code;            # code received from server
```

---

## SSE Support

PAGI has first-class SSE (unlike ASGI), so we provide dedicated SSE testing.

### PAGI::Test::SSE

**Callback style (recommended):**

```perl
$client->sse('/events', sub {
    my ($sse) = @_;

    my $event = $sse->receive_event;
    is $event->{event}, 'connected';
    is $event->{data}, '{"subscriber_id":1}';

    # JSON convenience
    my $data = $sse->receive_json;  # parses data field
});
```

**Explicit style:**

```perl
my $sse = $client->sse('/events');
my $event = $sse->receive_event;
$sse->close;
```

**Methods:**

```perl
# Receive
$sse->receive_event;                # returns hashref
$sse->receive_event(timeout => 5);  # with timeout
$sse->receive_json;                 # convenience: parses data as JSON

# Close
$sse->close;
```

**Event structure:**

```perl
{
    event => 'message',     # from event: line
    data  => '...',         # from data: line(s)
    id    => '123',         # from id: line
    retry => 3000,          # from retry: line (if present)
}
```

---

## Lifespan Support

For apps with startup/shutdown hooks:

```perl
# Disabled by default (most tests don't need it)
my $client = PAGI::Test::Client->new(app => $app);

# Enable lifespan
my $client = PAGI::Test::Client->new(app => $app, lifespan => 1);
$client->start;     # triggers lifespan.startup
# ... tests ...
$client->stop;      # triggers lifespan.shutdown

# Callback style (auto start/stop)
PAGI::Test::Client->run($app, sub {
    my ($client) = @_;
    my $res = $client->get('/');
});

# Access shared state from lifespan
my $state = $client->state;
```

---

## Session & Cookies

Cookies persist across requests:

```perl
# Login sets cookie
$client->post('/login', form => { user => 'admin', pass => 'secret' });

# Subsequent requests are authenticated
$client->get('/dashboard');  # cookie sent automatically

# Inspect cookies
$client->cookies;               # hashref
$client->cookie('session_id');  # specific cookie

# Manually set/clear
$client->set_cookie('theme', 'dark');
$client->clear_cookies;
```

---

## Internal Architecture

### HTTP Request Flow

1. Build `$scope` from method, path, headers, query string
2. Create `$receive` coderef that yields:
   - `{ type => 'http.request', body => $body, more => 0 }`
3. Create `$send` coderef that captures events
4. Call `await $app->($scope, $receive, $send)`
5. Collect `http.response.start` (status, headers) and `http.response.body` events
6. Return `PAGI::Test::Response` wrapping captured data

### WebSocket Flow

1. Build `websocket` scope
2. `$receive` initially yields `{ type => 'websocket.connect' }`
3. Wait for app to `$send` `websocket.accept`
4. `send_*` methods queue `websocket.receive` events
5. `receive_*` methods wait for `websocket.send` events
6. `close` sends `websocket.disconnect`

### SSE Flow

1. Build `sse` scope (PAGI-specific)
2. `$receive` yields disconnect when `close` called
3. Wait for app to `$send` `sse.start`
4. `receive_*` methods wait for `sse.send` events
5. `close` triggers `sse.disconnect`

---

## File Structure

```
lib/PAGI/Test/Client.pm      # Main client class
lib/PAGI/Test/Response.pm    # HTTP response wrapper
lib/PAGI/Test/WebSocket.pm   # WebSocket test connection
lib/PAGI/Test/SSE.pm         # SSE test connection
t/test-client/               # Tests for the test client itself
```

---

## Example Test Rewrite

**Before (current style):**

```perl
my $loop = IO::Async::Loop->new;
my $server = PAGI::Server->new(app => $app, host => '127.0.0.1', port => 0, quiet => 1);
$loop->add($server);
$server->listen->get;

my $http = Net::Async::HTTP->new;
$loop->add($http);
my $response = $http->GET("http://127.0.0.1:" . $server->port . "/")->get;

is($response->code, 200);
is($response->content, 'Hello World');

$server->shutdown->get;
```

**After (with TestClient):**

```perl
my $client = PAGI::Test::Client->new(app => $app);
my $res = $client->get('/');

is $res->status, 200;
is $res->text, 'Hello World';
```

---

## Success Criteria

- Tests run faster (no network overhead)
- Test code is 80%+ shorter
- All three protocols work: HTTP, WebSocket, SSE
- Session cookies persist across requests
- Lifespan hooks work when enabled
- Compatible with Test2::V0
- Works with Perl 5.16+
