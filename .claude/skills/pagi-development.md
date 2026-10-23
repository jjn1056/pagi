---
name: pagi-development
description: Use when writing raw PAGI applications, understanding the PAGI spec, or debugging PAGI code. Covers HTTP, WebSocket, SSE and Lifespan.
---

# PAGI Development Skill

PAGI (Perl Asynchronous Gateway Interface) is an async successor to PSGI. A
PAGI application is one async coderef that serves HTTP, WebSocket, SSE and
lifespan scopes. This skill covers **raw** PAGI: the protocol itself. The
toolkit built on it (requests, responses, routing, middleware) is PAGI-Tools;
point people to `PAGI::Tools` for that, don't teach it from here.

**The authorities**, which win over anything below: `PAGI::Spec` and
`PAGI::Spec::Www` / `::Lifespan` / `::Extensions` / `::Tls` (the rules),
`PAGI::Tutorial`, `PAGI::Cookbook` (recipes), `PAGI::EventLoops`
(Futures, Future::IO, loops), `PAGI::Upgrading` (spec changes), and the
runnable apps in the PAGI distribution's `examples/`. When in doubt, read the
spec section and say which one.

## Setup

- **Perl 5.24 or later** is required for PAGI, PAGI-Server and PAGI-Tools
  (see "Perl version support" in `PAGI`).
- A raw app needs `Future::AsyncAwait`, and `Future::IO` for timers and I/O.
  To run it: `cpanm PAGI::Server` (add `PAGI::Tools` for the toolkit and for
  `-E development`, which turns on its Lint middleware).
