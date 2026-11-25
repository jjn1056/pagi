# 05 – SSE Broadcaster

Streams `text/event-stream` data by emitting:
- `sse.start` (replaces `http.response.start` for SSE).
- Multiple `sse.send` events with UTF-8 text payloads.
- The events run in `$conn->run_until_end`, so the stream stops at its next
  wait when the client leaves.
- `sse.close` only when every event went: a stream cut short does not claim
  to be complete.

## Quick Start

**1. Start the server:**

```bash
pagi-server --app examples/05-sse-broadcaster/app.pl --port 5000
```

**2. Demo with curl:**

```bash
# Subscribe to SSE stream (events arrive periodically)
curl -N -v -H "Accept: text/event-stream" http://localhost:5000/   
# => event: tick
# => data: 1
# =>
# => event: tick
# => data: 2
# =>
# => event: done
# => data: finished

# Press Ctrl+C to disconnect
```

**3. Or use JavaScript in browser console:**

```javascript
const es = new EventSource('http://localhost:5000/');
es.addEventListener('tick', (e) => console.log('tick:', e.data));
es.addEventListener('done', (e) => { console.log('done:', e.data); es.close(); });
es.onerror = () => console.log('Connection lost');
```

## Spec References

- SSE scope/events – `PAGI::Spec::Www`
