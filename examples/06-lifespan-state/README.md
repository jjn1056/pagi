# 06 – Lifespan & Shared State

Single PAGI app that handles both `lifespan` and `http` scopes:
- Stores a greeting in `scope->{state}` during `lifespan.startup`.
- Reuses that state when handling HTTP requests.
- Responds to `lifespan.shutdown` cleanly.

## Quick Start

**1. Start the server:**

```bash
pagi-server --app examples/06-lifespan-state/app.pl --port 5000
```

You should see startup message in the server logs indicating lifespan initialization.

**2. Demo with curl:**

```bash
# Request uses state initialized during lifespan.startup
curl http://localhost:5000/
# => Hello from lifespan state!

# Make multiple requests - all use the same shared state
curl http://localhost:5000/
curl http://localhost:5000/
```

**3. Test shutdown:**

Press Ctrl+C to stop the server and observe the clean shutdown sequence in the logs.

## Spec References

- Lifespan events – `PAGI::Spec::Lifespan`
- HTTP events – `PAGI::Spec::Www`
