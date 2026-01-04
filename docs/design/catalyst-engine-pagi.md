# Catalyst::Engine::PAGI Design (Refined)

## Goal

Run existing Catalyst apps under PAGI with zero changes. Enable async actions (WebSocket, SSE) by adding `:Async` attribute to specific actions.

## Key Insight: Scope Type is the Signal

No complex route detection needed. The PAGI scope type tells us everything:

| Scope Type | Handling | Worker Behavior |
|------------|----------|-----------------|
| `http` | Blocking (like Starman) | One request per worker |
| `websocket` | Async (event loop) | Many connections per worker |
| `sse` | Async (event loop) | Many connections per worker |

```
Request arrives at PAGI worker
         │
         ▼
    ┌─────────────────┐
    │ scope->{type}?  │
    └────────┬────────┘
             │
    ┌────────┼────────┐
    ▼        ▼        ▼
  http   websocket   sse
    │        │        │
    ▼        └───┬────┘
 Blocking        │
 (like Starman)  ▼
    │         Async
    │     (event loop)
    ▼            │
 Catalyst        ▼
 dispatch     Catalyst
    │         dispatch
    ▼         + PAGI
 Send via     primitives
 PAGI             │
                  ▼
              Action uses
              $c->pagi->websocket
              or $c->pagi->sse
```

## Components

### 1. PAGI::App::Catalyst (Main Entry Point)

