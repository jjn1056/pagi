# 13 – Flow Control (conflation under backpressure)

A high-frequency SSE feed that **conflates** under backpressure: it reads
`$scope->{'pagi.transport'}` and, when the client falls behind, *skips* stale
readings so a slow client always gets the freshest one instead of a growing
backlog. `pagi.transport` is the server-side analogue of the browser's
`WebSocket.bufferedAmount`.

This is the conflation recipe from `PAGI::Cookbook` ("Flow Control"), shown over
SSE so you can try it with `curl`. The cookbook's version uses WebSocket; the
pattern is identical.

## Quick Start

**1. Start the server:**

```bash
pagi-server --app examples/13-flow-control/app.pl --port 5000
```

**2. Fast client — the feed stays healthy (nothing skipped):**

```bash
curl -N -H "Accept: text/event-stream" http://localhost:5000/
```

The server log shows `[healthy] sent=… skipped=0`.

**3. Slow client — watch it conflate.** Throttle the reader so it falls behind
(here with `pv`, ~2 KB/sec). After a few seconds the client's read backlog
builds and the server log flips to `CONFLATING`, with the skipped count
climbing:

```bash
curl -N -H "Accept: text/event-stream" http://localhost:5000/ | pv -qL 2000
```

```
[CONFLATING] sent=12 skipped=137 buffered=33792
```

The client keeps receiving fresh readings; the stale ones in between are dropped
rather than queued. (No `pv`? Any slow consumer works — e.g. pipe into a script
that sleeps between reads.)

## How it works

`buffered_amount` reports the bytes queued for the client but not yet on the
wire. The app skips a send whenever that exceeds half of `high_water_mark`, so it
never even reaches the point where the server would block the send. The same
handle also offers `on_high_water` / `on_drain` callbacks for sources you can't
pace by skipping — see the cookbook.

## Spec References

- Transport flow control – `PAGI::Spec::Www` ("Transport Flow Control")
- Flow Control recipes – `PAGI::Cookbook`
- SSE scope/events – `PAGI::Spec::Www`
