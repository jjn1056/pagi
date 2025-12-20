---
name: pagi-development
description: Use when writing raw PAGI applications, understanding PAGI spec, or debugging PAGI code. Covers HTTP, WebSocket, SSE, and Lifespan protocols.
---

# PAGI Development Skill

This skill teaches how to write raw PAGI (Perl Asynchronous Gateway Interface) applications. PAGI is an async-native successor to PSGI supporting HTTP, WebSocket, SSE, and lifecycle management.

## When to Use This Skill

- Writing a new raw PAGI application
- Understanding PAGI scope types and events
- Debugging PAGI protocol issues
- Converting PSGI apps to PAGI

## Core Application Interface

Every PAGI application is an async coderef with this signature:

```perl
use strict;
use warnings;
use Future::AsyncAwait;
use experimental 'signatures';

async sub app ($scope, $receive, $send) {
    # $scope   - HashRef with connection metadata
    # $receive - Async coderef returning event HashRefs
    # $send    - Async coderef accepting event HashRefs
}
```

### The Three Parameters

**$scope** - Connection metadata (read-only):
- `type` - Protocol: `"http"`, `"websocket"`, `"sse"`, `"lifespan"`
- `pagi` - HashRef with `version` and `spec_version`
- Protocol-specific keys (path, method, headers, etc.)

**$receive** - Get events from client/server:
```perl
my $event = await $receive->();
# Returns HashRef with 'type' key
```

**$send** - Send events to client:
```perl
await $send->({ type => 'http.response.start', status => 200, ... });
```

### Required Error Handling

Apps MUST reject unsupported scope types:

```perl
async sub app ($scope, $receive, $send) {
    die "Unsupported scope type: $scope->{type}"
        unless $scope->{type} eq 'http';
    # ... handle request
}
```

### File Structure

PAGI apps are typically loaded via `do`:

```perl
# app.pl
use strict;
use warnings;
use Future::AsyncAwait;
use experimental 'signatures';

my $app = async sub ($scope, $receive, $send) {
    # ... implementation
};

$app;  # Return coderef when loaded
```

Run with: `pagi-server ./app.pl --port 5000`

## HTTP Protocol

### HTTP Scope

When `$scope->{type}` is `"http"`:

```perl
{
    type         => 'http',
    http_version => '1.1',           # '1.0', '1.1', or '2'
    method       => 'GET',           # Uppercase
    scheme       => 'http',          # or 'https'
    path         => '/users/123',    # Decoded UTF-8
    raw_path     => '/users/123',    # Original bytes (optional)
    query_string => 'foo=bar',       # Raw bytes after ?
    root_path    => '',              # Mount point (like SCRIPT_NAME)
    headers      => [                # ArrayRef of [name, value] pairs
        ['host', 'example.com'],
        ['content-type', 'application/json'],
    ],
    client       => ['192.168.1.1', 54321],  # [host, port] (optional)
    server       => ['0.0.0.0', 5000],       # [host, port] (optional)
    state        => {},                       # From lifespan (optional)
}
```

### Reading Request Body

```perl
async sub app ($scope, $receive, $send) {
    die "Unsupported" if $scope->{type} ne 'http';

    # Collect full body
    my $body = '';
    while (1) {
        my $event = await $receive->();
        if ($event->{type} eq 'http.request') {
            $body .= $event->{body} // '';
            last unless $event->{more};
        }
        elsif ($event->{type} eq 'http.disconnect') {
            return;  # Client disconnected
        }
    }

    # Now $body contains full request body
}
```

### Sending Response

**Simple response:**

```perl
await $send->({
    type    => 'http.response.start',
    status  => 200,
    headers => [
        ['content-type', 'text/plain'],
        ['content-length', '13'],
    ],
});

await $send->({
    type => 'http.response.body',
    body => 'Hello, World!',
});
```

**Streaming response:**