```perl
package PAGI::App::Catalyst;

use strict;
use warnings;
use Future::AsyncAwait;
use Scalar::Util qw(blessed);
use Plack::Util;

sub new {
    my ($class, %args) = @_;

    my $app_class = $args{class} or die "class is required";

    # Load Catalyst app if not already loaded
    Plack::Util::load_class($app_class);

    # Ensure PAGI plugin is loaded
    unless ($app_class->registered_plugins('PAGI')) {
        warn "Consider adding 'PAGI' to your Catalyst plugins for full support\n";
    }

    return bless {
        class => $app_class,
    }, $class;
}

sub to_app {
    my $self = shift;
    my $app_class = $self->{class};

    return async sub ($scope, $receive, $send) {

        # Route based on scope type
        if ($scope->{type} eq 'http') {
            return await _handle_http($app_class, $scope, $receive, $send);
        }
        elsif ($scope->{type} eq 'websocket') {
            return await _handle_async($app_class, $scope, $receive, $send);
        }
        elsif ($scope->{type} eq 'sse') {
            return await _handle_async($app_class, $scope, $receive, $send);
        }
        elsif ($scope->{type} eq 'lifespan') {
            return await _handle_lifespan($app_class, $scope, $receive, $send);
        }
        else {
            die "Unsupported scope type: $scope->{type}";
        }
    };
}

# Blocking HTTP - same behavior as Starman
async sub _handle_http {
    my ($app_class, $scope, $receive, $send) = @_;

    # Build PSGI environment
    my $env = _scope_to_env($scope);

    # Collect request body (blocking is fine here)
    if (_has_body($scope)) {
        $env->{'psgi.input'} = await _collect_body($receive);
    }

    # Inject PAGI primitives for optional async upgrade
    $env->{'pagi.scope'}   = $scope;
    $env->{'pagi.receive'} = $receive;
    $env->{'pagi.send'}    = $send;

    # Run Catalyst (blocks the worker - same as Starman)
    my $c = $app_class->prepare(env => $env);

    # Check if action wants async handling (streaming, long-poll)
    my $action = $c->action;
    my $is_async = $action && $action->attributes->{Async};

    if ($is_async) {
        # Inject PAGI primitives
        $c->pagi_scope($scope);
        $c->pagi_receive($receive);
        $c->pagi_send($send);

        # Dispatch - action returns Future
        my $result = $c->dispatch;

        if (blessed($result) && $result->isa('Future')) {
            await $result;
        }

        # Action handled response, we're done
        return if $scope->{'pagi.response.sent'};
    }
    else {
        # Normal blocking dispatch
        $c->dispatch;
    }

    # Finalize and send response
    $c->finalize;
    await _send_catalyst_response($c, $send);
}

# Async protocols (WebSocket, SSE) - must use event loop
async sub _handle_async {
    my ($app_class, $scope, $receive, $send) = @_;

    my $env = _scope_to_env($scope);

    # Always inject PAGI primitives for async protocols
    $env->{'pagi.scope'}   = $scope;
    $env->{'pagi.receive'} = $receive;
    $env->{'pagi.send'}    = $send;

    my $c = $app_class->prepare(env => $env);

    # Inject into context
    $c->pagi_scope($scope);
    $c->pagi_receive($receive);
    $c->pagi_send($send);

    # Verify action is async-capable
    my $action = $c->action;
    unless ($action && $action->attributes->{Async}) {
        # No matching async action - send error
        if ($scope->{type} eq 'websocket') {
            await $send->({
                type   => 'websocket.close',
                code   => 4004,
                reason => 'No async handler for this path',
            });
        }
        else {
            await _send_error($send, 404, 'Not Found');
        }
        return;
    }

    # Dispatch async action
    my $result = $c->dispatch;

    if (blessed($result) && $result->isa('Future')) {
        await $result;
    }
}

# Lifespan events
async sub _handle_lifespan {
    my ($app_class, $scope, $receive, $send) = @_;

    while (1) {
        my $event = await $receive->();

        if ($event->{type} eq 'lifespan.startup') {
            # Could call Catalyst setup hooks here
            await $send->({ type => 'lifespan.startup.complete' });
        }
        elsif ($event->{type} eq 'lifespan.shutdown') {
            # Could call Catalyst teardown hooks here
            await $send->({ type => 'lifespan.shutdown.complete' });
            return;
        }
    }
}

# Helper: Convert PAGI scope to PSGI env
sub _scope_to_env {
    my ($scope) = @_;

    my %env = (
        REQUEST_METHOD  => $scope->{method} // 'GET',
        SCRIPT_NAME     => '',
        PATH_INFO       => $scope->{path} // '/',
        REQUEST_URI     => $scope->{raw_path} // $scope->{path} // '/',
        QUERY_STRING    => $scope->{query_string} // '',
        SERVER_NAME     => $scope->{server}[0] // 'localhost',
        SERVER_PORT     => $scope->{server}[1] // 80,
        SERVER_PROTOCOL => 'HTTP/' . ($scope->{http_version} // '1.1'),
        REMOTE_ADDR     => $scope->{client}[0] // '127.0.0.1',
        REMOTE_PORT     => $scope->{client}[1] // 0,

        'psgi.version'      => [1, 1],
        'psgi.url_scheme'   => $scope->{scheme} // 'http',
        'psgi.input'        => do { open my $fh, '<', \''; $fh },
        'psgi.errors'       => \*STDERR,
        'psgi.multithread'  => 0,
        'psgi.multiprocess' => 1,
        'psgi.run_once'     => 0,
        'psgi.streaming'    => 1,
        'psgi.nonblocking'  => 1,

        'pagi.scope_type'   => $scope->{type},
    );

    # Convert headers
    for my $header (@{$scope->{headers} // []}) {
        my ($name, $value) = @$header;
        my $key = uc($name);
        $key =~ s/-/_/g;

        if ($key eq 'CONTENT_TYPE') {
            $env{CONTENT_TYPE} = $value;
        }
        elsif ($key eq 'CONTENT_LENGTH') {
            $env{CONTENT_LENGTH} = $value;
        }
        else {
            my $env_key = "HTTP_$key";
            if (exists $env{$env_key}) {
                $env{$env_key} .= ", $value";
            }
            else {
                $env{$env_key} = $value;
            }
        }
    }

    return \%env;
}

sub _has_body {
    my ($scope) = @_;
    my $method = $scope->{method} // 'GET';
    return $method =~ /^(POST|PUT|PATCH)$/i;
}

async sub _collect_body {
    my ($receive) = @_;

    my $body = '';
    while (1) {
        my $event = await $receive->();
        last if $event->{type} eq 'http.disconnect';
        $body .= $event->{body} // '';
        last unless $event->{more_body};
    }

    open my $fh, '<', \$body;
    return $fh;
}

async sub _send_catalyst_response {
    my ($c, $send) = @_;

    my $res = $c->response;

    # Build headers array
    my @headers;
    for my $name ($res->headers->header_field_names) {
        for my $value ($res->headers->header($name)) {
            push @headers, [lc($name), $value];
        }
    }

    await $send->({
        type    => 'http.response.start',
        status  => $res->status // 200,
        headers => \@headers,
    });

    my $body = $res->body;

    if (ref $body eq 'GLOB' || (blessed($body) && $body->can('read'))) {
        # Streaming body
        while (1) {
            my $chunk;
            my $read = $body->read($chunk, 65536);
            last unless $read;
            await $send->({
                type => 'http.response.body',
                body => $chunk,
                more => 1,
            });
        }
        $body->close if $body->can('close');
        await $send->({
            type => 'http.response.body',
            body => '',
            more => 0,
        });
    }
    else {
        # Simple body
        await $send->({
            type => 'http.response.body',
            body => $body // '',
        });
    }
}

async sub _send_error {
    my ($send, $status, $message) = @_;

    await $send->({
        type    => 'http.response.start',
        status  => $status,
        headers => [['content-type', 'text/plain']],
    });
    await $send->({
        type => 'http.response.body',
        body => $message,
    });
}

1;
```

