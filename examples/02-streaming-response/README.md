# 02 – Streaming Response with Disconnect Handling

Shows how to:
- Drain the incoming `http.request` body (if any) before replying.
- Send multiple `http.response.body` chunks with `more => 1`.
- Emit `http.response.trailers` when `trailers => 1` was advertised.
- Watch for `{ type => 'http.disconnect' }` while streaming and stop if the client drops.

## Quick Start

**1. Start the server:**

```bash
pagi-server --app examples/02-streaming-response/app.pl --port 5000
```

**2. Demo with curl:**

```bash
# Watch chunks stream in (one per second)
curl -N http://localhost:5000/
# => Chunk 1 of 5
# => Chunk 2 of 5
# => ...

# Test disconnect handling - press Ctrl+C during streaming
curl -N http://localhost:5000/
# (press Ctrl+C to see server handle disconnect)
```

## Spec References

- HTTP events, trailers, disconnect – `PAGI::Spec::Www`
- Cancellation semantics – `PAGI::Spec`