```perl
await $send->({
    type    => 'http.response.start',
    status  => 200,
    headers => [['content-type', 'text/plain']],
});

for my $chunk (@chunks) {
    await $send->({
        type => 'http.response.body',
        body => $chunk,
        more => 1,  # More chunks coming
    });
}

# Final chunk
await $send->({
    type => 'http.response.body',
    body => '',
    more => 0,  # Done
});
```

**File response:**

```perl
await $send->({
    type    => 'http.response.start',
    status  => 200,
    headers => [['content-type', 'application/octet-stream']],
});

await $send->({
    type   => 'http.response.body',
    file   => '/path/to/file.bin',  # Server streams efficiently
    # offset => 0,                   # Optional: start offset
    # length => 1000,                # Optional: byte count
});
# Note: 'more' is ignored for file/fh - implicitly complete
```

### Complete HTTP Example

```perl
use strict;
use warnings;
use Future::AsyncAwait;
use experimental 'signatures';
use JSON::PP;

my $app = async sub ($scope, $receive, $send) {
    die "Unsupported scope type: $scope->{type}"
        if $scope->{type} ne 'http';

    my $method = $scope->{method};
    my $path   = $scope->{path};

    if ($path eq '/' && $method eq 'GET') {
        my $json = encode_json({ message => 'Hello!' });

        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [
                ['content-type', 'application/json'],
                ['content-length', length($json)],
            ],
        });

        await $send->({
            type => 'http.response.body',
            body => $json,
        });
    }
    else {
        await $send->({
            type    => 'http.response.start',
            status  => 404,
            headers => [['content-type', 'text/plain']],
        });
        await $send->({
            type => 'http.response.body',
            body => 'Not Found',
        });
    }
};

$app;
```

## WebSocket Protocol

### WebSocket Scope

When `$scope->{type}` is `"websocket"`:

```perl
{
    type         => 'websocket',
    http_version => '1.1',
    scheme       => 'ws',              # or 'wss'
    path         => '/ws/chat',
    query_string => 'room=general',
    headers      => [...],             # Handshake headers
    subprotocols => ['chat', 'json'],  # From Sec-WebSocket-Protocol
    client       => ['192.168.1.1', 54321],
    server       => ['0.0.0.0', 5000],
}
```

### WebSocket Event Flow

1. Receive `websocket.connect`
2. Send `websocket.accept` (or `websocket.close` to reject)
3. Loop: receive messages, send responses
4. Handle `websocket.disconnect` to clean up

### WebSocket Events

**Receive events:**
- `websocket.connect` - Client wants to connect
- `websocket.receive` - Message from client (`text` or `bytes`)
- `websocket.disconnect` - Client disconnected (`code`, `reason`)

**Send events:**
- `websocket.accept` - Accept connection (optional: `subprotocol`, `headers`)
- `websocket.send` - Send message (`text` or `bytes`)
- `websocket.close` - Close connection (`code`, `reason`)

### Complete WebSocket Echo Example

```perl
use strict;
use warnings;
use Future::AsyncAwait;
use experimental 'signatures';

async sub app ($scope, $receive, $send) {
    die "Unsupported scope type: $scope->{type}"
        if $scope->{type} ne 'websocket';

    # Wait for connection request
    my $event = await $receive->();
    die "Expected websocket.connect"
        if $event->{type} ne 'websocket.connect';

    # Accept the connection
    await $send->({ type => 'websocket.accept' });

    # Message loop
    while (1) {
        my $msg = await $receive->();

        if ($msg->{type} eq 'websocket.receive') {
            # Echo back
            if (defined $msg->{text}) {
                await $send->({
                    type => 'websocket.send',
                    text => "Echo: $msg->{text}",
                });
            }
            elsif (defined $msg->{bytes}) {
                await $send->({
                    type  => 'websocket.send',
                    bytes => $msg->{bytes},
                });
            }
        }
        elsif ($msg->{type} eq 'websocket.disconnect') {
            last;  # Client disconnected
        }
    }
}

$app;
```

### Rejecting WebSocket Connections

```perl
# Check auth before accepting
my $event = await $receive->();  # websocket.connect

my $token = _get_header($scope, 'authorization');
unless (valid_token($token)) {
    await $send->({
        type   => 'websocket.close',
        code   => 4001,
        reason => 'Unauthorized',
    });
    return;
}

await $send->({ type => 'websocket.accept' });
```