### 2. Catalyst::Plugin::PAGI

```perl
package Catalyst::Plugin::PAGI;

use Moose::Role;
use namespace::autoclean;

# PAGI primitives storage
has 'pagi_scope'   => (is => 'rw', predicate => 'has_pagi');
has 'pagi_receive' => (is => 'rw');
has 'pagi_send'    => (is => 'rw');

# Lazy helper object
has '_pagi_helper' => (
    is      => 'ro',
    lazy    => 1,
    builder => '_build_pagi_helper',
);

sub _build_pagi_helper {
    my $c = shift;
    return undef unless $c->has_pagi;

    require Catalyst::PAGI::Context;
    return Catalyst::PAGI::Context->new(
        scope   => $c->pagi_scope,
        receive => $c->pagi_receive,
        send    => $c->pagi_send,
    );
}

# Main accessor
sub pagi {
    my $c = shift;
    return $c->_pagi_helper;
}

# Detect if running under PAGI
sub is_pagi {
    my $c = shift;
    return $c->has_pagi || $c->req->env->{'pagi.scope_type'};
}

# Get scope type
sub pagi_scope_type {
    my $c = shift;
    return $c->pagi_scope->{type} if $c->has_pagi;
    return $c->req->env->{'pagi.scope_type'};
}

1;
```

### 3. Catalyst::PAGI::Context (Helper Object)

```perl
package Catalyst::PAGI::Context;

use Moose;
use Future::AsyncAwait;
use PAGI::WebSocket;
use PAGI::SSE;
use PAGI::Response;

has 'scope'   => (is => 'ro', required => 1);
has 'receive' => (is => 'ro', required => 1);
has 'send'    => (is => 'ro', required => 1);

has '_websocket' => (is => 'rw');
has '_sse'       => (is => 'rw');
has '_response'  => (is => 'rw');

# Get WebSocket helper (lazy, cached)
sub websocket {
    my $self = shift;

    die "Not a WebSocket connection"
        unless $self->scope->{type} eq 'websocket';

    return $self->_websocket //= PAGI::WebSocket->new(
        $self->scope,
        $self->receive,
        $self->send,
    );
}

# Get SSE helper (lazy, cached)
sub sse {
    my $self = shift;

    # SSE can work over HTTP or dedicated SSE scope
    return $self->_sse //= PAGI::SSE->new(
        $self->scope,
        $self->receive,
        $self->send,
    );
}

# Get Response helper for async HTTP (streaming, etc)
sub response {
    my $self = shift;

    return $self->_response //= PAGI::Response->new(
        $self->scope,
        $self->send,
    );
}

# Direct scope access
sub type { shift->scope->{type} }
sub path { shift->scope->{path} }

# Raw primitives for advanced use
sub raw_receive { shift->receive }
sub raw_send    { shift->send }

__PACKAGE__->meta->make_immutable;
1;
```

### 4. Catalyst::Action::Async

