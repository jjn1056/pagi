# 20 – Streaming Echo (an HTTP body in and out at once)

An HTTP request body and its response body are both streams, and a handler
can work on both at the same time. Here the client uploads numbers, one per
line, and the server:

- **in** – answers each number with the running total as soon as it arrives;
- **out** – sends a progress `tick` every second, on its own, whatever the
  client is doing.

When the upload ends, the ticker stops and the summary goes out. If the client
leaves first, both stop and nothing more is sent.

## The pattern

Both directions run inside one `run_until_end` on the connection object,
joined with `wait_any`. Data goes out inside it; the ending goes out after
it, only if the client is still there:

```perl
await $conn->run_until_end(sub { Future->wait_any($read->(), $tick->()) });

return unless $conn->is_connected;    # the client left: nothing more to send
await $send->({ type => 'http.response.body', body => "done: ...\n", more => 0 });
```

The upload ending finishes the read branch, and `wait_any` cancels the ticker.
The client leaving ends the scope, and `run_until_end` cancels both. The two
branches send at the same time without a queue between them: since Www 0.7
the server keeps a scope's sends in the order they were called.

It's the HTTP twin of `18-bidirectional-websocket`.

## Quick Start

```bash
pagi-server --app examples/20-streaming-echo/app.pl --port 5020
```

From an uninstalled PAGI-Server checkout, add `-I /path/to/PAGI-Server/lib`:

```bash
perl -I /path/to/PAGI-Server/lib /path/to/PAGI-Server/bin/pagi-server \
  --app examples/20-streaming-echo/app.pl --port 5020
```

To watch both directions live, use the included client, which reads while it
writes:

```bash
perl examples/20-streaming-echo/client.pl 5020
#   0.2s  -> 5
#   0.2s  <- got 5, total 5
#   1.0s  <- tick 1: 1 numbers so far     <- on its own, between uploads
#   1.7s  -> 10
#   1.7s  <- got 10, total 15
#   2.0s  <- tick 2: 2 numbers so far
#   3.0s  <- tick 3: 2 numbers so far
#   3.4s  -> -3
#   3.4s  <- got -3, total 12
#   4.0s  -> (end of upload)
#   4.0s  <- done: 3 numbers, total 12
# (the timings vary a little: a fourth tick can land just as the upload ends)

perl examples/20-streaming-echo/client.pl 5020 leave   # hangs up after "10"
# the server logs: running total stopped after 2 numbers: client_closed
```

`curl` works too, but over HTTP/1.1 it prints the replies in bursts, each time
it sends more of its upload, so the order shows but not the timing:

```bash
(echo 5; sleep 1.5; echo 10; sleep 1.5; echo -3) | curl -sN -T - http://localhost:5020/
```

## Spec References

- `run_until_end`, `is_connected` – `PAGI::Spec::Www`, "Connection Object Interface"
- Sends Are Sequential – `PAGI::Spec::Www`