### Common Close Codes

- `1000` - Normal closure
- `1001` - Going away (server shutdown)
- `1008` - Policy violation
- `1011` - Server error
- `4000-4999` - Application-specific codes

## Server-Sent Events (SSE) Protocol

SSE enables server-to-client streaming over HTTP. The server detects SSE requests when `Accept: text/event-stream` header is present.

### SSE Scope

When `$scope->{type}` is `"sse"`:

```perl
{
    type         => 'sse',
    http_version => '1.1',
    method       => 'GET',
    scheme       => 'http',
    path         => '/events',
    headers      => [...],
    # ... same structure as HTTP
}
```

### SSE Events

**Send events:**
- `sse.start` - Begin SSE stream (`status`, `headers`)
- `sse.send` - Send event (`data`, `event`, `id`, `retry`)

**Receive events:**
- `sse.disconnect` - Client disconnected

### SSE Message Format

`sse.send` fields:
- `data` (required) - Event payload (string, auto-encoded if hashref)
- `event` (optional) - Event type name
- `id` (optional) - Event ID for reconnection
- `retry` (optional) - Reconnect delay in milliseconds

### Complete SSE Example

```perl
use strict;
use warnings;
use Future::AsyncAwait;
use experimental 'signatures';

async sub app ($scope, $receive, $send) {
    die "Unsupported scope type: $scope->{type}"
        if $scope->{type} ne 'sse';

    # Start SSE stream
    await $send->({
        type    => 'sse.start',
        status  => 200,
        headers => [['cache-control', 'no-cache']],
    });

    # Watch for disconnection in background
    my $disconnected = 0;
    my $watch = async sub {
        while (1) {
            my $event = await $receive->();
            if ($event->{type} eq 'sse.disconnect') {
                $disconnected = 1;
                return;
            }
        }
    };
    my $watch_future = $watch->();

    # Send events
    my $count = 0;
    while (!$disconnected && $count < 10) {
        await $send->({
            type  => 'sse.send',
            event => 'tick',
            data  => "Count: $count",
            id    => $count,
        });
        $count++;

        # Wait 1 second - get loop from your app context in production
        # await $loop->delay_future(after => 1);
        sleep(1);  # Blocking - for demo only!
    }

    $watch_future->cancel if $watch_future->can('cancel');
}

$app;
```

### SSE with JSON Data

```perl
use JSON::PP;

await $send->({
    type  => 'sse.send',
    event => 'update',
    data  => encode_json({ users => \@users, count => scalar @users }),
    id    => $event_id++,
});
```

### Rejecting Non-SSE Requests

If you want an endpoint that's HTTP-only (not SSE), reject SSE scope:

```perl
if ($scope->{type} eq 'sse') {
    await $send->({ type => 'sse.start', status => 406 });
    return;
}
```

## Lifespan Protocol

Lifespan events handle application startup and shutdown. Use for initializing database pools, loading configuration, or cleanup.

### Lifespan Scope

When `$scope->{type}` is `"lifespan"`:

```perl
{
    type  => 'lifespan',
    pagi  => { version => '0.1', spec_version => '0.1' },
    state => {},  # Shared with request scopes
}
```

### Lifespan Events

**Receive events:**
- `lifespan.startup` - Server is starting
- `lifespan.shutdown` - Server is stopping

**Send events:**
- `lifespan.startup.complete` - App ready to accept connections
- `lifespan.startup.failed` - Startup failed (`message`)
- `lifespan.shutdown.complete` - Cleanup finished
- `lifespan.shutdown.failed` - Cleanup failed (`message`)

### Complete Lifespan Example

