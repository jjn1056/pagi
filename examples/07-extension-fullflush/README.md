# 07 – Extension-Aware Streaming with FullFlush

Demonstrates how to:
- Check for extension support via `scope->{extensions}{fullflush}`
- Use `http.fullflush` event during streaming to force immediate TCP buffer flush
- Only send extension events when the server advertises support

The fullflush extension is useful for real-time streaming scenarios where you want each chunk delivered to the client immediately rather than waiting for TCP buffer fill or Nagle's algorithm.

## Quick Start

**1. Start the server:**

```bash
pagi-server --app examples/07-extension-fullflush/app.pl --port 5000
```

**2. Demo with curl:**

```bash
# Watch real-time streaming with immediate flush
curl -N http://localhost:5000/
# => Chunk 1 (flushed immediately)
# => Chunk 2 (flushed immediately)
# => ...

# Each chunk appears instantly rather than being buffered
```

**Note:** The difference from regular streaming is most noticeable with small chunks that would normally be buffered by TCP.

## Spec References

- Extension mechanism – `PAGI::Spec::Extensions`
- Fullflush example – `PAGI::Spec::Extensions` (the `fullflush` section)
