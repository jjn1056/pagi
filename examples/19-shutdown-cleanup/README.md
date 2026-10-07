# 19 – Cleaning Up When the Server Shuts Down

A WebSocket app that keeps a little state per connection (the messages it
received) and saves it when the connection ends:
- Tells a server shutdown (code `1012`, reason `server_shutdown`) from a client
  leaving.
- Saves each session asynchronously (a 0.2 s sleep stands in for a database or
  remote service).
- Prints a summary in `lifespan.shutdown`, which the server sends only after
  every connection's application has returned -- so every session is saved
  before the process exits.

## Quick Start

**1. Start the server:**

```bash
pagi-server --app examples/19-shutdown-cleanup/app.pl --port 5000
```

**2. Connect two clients and type a few lines in each:**

```bash
websocat ws://127.0.0.1:5000/
```

Each line is answered with `noted: N`.

**3. Stop the server** with Ctrl+C. The log shows each session ending with
`server shutdown, code 1012`, then `saved N message(s)` for each, and only then
`shutdown: 2 session(s) saved`.

Close a client yourself instead and its session ends with `client left`.

## Spec References

- Shutdown order – `PAGI::Spec::Lifespan` ("Shutdown - receive event")
- WebSocket close on shutdown – `PAGI::Spec::Www` ("Disconnect - receive event")