```perl
use strict;
use warnings;
use Future::AsyncAwait;
use experimental 'signatures';

async sub app ($scope, $receive, $send) {
    if ($scope->{type} eq 'lifespan') {
        await handle_lifespan($scope, $receive, $send);
    }
    elsif ($scope->{type} eq 'http') {
        await handle_http($scope, $receive, $send);
    }
    else {
        die "Unsupported scope type: $scope->{type}";
    }
}

async sub handle_lifespan ($scope, $receive, $send) {
    while (1) {
        my $event = await $receive->();

        if ($event->{type} eq 'lifespan.startup') {
            eval {
                # Initialize resources
                $scope->{state}{db} = DBI->connect(...);
                $scope->{state}{started} = time();
            };

            if ($@) {
                await $send->({
                    type    => 'lifespan.startup.failed',
                    message => "Startup error: $@",
                });
                return;
            }

            await $send->({ type => 'lifespan.startup.complete' });
        }
        elsif ($event->{type} eq 'lifespan.shutdown') {
            eval {
                # Cleanup resources
                $scope->{state}{db}->disconnect if $scope->{state}{db};
            };

            await $send->({ type => 'lifespan.shutdown.complete' });
            return;
        }
    }
}

async sub handle_http ($scope, $receive, $send) {
    # Access shared state from lifespan
    my $db = $scope->{state}{db};
    my $uptime = time() - $scope->{state}{started};

    await $send->({
        type    => 'http.response.start',
        status  => 200,
        headers => [['content-type', 'text/plain']],
    });
    await $send->({
        type => 'http.response.body',
        body => "Server uptime: ${uptime}s",
    });
}

$app;
```

### State Sharing

The `$scope->{state}` hashref is:
- Created during lifespan scope
- Shallow-copied to each request scope
- Use for sharing database pools, config, caches

## Multi-Protocol Applications

Real applications often handle multiple protocols in one app.

### Dispatcher Pattern

```perl
use strict;
use warnings;
use Future::AsyncAwait;
use experimental 'signatures';

async sub app ($scope, $receive, $send) {
    my $type = $scope->{type};

    if ($type eq 'lifespan') {
        await handle_lifespan($scope, $receive, $send);
    }
    elsif ($type eq 'http') {
        await handle_http($scope, $receive, $send);
    }
    elsif ($type eq 'websocket') {
        await handle_websocket($scope, $receive, $send);
    }
    elsif ($type eq 'sse') {
        await handle_sse($scope, $receive, $send);
    }
    else {
        die "Unsupported scope type: $type";
    }
}

# Implement each handler...

$app;
```

### Routing by Path

```perl
async sub handle_http ($scope, $receive, $send) {
    my $method = $scope->{method};
    my $path   = $scope->{path};

    if ($path eq '/' && $method eq 'GET') {
        await send_home($scope, $receive, $send);
    }
    elsif ($path =~ m{^/api/} && $method eq 'POST') {
        await handle_api($scope, $receive, $send);
    }
    else {
        await send_404($send);
    }
}

async sub handle_websocket ($scope, $receive, $send) {
    my $path = $scope->{path};

    if ($path eq '/ws/chat') {
        await chat_handler($scope, $receive, $send);
    }
    elsif ($path eq '/ws/notifications') {
        await notification_handler($scope, $receive, $send);
    }
    else {
        # Reject unknown WebSocket paths
        my $event = await $receive->();  # websocket.connect
        await $send->({
            type   => 'websocket.close',
            code   => 4004,
            reason => 'Not Found',
        });
    }
}
```

## Running PAGI Applications

### pagi-server CLI

```bash
# Basic usage
pagi-server ./app.pl --port 5000

# With options
pagi-server ./app.pl \
    --host 0.0.0.0 \
    --port 8080 \
    --workers 4 \
    --access-log /var/log/access.log

# TLS
pagi-server ./app.pl \
    --port 443 \
    --ssl-cert /path/to/cert.pem \
    --ssl-key /path/to/key.pem

# Production (daemonize)
pagi-server ./app.pl \
    --port 8080 \
    --workers 8 \
    --daemonize \
    --pid /var/run/myapp.pid \
    --user www-data \
    --group www-data
```

### Common Options