```perl
package Catalyst::Action::Async;

use Moose;
use Scalar::Util qw(blessed);

extends 'Catalyst::Action';

# Validate at dispatch time
before 'execute' => sub {
    my ($self, $controller, $c, @args) = @_;

    unless ($c->is_pagi) {
        die sprintf(
            "Action '%s' has :Async attribute but not running under PAGI. "
            . "Use pagi-server instead of starman.",
            $self->reverse
        );
    }
};

# Return value handling - preserve Future
around 'execute' => sub {
    my ($orig, $self, $controller, $c, @args) = @_;

    my $result = $self->$orig($controller, $c, @args);

    # If action returns a Future, return it for awaiting
    if (blessed($result) && $result->isa('Future')) {
        return $result;
    }

    return $result;
};

__PACKAGE__->meta->make_immutable;
1;
```

### 5. Catalyst::ControllerRole::PAGI

```perl
package Catalyst::ControllerRole::PAGI;

use Moose::Role;
use Catalyst::Action::Async;

# Register :Async attribute
sub _parse_Async_attr {
    my ($self, $c, $name, $value) = @_;
    return (Async => 1);
}

# Use our action class for async actions
around 'create_action' => sub {
    my ($orig, $self, %args) = @_;

    if ($args{attributes}{Async}) {
        $args{class} = 'Catalyst::Action::Async';
    }

    return $self->$orig(%args);
};

1;
```

## Usage

### myapp.psgi

```perl
#!/usr/bin/env perl
use strict;
use warnings;
use MyApp;

# Auto-detect PAGI vs traditional PSGI server
if ($ENV{PAGI_SERVER}) {
    require PAGI::App::Catalyst;
    PAGI::App::Catalyst->new(class => 'MyApp')->to_app;
}
else {
    MyApp->psgi_app;
}
```

Or simpler - just always use PAGI adapter (works for both):

```perl
#!/usr/bin/env perl
use PAGI::App::Catalyst;
PAGI::App::Catalyst->new(class => 'MyApp')->to_app;
```

### lib/MyApp.pm

```perl
package MyApp;
use Moose;
use Catalyst;

extends 'Catalyst';

__PACKAGE__->config(name => 'MyApp');

__PACKAGE__->setup(qw/
    -Debug
    ConfigLoader
    Static::Simple
    PAGI
/);

1;
```

### lib/MyApp/Controller/Root.pm (Blocking - Unchanged)

```perl
package MyApp::Controller::Root;
use Moose;
BEGIN { extends 'Catalyst::Controller' }

__PACKAGE__->config(namespace => '');

# Existing blocking action - no changes needed
sub index :Path('/') :Args(0) {
    my ($self, $c) = @_;

    # This blocks the worker - same as Starman
    my $users = $c->model('DB::User')->all;

    $c->stash(
        users    => $users,
        template => 'index.tt',
    );
}

# Existing API endpoint - blocking, no changes
sub api_users :Path('/api/users') :Args(0) {
    my ($self, $c) = @_;

    my @users = $c->model('DB::User')->all;

    $c->res->content_type('application/json');
    $c->res->body(JSON::encode_json(\@users));
}

1;
```

### lib/MyApp/Controller/Chat.pm (New Async Actions)

