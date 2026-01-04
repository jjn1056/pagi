# 14 – Lifespan Hooks via PAGI::Utils

Minimal app that uses `PAGI::Utils::handle_lifespan` for startup/shutdown hooks
and serves a plain-text HTTP response.

## Requirements

- Perl 5.42+
- `Future::AwaitAsync`

## Quick Start

```bash
pagi-server --app examples/14-lifespan-utils/app.pl --port 5000
```

## Demo

```bash
curl http://localhost:5000/
# => Hello from PAGI!
```

Stop the server with Ctrl+C to see the shutdown hook log message.

## Spec References

- Lifespan events – `docs/specs/lifespan.mkdn`
- HTTP events – `docs/specs/www.mkdn`