| Option | Description |
|--------|-------------|
| `-p, --port` | Port to listen on (default: 5000) |
| `-h, --host` | Host to bind (default: 127.0.0.1) |
| `-w, --workers` | Number of worker processes |
| `-a, --app` | Path to app file |
| `-I, --lib` | Add to @INC |
| `-q, --quiet` | Suppress startup messages |
| `--access-log` | Access log file path |
| `--log-level` | debug, info, warn, error |
| `--timeout` | Request timeout in seconds |
| `--max-requests` | Restart worker after N requests |
| `-D, --daemonize` | Run in background |
| `--pid` | PID file path |
| `--user` | Drop privileges to user |
| `--group` | Drop privileges to group |
| `-v, --version` | Show version |

### Signal Handling

- `SIGTERM` / `SIGINT` - Graceful shutdown
- `SIGHUP` - Graceful restart (reload app)
- `SIGTTIN` - Increase workers by 1
- `SIGTTOU` - Decrease workers by 1

## Common Patterns

### Helper: Get Header Value

```perl
sub get_header ($scope, $name) {
    $name = lc($name);
    for my $h (@{$scope->{headers} // []}) {
        return $h->[1] if lc($h->[0]) eq $name;
    }
    return;
}

# Usage
my $content_type = get_header($scope, 'Content-Type');
my $auth = get_header($scope, 'Authorization');
```

### Helper: Parse Query String

```perl
sub parse_query ($query_string) {
    my %params;
    for my $pair (split /&/, $query_string // '') {
        my ($key, $value) = split /=/, $pair, 2;
        $key   = URI::Escape::uri_unescape($key   // '');
        $value = URI::Escape::uri_unescape($value // '');
        $params{$key} = $value;
    }
    return \%params;
}

# Usage
my $params = parse_query($scope->{query_string});
```

### JSON Response Helper

```perl
use JSON::PP;

async sub json_response ($send, $data, $status = 200) {
    my $json = encode_json($data);

    await $send->({
        type    => 'http.response.start',
        status  => $status,
        headers => [
            ['content-type', 'application/json'],
            ['content-length', length($json)],
        ],
    });

    await $send->({
        type => 'http.response.body',
        body => $json,
    });
}
```

## Common Pitfalls

### 1. Forgetting to Check Scope Type

**Wrong:**
```perl
async sub app ($scope, $receive, $send) {
    await $send->({ type => 'http.response.start', ... });  # Crash on WebSocket!
}
```

**Right:**
```perl
async sub app ($scope, $receive, $send) {
    die "Unsupported" if $scope->{type} ne 'http';
    await $send->({ type => 'http.response.start', ... });
}
```

### 2. Not Handling http.disconnect

**Wrong:**
```perl
my $body = '';
while (1) {
    my $event = await $receive->();
    $body .= $event->{body};
    last unless $event->{more};  # Never handles disconnect
}
```

**Right:**
```perl
my $body = '';
while (1) {
    my $event = await $receive->();
    if ($event->{type} eq 'http.disconnect') {
        return;  # Client gone
    }
    $body .= $event->{body} // '';
    last unless $event->{more};
}
```

### 3. Blocking the Event Loop

**Wrong:**
```perl
my $result = `curl http://slow-api.com`;  # Blocks everything!
```

**Right:**
```perl
# For blocking I/O, use a worker pool or run_blocking:
my $result = await $loop->run_child(
    command => ['curl', '-s', 'http://slow-api.com'],
)->get;

# Or with IO::Async::HTTP (if available):
# my $result = await $http->do_request(uri => 'http://slow-api.com');
```

### 4. Forgetting UTF-8 Encoding

**Wrong:**
```perl
body => "Привет"  # Raw Unicode - will corrupt
```

**Right:**
```perl
use Encode;

body => encode_utf8("Привет")  # Properly encoded bytes
```

### 5. WebSocket: Not Waiting for connect Event

**Wrong:**
```perl
await $send->({ type => 'websocket.accept' });  # No connect received!
```

**Right:**
```perl
my $event = await $receive->();
die "Expected connect" if $event->{type} ne 'websocket.connect';
await $send->({ type => 'websocket.accept' });
```
