# 14 – Periodic Events

An in-app event source built on `Future::IO`. A background loop produces a
"tick" result every interval and delivers it to whoever is currently listening.
This shows that you can model your own events as Futures and compose them with
protocol events — without ever naming an event loop.

The timer is a `Future::IO->sleep`, not an `IO::Async` timer, so the app does
not assume any particular loop: it runs on whatever loop the server provides.

## Routes

- `GET /` – returns the current tick `count` immediately.
- `GET /next` – *listens* for the next tick (long-poll). It pushes a fresh
  `Future` onto the waiter list and awaits it; the background source resolves
  that Future on the next tick. The await is non-blocking, so other requests
  are served while this one waits.

## Quick Start

**1. Start the server:**

```bash
# Installed server:
pagi-server --app examples/14-periodic-events/app.pl --port 5014

# Or run against an uninstalled checkout of PAGI-Server:
perl -I ~/Desktop/PAGI-Server/lib ~/Desktop/PAGI-Server/bin/pagi-server \
  --app examples/14-periodic-events/app.pl --port 5014
```

**2. Demo with curl:**

```bash
curl -s localhost:5014/ ; echo
# => {"count":3,"hint":"GET /next to wait for the next tick"}

time curl -s localhost:5014/next ; echo
# => {"tick":4,"at":1781893422}   (blocks up to ~2s, then wakes on the tick)

curl -s localhost:5014/ ; echo
# => {"count":4,...}   (count advanced while you waited)
```

## Spec References

- Defining your own events – `PAGI::Spec::Extensions` ("Defining your own events")
- Loop-agnostic timing and event sources – `PAGI::EventLoops`
