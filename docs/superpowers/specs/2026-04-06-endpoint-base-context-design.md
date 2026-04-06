# Endpoint Base Class Context Integration

## Problem

The `PAGI::Endpoint::Router` now injects `$ctx` (a `PAGI::Context` subclass)
into handlers. But the three endpoint base classes —
`PAGI::Endpoint::HTTP`, `PAGI::Endpoint::WebSocket`, and
`PAGI::Endpoint::SSE` — still construct protocol objects directly and pass
them to user-defined methods with the old signatures (`($req, $res)`,
`($ws)`, `($sse)`).

This means users writing endpoint subclasses get a different handler
signature depending on whether they use the Router or the base classes.
The two systems should be consistent.

## Goals

- All user-facing handler/callback methods receive `$ctx` as the first
  argument (after `$self`).
- Replace protocol-specific factory methods (`request_class`,
  `response_class`, `websocket_class`, `sse_class`) with `context_class`.
- Match the pattern already established in `Endpoint::Router`.

## Non-Goals

- Changing the internal protocol object APIs (`PAGI::Request`,
  `PAGI::Response`, `PAGI::WebSocket`, `PAGI::SSE`).
- Changing raw PAGI apps that use `($scope, $receive, $send)` directly.

## PAGI::Endpoint::HTTP

### Current API

```perl
# to_app constructs Request + Response, calls dispatch($req, $res)
# dispatch routes to verb methods: $self->get($req, $res)

async sub get { my ($self, $req, $res) = @_; ... }
async sub post { my ($self, $req, $res) = @_; ... }
```

Factory methods: `request_class`, `response_class`.

### New API

```perl
async sub get { my ($self, $ctx) = @_; ... }
async sub post { my ($self, $ctx) = @_; ... }
```

Factory method: `context_class` (defaults to `'PAGI::Context'`).

### Changes

**`context_class`** replaces `request_class` and `response_class`:

```perl
sub context_class { 'PAGI::Context' }
```

**`to_app`** constructs Context instead of Request/Response. The
`Module::Load` import and `load()` calls for `request_class`/`response_class`
are removed — Context handles lazy-loading protocol classes internally.

```perl
sub to_app {
    my ($class) = @_;
    my $context_class = $class->context_class;

    return async sub {
        my ($scope, $receive, $send) = @_;

        my $type = $scope->{type} // 'http';
        croak "Expected http scope, got '$type'" unless $type eq 'http';

        require PAGI::Context;
        my $endpoint = $class->new;
        my $ctx = $context_class->new($scope, $receive, $send);

        await $endpoint->dispatch($ctx);
    };
}
```

**`dispatch`** receives `$ctx` and passes it to verb methods:

```perl
async sub dispatch {
    my ($self, $ctx) = @_;
    my $http_method = lc($ctx->method // 'GET');

    if ($http_method eq 'options') {
        if ($self->can('options')) {
            return await $self->options($ctx);
        }
        my $allow = join(', ', $self->allowed_methods);
        await $ctx->response->header('Allow', $allow)->empty;
        return;
    }

    if ($http_method eq 'head' && !$self->can('head') && $self->can('get')) {
        $http_method = 'get';
    }

    if ($self->can($http_method)) {
        return await $self->$http_method($ctx);
    }

    my $allow = join(', ', $self->allowed_methods);
    await $ctx->response->header('Allow', $allow)
              ->status(405)
              ->text("405 Method Not Allowed");
}
```

**Remove** `request_class` and `response_class` methods.

## PAGI::Endpoint::WebSocket

### Current API

```perl
# to_app constructs WebSocket, calls handle($ws, $scope, $send)
# handle calls lifecycle callbacks with $ws

async sub on_connect { my ($self, $ws) = @_; ... }
async sub on_receive { my ($self, $ws, $data) = @_; ... }
sub on_disconnect { my ($self, $ws, $code, $reason) = @_; ... }
```

Factory method: `websocket_class`.

### New API

```perl
async sub on_connect { my ($self, $ctx) = @_; ... }
async sub on_receive { my ($self, $ctx, $data) = @_; ... }
sub on_disconnect { my ($self, $ctx, $code, $reason) = @_; ... }
```

Factory method: `context_class` (defaults to `'PAGI::Context'`).

### Changes

**`context_class`** replaces `websocket_class`:

```perl
sub context_class { 'PAGI::Context' }
```

**`to_app`** constructs Context:

