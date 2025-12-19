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
