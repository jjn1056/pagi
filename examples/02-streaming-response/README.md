# 02 – Streaming Response with Disconnect Handling

Shows how to:
- Drain the incoming `http.request` body (if any) before replying.
- Send multiple `http.response.body` chunks with `more => 1`.
- Emit `http.response.trailers` when `trailers => 1` was advertised.
- Run the body in `$conn->run_until_end`, so it stops at its next wait when
  the client leaves, and send the end of the body and the trailer only when
  the body finished: a response cut short does not claim to be complete.

## Quick Start

**1. Start the server:**

```bash
pagi-server --app examples/02-streaming-response/app.pl --port 5000
```

**2. Demo with curl:**

```bash
# Watch chunks stream in (one per second)
curl -N http://localhost:5000/
# => Chunk 1
# => Chunk 2
# => Chunk 3

# Test disconnect handling - press Ctrl+C during streaming
curl -N http://localhost:5000/
# (press Ctrl+C: the server logs "Client left early: client_closed"
#  and sends no end of body or trailer)
```

## Spec References

- HTTP events, trailers, disconnect – `PAGI::Spec::Www`
- Cancellation semantics – `PAGI::Spec`
