# 05 – SSE Broadcaster

Streams `text/event-stream` data by emitting:
- `sse.start` (replaces `http.response.start` for SSE).
- Multiple `sse.send` events with UTF-8 text payloads.
- Stops early if `sse.disconnect` arrives.

## Quick Start

**1. Start the server:**

```bash
pagi-server --app examples/05-sse-broadcaster/app.pl --port 5000
```

**2. Demo with curl:**

```bash
# Subscribe to SSE stream (events arrive periodically)
curl -N -v -H "Accept: text/event-stream" http://localhost:5000/   
# => event: time
# => data: Current time: 2024-01-15 10:30:00
# =>
# => event: time
# => data: Current time: 2024-01-15 10:30:01
# => ...

# Press Ctrl+C to disconnect
```

**3. Or use JavaScript in browser console:**

```javascript
const es = new EventSource('http://localhost:5000/');
es.addEventListener('time', (e) => console.log('Time:', e.data));
es.onerror = () => console.log('Connection lost');
```

## Spec References

- SSE scope/events – `PAGI::Spec::Www`