```perl
package MyApp::Controller::Chat;
use Moose;
use Future::AsyncAwait;

BEGIN { extends 'Catalyst::Controller' }

# Enable :Async attribute
with 'Catalyst::ControllerRole::PAGI';

# Regular blocking action for the chat page
sub index :Path('/chat') :Args(0) {
    my ($self, $c) = @_;

    my $recent = $c->model('DB::Message')->recent(50);

    $c->stash(
        messages => $recent,
        template => 'chat/index.tt',
    );
}

# WebSocket endpoint - async, many connections per worker
async sub websocket :Path('/chat/ws') :Args(0) :Async {
    my ($self, $c) = @_;

    my $ws = $c->pagi->websocket;
    my $user = $c->user;  # From auth middleware

    # Accept the WebSocket connection
    await $ws->accept;

    # Join chat room
    my $room = $c->model('Chat')->join($user->id);

    # Main message loop
    while (1) {
        # Wait for either: incoming message OR broadcast from others
        my $event = await Future->wait_any(
            $ws->receive,
            $room->next_message,
        );

        if (!defined $event || $event->{type} eq 'websocket.disconnect') {
            # Client disconnected
            $room->leave($user->id);
            last;
        }

        if ($event->{type} eq 'websocket.receive') {
            # Message from this client - broadcast to room
            my $text = $event->{text};

            # Save to database (async)
            await $c->model('DB::Message')->create_async({
                user_id => $user->id,
                text    => $text,
            });

            # Broadcast
            $room->broadcast({
                user => $user->name,
                text => $text,
                time => time(),
            });
        }
        elsif ($event->{type} eq 'room.message') {
            # Broadcast from another user - send to this client
            await $ws->send_json($event->{data});
        }
    }
}

# SSE endpoint for notifications
async sub notifications :Path('/notifications') :Args(0) :Async {
    my ($self, $c) = @_;

    my $sse = $c->pagi->sse;
    my $user = $c->user;

    await $sse->start;

    # Subscribe to user's notification channel
    my $sub = $c->model('Notifications')->subscribe($user->id);

    while (my $notif = await $sub->next) {
        await $sse->send_event(
            event => $notif->{type},
            data  => $notif->{payload},
        );
    }
}

# Async HTTP streaming (large file generation)
async sub export :Path('/chat/export') :Args(0) :Async {
    my ($self, $c) = @_;

    my $res = $c->pagi->response;

    $res->content_type('text/csv');
    $res->header('Content-Disposition' => 'attachment; filename="chat.csv"');

    await $res->stream(async sub ($writer) {
        await $writer->write("timestamp,user,message\n");

        # Stream from database cursor
        my $cursor = $c->model('DB::Message')->cursor;

        while (my $row = await $cursor->next) {
            my $line = sprintf("%s,%s,%s\n",
                $row->timestamp,
                $row->user->name,
                $row->text,
            );
            await $writer->write($line);
        }
    });
}

1;
```

## How It Works

### Request Flow: Blocking (unchanged behavior)

```
1. HTTP request arrives
2. PAGI worker receives it
3. PAGI::App::Catalyst->_handle_http():
   - Converts scope to PSGI env
   - Collects request body
   - Calls $app_class->prepare(env => $env)
   - Calls $c->dispatch  ← BLOCKS HERE (same as Starman)
   - Calls $c->finalize
   - Sends response via PAGI
4. Worker ready for next request
```

### Request Flow: Async (WebSocket)

```
1. WebSocket upgrade request arrives
2. PAGI completes HTTP upgrade internally
3. PAGI::App::Catalyst->_handle_async():
   - Converts scope to PSGI env
   - Injects PAGI primitives into $c
   - Calls $c->dispatch
   - Action uses $c->pagi->websocket
   - Action returns Future (long-running)
   - Worker stays responsive (event loop)
4. When WebSocket closes, action's Future resolves
5. Worker continues handling other connections
```

## Configuration

### Multi-worker deployment

```bash
# 8 workers, each can handle:
# - Many concurrent WebSocket connections (async)
# - One blocking HTTP request at a time (like Starman)
pagi-server --app myapp.psgi --workers 8 --port 5000
```

### With preloading (faster startup, copy-on-write)

```bash
pagi-server --app myapp.psgi --workers 8 --port 5000 --preload
```

## Testing

### Blocking actions (unchanged)

```perl
use Test::More;
use Catalyst::Test 'MyApp';

my $res = request('/');
ok($res->is_success);
like($res->content, qr/Welcome/);
```

### Async actions (need async test client)

```perl
use Test::More;
use Future::AsyncAwait;
use PAGI::Test::Client;

my $client = PAGI::Test::Client->new(app => 'MyApp');

# Test WebSocket
my $ws = await $client->websocket('/chat/ws');
await $ws->send_text('Hello');
my $msg = await $ws->receive;
is($msg->{text}, 'Echo: Hello');
await $ws->close;

done_testing;
```

## Migration Checklist

1. **Install**: `cpanm PAGI Catalyst::Plugin::PAGI`

2. **Update MyApp.pm**: Add `PAGI` to plugins

3. **Update myapp.psgi**: Use `PAGI::App::Catalyst` wrapper

4. **Replace server**: `pagi-server` instead of `starman`

5. **Add async actions**: Use `:Async` attribute and `$c->pagi`

6. **Test**: Verify blocking actions still work, test new async actions

## Future Enhancements

1. **Catalyst::Helper::PAGI** - Generate async controller boilerplate

2. **Catalyst::Plugin::PAGI::PubSub** - Built-in pubsub for chat/notifications

3. **Hot reload** - Reload Catalyst app without dropping WebSocket connections

4. **Metrics** - Track async vs blocking action performance
