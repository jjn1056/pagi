# Example 16 — PAGI::Server under a Foreign (EV-backed) Loop

Demonstrates running `PAGI::Server` under an **EV**-backed `IO::Async` loop,
and verifies that `Future::IO` operations actually tick on that loop.

## The diagnostic

The HTTP handler does `await Future::IO->sleep(1)` **before** sending a
response. If the response arrives after ~1 second, `Future::IO` is correctly
driven by the EV loop. If the request hangs, it is not.

## How the wiring works

```perl
BEGIN { $ENV{IO_ASYNC_LOOP} = 'EV' }   # (1) select the EV backend globally
use IO::Async::Loop;
use Future::IO::Impl::IOAsync;          # (2) wire Future::IO to IO::Async
use PAGI::Server;

my $loop   = IO::Async::Loop->new;      # IO::Async::Loop::EV
my $server = PAGI::Server->new(app => $app, port => 5016);
$loop->add($server);
$server->listen->get;   # bind without starting the loop
$loop->run;             # the host app owns the loop
```

Three things must be in place:

1. **`IO_ASYNC_LOOP=EV` (or `BEGIN` block)** — `IO::Async::Loop->new` reads
   this env var and constructs `IO::Async::Loop::EV` instead of the default
   poll/epoll backend.
2. **`Future::IO::Impl::IOAsync`** — loaded by the embedder, this routes all
   `Future::IO` calls (including `Future::IO->sleep`) through the shared
   IO::Async loop, which is now EV-backed.
3. **`$loop->add($server)` before `$server->listen->get`** — `PAGI::Server`
   is an `IO::Async::Notifier`; it must be added to the loop before it binds.

## Observed outcome (SUCCESS)

```
loop backend: IO::Async::Loop::EV
PAGI Server listening on http://127.0.0.1:5016/ (loop: EV, ...)
```

```
$ time curl -s localhost:5016/
PAGI::Server is running under the EV loop; Future::IO ticked

real    0m1.019s
```

Response arrived in ~1.019 s — the `Future::IO->sleep(1)` resolved correctly
on the EV-backed loop. Both server I/O and `Future::IO` are driven by EV.

## Running

```bash
perl examples/16-foreign-loop/server.pl
# In another terminal:
curl localhost:5016/
```

From an uninstalled PAGI-Server checkout, add `-I /path/to/PAGI-Server/lib`:

```bash
perl -I /path/to/PAGI-Server/lib examples/16-foreign-loop/server.pl
```

## See also

- `PAGI::EventLoops` — full embedding guide (D2 section covers EV integration)
- Example 15 (`examples/15-embedded-ioasync/`) — embedding without a foreign
  event loop (plain IO::Async default backend)
