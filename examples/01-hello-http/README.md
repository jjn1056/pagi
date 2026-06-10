# 01 – Hello HTTP

Demonstrates the minimum PAGI HTTP app: accept only `scope->{type} eq 'http'`, send `http.response.start`, then a single `http.response.body` event.

## Quick Start

**1. Start the server:**

```bash
pagi-server --app examples/01-hello-http/app.pl --port 5000
```

**2. Demo with curl:**

```bash
curl http://localhost:5000/
# => Hello from PAGI!
```

## Spec References

- Core scope & application contract – `PAGI::Spec`
- HTTP response events – `PAGI::Spec::Www`