```perl
sub to_app {
    my ($class) = @_;
    my $context_class = $class->context_class;

    return async sub {
        my ($scope, $receive, $send) = @_;

        my $type = $scope->{type} // '';
        croak "Expected websocket scope, got '$type'"
            unless $type eq 'websocket';

        my $endpoint = $class->new;
        my $ctx = $context_class->new($scope, $receive, $send);

        await $endpoint->handle($ctx);
    };
}
```

**`handle`** receives `$ctx`, extracts `$ws` internally for the message
loop, and passes `$ctx` to all lifecycle callbacks:

```perl
async sub handle {
    my ($self, $ctx) = @_;
    my $ws = $ctx->websocket;

    if ($self->can('on_connect')) {
        await $self->on_connect($ctx);
    } else {
        await $ws->accept;
    }

    if ($self->can('on_disconnect')) {
        $ws->on_close(sub {
            my ($code, $reason) = @_;
            $self->on_disconnect($ctx, $code, $reason);
        });
    }

    eval {
        if ($self->can('on_receive')) {
            my $encoding = $self->encoding;

            if ($encoding eq 'json') {
                await $ws->each_json(async sub {
                    my ($data) = @_;
                    await $self->on_receive($ctx, $data);
                });
            } elsif ($encoding eq 'bytes') {
                await $ws->each_bytes(async sub {
                    my ($data) = @_;
                    await $self->on_receive($ctx, $data);
                });
            } else {
                await $ws->each_text(async sub {
                    my ($data) = @_;
                    await $self->on_receive($ctx, $data);
                });
            }
        } else {
            await $ws->run;
        }
    };
    die $@ if $@;
}
```

**Remove** `websocket_class` method.

## PAGI::Endpoint::SSE

### Current API

```perl
# to_app constructs SSE, calls handle($sse)
# handle calls lifecycle callbacks with $sse

async sub on_connect { my ($self, $sse) = @_; ... }
sub on_disconnect { my ($self, $sse) = @_; ... }
```

Factory method: `sse_class`.

### New API

```perl
async sub on_connect { my ($self, $ctx) = @_; ... }
sub on_disconnect { my ($self, $ctx) = @_; ... }
```

Factory method: `context_class` (defaults to `'PAGI::Context'`).

### Changes

**`context_class`** replaces `sse_class`:

```perl
sub context_class { 'PAGI::Context' }
```

**`to_app`** constructs Context:

```perl
sub to_app {
    my ($class) = @_;
    my $context_class = $class->context_class;

    return async sub {
        my ($scope, $receive, $send) = @_;

        my $type = $scope->{type} // '';
        croak "Expected sse scope, got '$type'" unless $type eq 'sse';

        my $endpoint = $class->new;
        my $ctx = $context_class->new($scope, $receive, $send);

        await $endpoint->handle($ctx);
    };
}
```

**`handle`** receives `$ctx`, extracts `$sse` internally:

```perl
async sub handle {
    my ($self, $ctx) = @_;
    my $sse = $ctx->sse;

    my $keepalive = $self->keepalive_interval;
    if ($keepalive > 0) {
        $sse->keepalive($keepalive);
    }

    if ($self->can('on_disconnect')) {
        $sse->on_close(sub {
            $self->on_disconnect($ctx);
        });
    }

    if ($self->can('on_connect')) {
        await $self->on_connect($ctx);
    } else {
        await $sse->start;
    }

    await $sse->run;
}
```

**Remove** `sse_class` method.

## Testing

Each endpoint base class has or needs tests updated:

- Tests for `Endpoint::HTTP` verb dispatch with `$ctx`
- Tests for `Endpoint::WebSocket` lifecycle callbacks with `$ctx`
- Tests for `Endpoint::SSE` lifecycle callbacks with `$ctx`
- Tests for `context_class` override on each
- Existing tests updated to new signatures

## Examples

Update `examples/endpoint-demo/app.pl` — the main example that uses all
three endpoint base classes directly.

## Migration

This is a breaking change to the endpoint base class handler signatures.
All existing subclasses of `Endpoint::HTTP`, `Endpoint::WebSocket`, and
`Endpoint::SSE` must update:

- `($self, $req, $res)` → `($self, $ctx)` with `$ctx->request` / `$ctx->response`
- `($self, $ws)` → `($self, $ctx)` with `$ctx->websocket`
- `($self, $ws, $data)` → `($self, $ctx, $data)` with `$ctx->websocket`
- `($self, $sse)` → `($self, $ctx)` with `$ctx->sse`
- `request_class` / `response_class` → `context_class`
- `websocket_class` → `context_class`
- `sse_class` → `context_class`
