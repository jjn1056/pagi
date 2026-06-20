# 17 – Event Middleware (delivering your own events through `$receive`)

The **composable** way to surface your own events: a middleware owns the event
source and folds its events into the `$receive` the app sees, so the app's `tick`
events arrive on the **same channel** as the protocol events (`http.request`,
`http.disconnect`). The app never reaches into shared state for a source — it just
awaits the next event and switches on `type`.

This is the "right way" companion to **`14-periodic-events`**, which exposes the
same source the *easy* way — a hub the handlers pull from with `$hub->next_tick`.

## Why deliver through `$receive`?

Because the events ride **in the `$receive` stream** as ordinary typed events,
every other middleware in the stack can act on them — log them, gate them,
transform them, fold in more — exactly as it does for protocol events. A source a
handler pulls from a shared object is a **side-channel** the middleware pipeline
can't see. Events on `$receive` are first-class to that pipeline; method calls on
a state-stashed object are not.

The app is also fully **decoupled** from the source: it depends only on the event
contract (a `type` and some fields), so the source can be swapped — an in-memory
ticker here, a Redis-backed channel in production — without touching a line of the
app. This is exactly the shape `PAGI::Middleware::Channels` uses to fan events
across workers and hosts.

## How it fits together

```
with_ticks($app)            # the middleware: owns the ticker (lifespan), wraps $receive
   └── $app                 # pure: await $receive->(); switch on $event->{type}
```

- **The middleware** (`with_ticks`) owns the source. On `lifespan` startup it
  starts a `Future::Selector`-held ticker, rooted in its own frame; for each
  request it wraps `$receive` to race the next protocol event against the next
  tick (without cancelling the long-lived `$receive`).
- **The app** is pure. It sends a streaming response, then loops:
  `await $receive->()` and switches on `type` — a `tick` and an `http.disconnect`
  arrive the same way.

## Routes

- `GET /` – a long-running NDJSON stream. Each background tick arrives through
  `$receive` as a `{type=>'tick'}` event and is emitted as one line
  (`{"tick":N}`), until the client disconnects.

## Quick Start

```bash
pagi-server --app examples/17-event-middleware/app.pl --port 5017
```

From an uninstalled PAGI-Server checkout, add `-I /path/to/PAGI-Server/lib`:

```bash
perl -I /path/to/PAGI-Server/lib /path/to/PAGI-Server/bin/pagi-server \
  --app examples/17-event-middleware/app.pl --port 5017
```

Watch the stream (one line per tick, ~every 2s, until you Ctrl-C):

```bash
curl -N localhost:5017/
# => {"tick":1}
# => {"tick":2}
# => {"tick":3}
```

## Scope: one node, one process

Like `14-periodic-events`, the ticker is in-memory and **per process**: in
multi-worker (`--workers N`) or multi-node deployments each process has its own.
To deliver one event source across processes, the source behind the middleware
must be an external broker — see `PAGI::Middleware::Channels` with its Redis
backend, which is this exact `$receive`-wrapping pattern with a cross-process
source.

## Spec References

- Writing your own event source, easy way and right way – `PAGI::EventLoops`
- The easy-way counterpart – `examples/14-periodic-events`
- Lifespan scope and shared state – `PAGI::Spec::Lifespan`
