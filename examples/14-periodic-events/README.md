# 14 – Periodic Events

A periodic background event source, **rooted in the lifespan scope**. Every
interval the source produces a "tick" and delivers it to whoever is currently
listening. It shows how to model your own events as Futures and run long-lived
background work correctly — without ever naming an event loop.

The key idea: an event-driven app is a **tree of futures**. The source lives in
a `Future::Selector` held by the lifespan handler, which the server keeps alive
for the whole life of the app — so it is a real branch of the tree. Nothing is
pinned in a file-scoped variable, so nothing is silently dropped, and because the
selector propagates failures, a crashing source surfaces (the server logs it)
rather than vanishing.

> **Anti-pattern, for contrast:** starting the source at file scope and keeping
> it alive in an `our` (or a bare `my`, which is worse — it is garbage-collected
> as soon as the app file finishes loading, dying with a cryptic *"lost its
> returning future"* warning). That is a future with no parent in the tree. Give
> it a parent instead: the lifespan scope.

The timer is a `Future::IO->sleep`, not an `IO::Async` timer, so the app does not
assume any particular loop.

## Routes

- `GET /` – returns the current `count` (ticks) and `beats` (the second source)
  immediately.
- `GET /next` – *listens* for the next tick (long-poll): it calls
  `$hub->next_tick` to get a `Future` the background source resolves on the next
  tick, and awaits it. Non-blocking, so other requests are served while this one
  waits.
- `GET /stream` – a **long-running stream**: it holds the connection open and
  emits one NDJSON line (`{"tick":N}`) every time the background source ticks,
  until the client disconnects. The handler produces nothing on its own — it just
  relays events from a source *outside* the request code. This is the pattern for
  streaming apps (live feeds, progress, notifications) that react to events
  happening elsewhere.

**Two background sources, one selector.** A fast `ticker` (every 2s) drives
`count`, `/next`, and `/stream`; a slower `heartbeat` (every 5s) drives `beats`.
Both run on a single `Future::Selector`, which multiplexes them and makes a
failure in either surface rather than vanish. Adding a third source is one more
`$selector->add`.

## Sharing state with the background source

The source and the request handlers rendezvous through a small **hub object**
stored once in `$scope->{state}` at startup. This is deliberate. Each request
scope gets a **shallow copy** of the lifespan `state`: the top-level keys are
private to that copy, but the *values* (object references) are shared. So we
store one hub and reach it through that shared reference — we never *replace* a
top-level `state` key (e.g. `$state->{count}++` in a request would change only
that request's copy and silently desync the rest). The hub encapsulates the
rule: it owns its waiter list and only ever mutates it in place.

## Quick Start

**1. Start the server:**

```bash
pagi-server --app examples/14-periodic-events/app.pl --port 5014
```

From an uninstalled PAGI-Server checkout, add `-I /path/to/PAGI-Server/lib`:

```bash
perl -I /path/to/PAGI-Server/lib /path/to/PAGI-Server/bin/pagi-server \
  --app examples/14-periodic-events/app.pl --port 5014
```

**2. Demo with curl:**

```bash
curl -s localhost:5014/ ; echo
# => {"count":1,"beats":0,"hint":"GET /next to wait for the next tick"}

time curl -s localhost:5014/next ; echo
# => {"tick":2}   (blocks up to ~2s, then wakes on the next tick)

curl -s localhost:5014/ ; echo
# => {"count":2,"beats":1,...}   (both sources advanced while you waited)

# Watch the live stream -- one line per tick, until you Ctrl-C:
curl -N localhost:5014/stream
# => {"tick":3}
# => {"tick":4}
# => {"tick":5}      (a new line every ~2s, driven by the background source)
```

## Scope: one node, one process

For teaching, this example deliberately runs as a **single process on a single
node** — that is exactly what makes the in-memory `TickHub` a valid place for the
source and the requests to rendezvous.

The moment there is more than one process, an in-memory hub stops being shared:

- **Multiple workers** (`--workers N`): each worker is a separate process running
  its own lifespan, so each has its own `TickHub` and ticker. A streaming
  connection is pinned to one worker and stays internally consistent, but the
  `count` differs between workers and two clients can land on different ones.
- **Multiple nodes** (e.g. scaling pods on Kubernetes): the same thing across
  hosts — nothing in `$scope->{state}` crosses a process or a machine boundary.

To fan one event source out to every worker and every node, publish through an
external broker instead of an in-memory hub — e.g. `PAGI::Middleware::Channels`
with its Redis backend, which keeps the same `subscribe`/`publish` shape this
example hand-rolls. See `PAGI::EventLoops` for the in-process pattern and where
the broker takes over.

## Spec References

- Writing your own event source – `PAGI::EventLoops` (the chain/tree-of-futures section)
- Lifespan scope and shared state – `PAGI::Spec::Lifespan`
- Defining your own events – `PAGI::Spec::Extensions` ("Defining your own events")
