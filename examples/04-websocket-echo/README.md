# 04 – WebSocket Echo

Handles the WebSocket protocol:
1. Waits for `websocket.connect`.
2. Sends `websocket.accept` to complete the handshake.
3. Echoes each message back via `websocket.send`: text as text, binary as binary.
4. Stops when `websocket.disconnect` arrives (the client closed or left), or
   when the client sends `bye`.

The echo loop runs in `$conn->run_until_end`; the Close goes out after it,
only if the client is still connected. So a `bye` ends the session from the
server's side with `websocket.close` 1000, and a client that closed or left
gets nothing more. Afterwards the app logs how the session ended, read from
the connection: `disconnect_reason` for an abnormal end, `close_code` for a
client's polite close.

## Quick Start

**1. Start the server:**

```bash
pagi-server --app examples/04-websocket-echo/app.pl --port 5000
```

**2. Demo with websocat:**

```bash
# Install websocat if needed
brew install websocat        # macOS
# or: cargo install websocat  # with Rust

# Connect and send messages
websocat ws://localhost:5000/
# Type: Hello
# => Hello
# Type: PAGI WebSocket!
# => PAGI WebSocket!
# Type: bye
# (the server closes the connection with code 1000)
```

**3. Or use JavaScript in browser console:**

```javascript
const ws = new WebSocket('ws://localhost:5000/');
ws.onmessage = (e) => console.log('Received:', e.data);
ws.onopen = () => ws.send('Hello from browser!');
```

## Spec References

- WebSocket scope & events – `PAGI::Spec::Www`
- `run_until_end`, `is_connected` – `PAGI::Spec::Www`, "Connection Object Interface"
