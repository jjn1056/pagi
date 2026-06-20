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

- `GET /` – returns the current tick `count` immediately.
- `GET /next` – *listens* for the next tick (long-poll). It pushes a fresh
  `Future` onto the waiter list and awaits it; the background source resolves
  that Future on the next tick. The await is non-blocking, so other requests are
  served while this one waits.

State (`count`, the waiter list) lives in `$scope->{state}`, which the lifespan
handler seeds and every request scope can read.

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
# => {"count":1,"hint":"GET /next to wait for the next tick"}

time curl -s localhost:5014/next ; echo
# => {"tick":2}   (blocks up to ~2s, then wakes on the next tick)

curl -s localhost:5014/ ; echo
# => {"count":2,...}   (count advanced while you waited)
```

## Spec References

- Writing your own event source – `PAGI::EventLoops` (the chain/tree-of-futures section)
- Lifespan scope and shared state – `PAGI::Spec::Lifespan`
- Defining your own events – `PAGI::Spec::Extensions` ("Defining your own events")
