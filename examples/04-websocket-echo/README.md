# 04 – WebSocket Echo

Handles the WebSocket protocol:
1. Waits for `websocket.connect`.
2. Sends `websocket.accept` to complete the handshake.
3. Echoes incoming frames back via `websocket.send`.
4. Stops when `websocket.disconnect` arrives or when `websocket.receive` contains neither `text` nor `bytes`.

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
```

**3. Or use JavaScript in browser console:**

```javascript
const ws = new WebSocket('ws://localhost:5000/');
ws.onmessage = (e) => console.log('Received:', e.data);
ws.onopen = () => ws.send('Hello from browser!');
```

## Spec References

- WebSocket scope & events – `PAGI::Spec::Www`
