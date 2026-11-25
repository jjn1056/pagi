# 21 – SSE Endings (every way a stream can end)

An event stream ends in one of three ways, and the app tells them apart after
`$conn->run_until_end`:

- **the feed ran to its end** with the client still there: send `sse.close`;
- **the scope ended first**: the client left, a server limit fired, the
  server shut down, or the app gave up itself. `disconnect_reason` says which;
  nothing more is sent;
- **the work failed**: the call dies with the error. Let it escape (the server
  logs it and ends the stream), or catch it, as this example does, to send an
  error event of your own while the client is still there.

## The pattern

```perl
await $conn->run_until_end(async sub {
    while (defined(my $item = await $feed->next)) {
        await $send->({ type => 'sse.send', data => $item });
    }
});
return unless $conn->is_connected;    # the scope ended: disconnect_reason says why
await $send->({ type => 'sse.close' });
```

The example adds a `deadline` of its own (`$conn->abort` ends the scope like
any other end) and an optional `eval` around the call for the failure case.

## Quick Start

Start the server with short limits, so the timeouts happen in seconds:

```bash
pagi-server --app examples/21-sse-endings/app.pl --port 5021 \
  --sse-idle-timeout 2 --write-timeout 2
```

From an uninstalled PAGI-Server checkout, add `-I /path/to/PAGI-Server/lib`.
Each case is a query string; the app logs how each stream ended:

```bash
curl -N -H 'Accept: text/event-stream' 'http://localhost:5021/?n=3'          # feed completed: 3 ticks
curl -N -H 'Accept: text/event-stream' 'http://localhost:5021/'              # Ctrl-C: ... client_closed
curl -N -H 'Accept: text/event-stream' 'http://localhost:5021/?n=5&fail=2'   # feed failed ...; an error event
curl -N -H 'Accept: text/event-stream' 'http://localhost:5021/?every=3'      # ... idle_timeout
curl -N -H 'Accept: text/event-stream' 'http://localhost:5021/?deadline=2'   # ... app_abort (gave up after 2s)
```

Stop the server while a stream is open to see `server_shutdown`. A client
that stops reading (`?size=65536&every=0` from a client that never reads)
ends with `write_timeout`, or `idle_timeout` if that limit fires first: with
nothing moving, whichever timer is shorter wins.

## Spec References

- `run_until_end`, `is_connected`, Standard Disconnect Reasons – `PAGI::Spec::Www`
- SSE scope and events – `PAGI::Spec::Www`
