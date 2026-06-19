# 15 – Embedded IO::Async

Demonstrates **embedding `PAGI::Server` inside a larger IO::Async program** (the
"D1" pattern from `PAGI::EventLoops`). The caller owns the loop, runs its own
periodic activity on the same loop, and hands the server in via
`$loop->add` / `listen->get` / `$loop->run`.

Because there is no `pagi-server` wrapper, **the embedder must wire the
`Future::IO` backend** with `use Future::IO::Impl::IOAsync` — the server cannot
do it for you.

## Owning vs. Embedding

| Mode | Who creates the loop? | Who calls `$loop->run`? | Future::IO wiring |
|------|-----------------------|-------------------------|--------------------|
| `pagi-server` (owning) | The server | The server | Automatic |
| Embedded (this example) | **Your program** | **Your program** | `use Future::IO::Impl::IOAsync` |

The embedding pattern is three lines:

```perl
$loop->add($server);   # register the server as an IO::Async::Notifier
$server->listen->get;  # bind the port (no loop iteration needed yet)
$loop->run;            # your program drives the loop
```

`listen->get` binds the port synchronously via `get` on the returned Future,
so you know the server is ready before the host app prints its "listening" line.

## Quick Start

**1. Start the server:**

```bash
perl examples/15-embedded-ioasync/server.pl
```

From an uninstalled PAGI-Server checkout, add `-I /path/to/PAGI-Server/lib`:

```bash
perl -I /path/to/PAGI-Server/lib examples/15-embedded-ioasync/server.pl
```

**2. Demo with curl:**

```bash
curl -s localhost:5015/ ; echo
# => Hello from a PAGI::Server embedded in an IO::Async app
```

While the server runs you should see `[host app] tick at ...` warnings on
stderr every 2 seconds — before the request, during it, and after — confirming
that the host-app timer and the HTTP server share the same event loop without
interfering.

## Spec References

- Embedding pattern (D1) – `PAGI::EventLoops`
- `PAGI::Server` loop integration – `PAGI::Server` / `LOOP INTEROPERABILITY`
