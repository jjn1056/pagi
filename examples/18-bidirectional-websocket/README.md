# 18 – Bidirectional WebSocket (send and receive at once)

A WebSocket app is **full-duplex**: `$receive` (client → server) and `$send`
(server → client) are independent, so a handler can do both *at the same time*.
After accepting the connection this one runs **two concurrent branches**:

- **incoming** – read client messages and echo them back, uppercased.
- **outgoing** – push an unsolicited server `tick` every second, with no prompting.

You see the server's ticks interleaved with echoes of whatever you type — both
directions live at once.

## The pattern

It's the tree-of-futures idea applied to a single connection: the handler node
**branches** into two children the loop turns concurrently, joined with
`wait_any`:

```perl
my $incoming = (async sub { ... await $receive->() ... })->();   # client -> server
my $outgoing = (async sub { ... await $send->(...) ... })->();   # server -> client
await Future->wait_any($incoming, $outgoing);   # a disconnect ends incoming -> cancels outgoing
```

`$send` and `$receive` never block each other: one branch can sit in
`await $receive->()` while the other is in `await Future::IO->sleep` then
`$send`. Concurrent sends from both branches are serialized into whole frames by
the server.

(The app handles only the `websocket` scope and declines `lifespan` by raising —
the reference server logs one "lifespan not supported, continuing" line and
proceeds, the canonical idiom for a stateless app. See `PAGI::Spec::Lifespan`.)

## Quick Start

```bash
pagi-server --app examples/18-bidirectional-websocket/app.pl --port 5018
```

From an uninstalled PAGI-Server checkout, add `-I /path/to/PAGI-Server/lib`:

```bash
perl -I /path/to/PAGI-Server/lib /path/to/PAGI-Server/bin/pagi-server \
  --app examples/18-bidirectional-websocket/app.pl --port 5018
```

Connect with a **WebSocket-aware** client — not `curl` or `socat`, which can't
speak WebSocket (it needs the HTTP `Upgrade` handshake and client-side frame
masking that raw TCP tools don't do). With
[`websocat`](https://github.com/vi/websocat):

```bash
websocat ws://localhost:5018/
# server tick #1            <- arrives on its own every second
hello                       <- you type this
you said: HELLO             <- echoed back, uppercased
# server tick #2
# server tick #3
```

Or straight from a browser console, nothing to install:

```js
let ws = new WebSocket('ws://localhost:5018/');
ws.onmessage = e => console.log(e.data);   // server ticks + your echoes
ws.onopen    = () => ws.send('hello');
```

The `tick` lines keep arriving whether or not you type — that's the outgoing
branch running concurrently with the incoming one.

## Spec References

- WebSocket scope and events – `PAGI::Spec::Www`
- Concurrent branches as a tree of futures – `PAGI::EventLoops`