- Syntax: on 5.36+ use `use v5.36;` (not `use 5.36;`, which means 5.360 and
  dies) and signatures. On 5.24-5.35 use `use strict; use warnings;` and
  `my ($scope, $receive, $send) = @_;` (the spec's examples do this).

## The interface

```perl
use strict;
use warnings;
use Future::AsyncAwait;

my $app = async sub {
    my ($scope, $receive, $send) = @_;
    die "Unsupported scope type: $scope->{type}" if $scope->{type} ne 'http';

    await $send->({
        type    => 'http.response.start',
        status  => 200,
        headers => [ [ 'content-type', 'text/plain' ] ],
    });
    await $send->({ type => 'http.response.body', body => "Hello, world!\n", more => 0 });
};

$app;   # the file's last value: a coderef (or an object with to_app)
```

Run it: `pagi-server --app app.pl --port 5000` (or `pagi-server app.pl`).

- **`$scope`** describes the connection: `type` (`http`, `websocket`, `sse`,
  `lifespan`), `pagi` (`version`, `spec_version`), `extensions`, and for
  http/websocket/sse `pagi.connection` (required) and often `pagi.transport`.
  Don't mutate the scope you were handed; pass a copy (`{ %$scope, ... }`)
  down. Your own keys are namespaced (`'myapp.user'`); undotted keys are the
  spec's.
- **`$receive->()`** returns a Future of the next event (`{ type => ... }`).
- **`$send->(\%event)`** returns a Future. **Await every send**: it resolves
  when the server is done with the event (not when the client has it); sends
  are sequential; a send after the client left succeeds as a no-op. Don't
  cancel sends.
- **Unsupported scope types**: die (the server treats a lifespan that dies as
  "lifespan not supported" and carries on).
- **Every response ends with a terminal event**: the last body (`more => 0`),
  a `file`/`fh` body, trailers, `sse.close`, or `websocket.close`/a received
  `websocket.disconnect`. Returning without it is an incomplete response: the
  client sees a truncation, and the server logs it. But if you stop because
  the client left, don't send it.
- If the app returns before `http.response.start` while the client is still
  there, the server sends a 500.

## Receiving, disconnects, cancelling

- Every pending receive resolves with the scope's disconnect event when the
  client goes (`http.disconnect`, `websocket.disconnect`, `sse.disconnect`).
  After the scope ends, receives keep returning that end (bounded by the
  server's `--max-disconnect-receives`).
- **An application may cancel a pending receive**: `Future->wait_any` cancels
  the loser, and that consumes no event; the next receive gets the next one.
  So racing the client against your own events is fine:

  ```perl
  my $first = await Future->wait_any($receive->(), $my_event->());
  ```

- To know about a disconnect without receiving, use `pagi.connection`:
  `$scope->{'pagi.connection'}->is_connected`, `->disconnect_future`,
  `->disconnect_reason`, `->on_disconnect(sub { ... })`. See
  `PAGI::Spec::Www` "Connection State" and Cookbook "Detecting client
  disconnect".

## HTTP

Scope keys you'll use: `method`, `path` (decoded, below `root_path`),
`raw_path` (bytes, percent-encoded; never route on it), `query_string`
(bytes), `headers` (ArrayRef of [name, value], names lower-case),
`root_path`, `scheme`, `http_version`, `client`, `server`, `state`.

Read the body:

```perl
async sub read_body {
    my ($receive) = @_;
    my $body = '';
    while (1) {
        my $event = await $receive->();
        last if $event->{type} ne 'http.request';   # http.disconnect
        $body .= $event->{body} // '';
        last unless $event->{more};
    }
    return $body;
}
```

Respond:

- `http.response.start`: `status`, `headers`, `trailers => 1` if you'll send
  trailers.
- `http.response.body`: `body` (bytes), `more => 1` to stream more chunks,
  `more => 0` for the last. Or one terminal `file` (absolute path) or `fh`
  body, with optional `offset` and `length`; not after `more => 1` chunks.
- `http.response.trailers`: `headers`. Over HTTP/1.1, don't set a
  `content-length` on a response with trailers (the trailers send fails).
- `content-length` is the byte length. Answer HEAD as you would GET; the
  server drops the body. The server owns framing, `Date`, `100 Continue`,
  and its own 400/413/431/500 responses.

## WebSocket

The flow: receive `websocket.connect`, then either **accept** or **refuse**.

- Accept: `websocket.accept` (`subprotocol`, `headers` optional). Then
  `websocket.send` (`text` for characters, `bytes` for binary), receive
  `websocket.receive` (`text` or `bytes`) and `websocket.disconnect` (`code`,
  `reason`).
- **Refuse with an ordinary HTTP response**, before accepting:
  `http.response.start` (status 300 or above) then `http.response.body`. A
  `websocket.close` before accept is an error.
- After accepting you must end with `websocket.close` (`code`, default 1000;
  `reason`) or by receiving `websocket.disconnect`; sends after the close
  fail. Optional `websocket.keepalive` (`interval`, `timeout`) pings.
- Codes: 1000 normal, 1001 going away, 1011 server error, 1012 the server is
  restarting (what PAGI-Server sends on shutdown), 4000-4999 yours.

```perl
my $app = async sub {
    my ($scope, $receive, $send) = @_;
    die "Unsupported scope type: $scope->{type}" if $scope->{type} ne 'websocket';

    await $receive->();                                    # websocket.connect
    unless (authorised($scope)) {
        await $send->({ type => 'http.response.start', status => 401,
            headers => [ [ 'content-type', 'text/plain' ] ] });
        await $send->({ type => 'http.response.body', body => 'Unauthorized' });
        return;
    }
    await $send->({ type => 'websocket.accept' });

    while (1) {
        my $event = await $receive->();
        last if $event->{type} eq 'websocket.disconnect';
        next unless $event->{type} eq 'websocket.receive';
        await $send->({ type => 'websocket.send', text => "echo: " . ($event->{text} // '') });
    }
};
```

## Server-Sent Events

A request is an `sse` scope when its `Accept` header names
`text/event-stream` exactly (q > 0; wildcards don't count), any method, not a
WebSocket upgrade.

- The first receive is `sse.request` (`body`, `more`; one empty event for a
  GET). Then `sse.disconnect` when the client goes.
- Send `sse.start` (`status` default 200, `headers` with the content type),
  then `sse.send` (`data`, a required character string; optional `event`,
  `id`, `retry`), `sse.comment` (`comment`), `sse.keepalive` (`interval`,
  `comment`).
- **End a started stream with `sse.close`** (optional server-side `reason`,
  never sent to the client). Unless the client left first.
- **Refuse with an ordinary HTTP response** before `sse.start`
  (`http.response.start`, `http.response.body`), any status.

```perl
use Future::IO;

my $app = async sub {
    my ($scope, $receive, $send) = @_;
    die "Unsupported scope type: $scope->{type}" if $scope->{type} ne 'sse';

    await $send->({ type => 'sse.start', status => 200,
        headers => [ [ 'content-type', 'text/event-stream' ] ] });

    my $disconnect = (async sub {            # receives sse.request first
        while (1) {
            my $event = await $receive->();
            return $event if $event->{type} eq 'sse.disconnect';
        }
    })->();

    for my $n (1 .. 3) {
        last if $disconnect->is_ready;
        await Future::IO->sleep(1);
        await $send->({ type => 'sse.send', event => 'tick', data => "$n" });
    }

    return if $disconnect->is_ready;         # the client left: no sse.close
    $disconnect->cancel;
    await $send->({ type => 'sse.close' });
};
```

## Lifespan

One `lifespan` scope per process (per worker): receive `lifespan.startup`,
reply `lifespan.startup.complete` (or `.failed` with `message`, which stops
startup); later receive `lifespan.shutdown`, reply
`lifespan.shutdown.complete` (or `.failed`). The scope carries `state`, which
the server copies (shallowly) into each request's scope:

```perl
async sub handle_lifespan {
    my ($scope, $receive, $send) = @_;
    my $state = $scope->{state} //= {};
    while (1) {
        my $event = await $receive->();
        if ($event->{type} eq 'lifespan.startup') {
            $state->{config} = { greeting => 'hello' };    # set containers once
            await $send->({ type => 'lifespan.startup.complete' });
        }
        elsif ($event->{type} eq 'lifespan.shutdown') {
            await $send->({ type => 'lifespan.shutdown.complete' });
            return;
        }
    }
}
```

Requests read `$scope->{state}{config}`. Top-level keys are per copy, so put a
container in `state` at startup and mutate through it; don't replace keys
later. An app that dies on a lifespan scope "doesn't support lifespan", and
the server continues (`--lifespan on` makes that fatal). On shutdown the server
closes connections (WebSockets with 1012), waits for their app calls to
return, then sends `lifespan.shutdown`.

## Several protocols in one app

```perl
my $app = async sub {
    my ($scope, $receive, $send) = @_;
    my $type = $scope->{type};
    return await handle_lifespan($scope, $receive, $send)  if $type eq 'lifespan';
    return await handle_http($scope, $receive, $send)      if $type eq 'http';
    return await handle_websocket($scope, $receive, $send) if $type eq 'websocket';
    return await handle_sse($scope, $receive, $send)       if $type eq 'sse';
    die "Unsupported scope type: $type";
};
```

Middleware is the same shape: a function from app to app that wraps
`$send`/`$receive` or passes a copied scope. Guards that protect HTTP should
cover `sse` too (it is HTTP with a different response shape).

## Event loops and blocking

- PAGI's contract is Futures. Use **`Future::IO`** for sleeps, timers and I/O
  (`await Future::IO->sleep(1)`); `pagi-server` binds Future::IO to its loop
  before loading the app. Don't bind or create a loop in an app or library;
  IO::Async is PAGI-Server's implementation detail.
- Never block: no `sleep`, no blocking DBI/LWP in a handler, never `->get` on
  a Future. Use async clients, or move CPU-heavy work to a worker process or
  job queue. See `PAGI::EventLoops`.
- Background work needs a parent that holds it, such as the lifespan scope; a
  Future started at file scope is reaped ("lost its returning future").

## UTF-8

- `path` is decoded characters; `raw_path`, `query_string`, header values and
  bodies are bytes. Decode what you read; **encode what you send**:
  `body => Encode::encode('UTF-8', $text)` and a byte-length
  `content-length`.
- `websocket.send` and `sse.send`: `text`/`data` take characters (the server
  encodes); `bytes` takes bytes.
- See `PAGI` "UTF-8 HANDLING OVERVIEW".

## Extensions

`$scope->{extensions}` lists what the server offers: `tls` (connection
details; `PAGI::Spec::Tls`) and `fullflush` (`{ type => 'http.fullflush' }`
forces a flush; PAGI::Server advertises it only when configured with
`extensions => { fullflush => {} }`). Check before using an extension.

## Running

`pagi-server [options] [--app] app.pl`. The ones you'll reach for:

| Option | Meaning |
|---|---|
| `-p, --port` / `-o, --host` | listen address (default port 5000) |
| `-w, --workers N` | pre-fork workers |
| `-E, --env development\|production` | mode; development adds PAGI-Tools Lint |
| `--http2` | HTTP/2 (needs Net::HTTP2::nghttp2) |
| `--ssl-cert`, `--ssl-key` | TLS |
| `--lifespan on` | fail if the app declines lifespan |
| `--log-level`, `-q` (errors only), `--log-format text\|json` | diagnostics |
| `--timeout N` | connection idle timeout (default 60) |
| `--request-timeout N` | request stall timeout (default off) |
| `--max-body-size N` | the server answers 413 itself |
| `--shutdown-timeout N` | how long shutdown waits for app calls |
| `--future-xs` | run on Future::XS (needs 0.16 or later) |

`pagi-server --help` and its POD list every option and the signal handling.

## PSGI

PAGI-Tools' `PAGI::App::WrapPSGI` runs a PSGI app under PAGI; it blocks its
worker's loop, so use workers. See `PAGI::PSGI`.

## Pitfalls

1. Not checking the scope type, or not dying on an unknown one.
2. Not awaiting a send.
3. Refusing a WebSocket with `websocket.close`, or an SSE request with
   `sse.start` and an error status: refusals are HTTP responses.
4. Returning without the terminal event (or sending one after the client
   left).
5. Treating the first SSE receive as the disconnect: it is `sse.request`.
6. Sending characters in `body`, or a character-count `content-length`.
7. Blocking: `sleep`, `->get`, blocking clients.
8. Mutating the scope you were handed instead of passing a copy.
9. `use 5.36;` (dies) instead of `use v5.36;`.
