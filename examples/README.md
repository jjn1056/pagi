# PAGI Examples

These are raw-protocol PAGI applications -- each is a plain `async sub` working
directly with `$scope`/`$receive`/`$send`, using no helper modules. They
illustrate the protocol itself, and what you can build on it, which is what the
`PAGI` distribution is about.

## Start here: build a framework on PAGI

**`mini-framework`** -- a complete little web framework (routing, path
parameters, genuinely non-blocking async dispatch) in about **forty lines** on
raw PAGI, plus an application that uses it. It is the single best demonstration
of why PAGI is a foundation worth building on. If you read one example, read
this one.

## Requirements
- Perl 5.18+ with `Future::AsyncAwait`
- For timers/sleeps: `Future::IO` (loop-agnostic)
- A PAGI server to run them. We use the reference server from the `PAGI-Server`
  distribution: `pagi-server examples/01-hello-http/app.pl --port 5000`

Examples assume you understand the core specification -- see L<PAGI::Tutorial>
and L<PAGI::Spec>.

## Testing the examples

How you poke an example depends on its protocol:

- **HTTP, streaming, SSE** -- `curl`. Add `-N` (unbuffered) for streaming and SSE
  endpoints so you see events as they arrive: `curl -N localhost:5000/`.
- **WebSocket** -- a WebSocket-aware client. `curl` and `socat` **can't** speak
  it: WebSocket needs an HTTP `Upgrade` handshake and client-side frame masking
  that raw TCP tools don't do. Use [`websocat`](https://github.com/vi/websocat):

  ```bash
  websocat ws://localhost:5018/
  ```

  ...or, with nothing to install, your browser's dev console:

  ```js
  let ws = new WebSocket('ws://localhost:5018/');
  ws.onmessage = e => console.log(e.data);
  ws.onopen    = () => ws.send('hello');
  ```

## Example List
1. `01-hello-http` - minimal HTTP response
2. `02-streaming-response` - chunked body, trailers, disconnect handling
3. `03-request-body` - reads multi-event request bodies
4. `04-websocket-echo` - handshake and echo loop
5. `05-sse-broadcaster` - server-sent events
6. `06-lifespan-state` - lifespan protocol with shared state
7. `07-extension-fullflush` - middleware using the `fullflush` extension
8. `08-tls-introspection` - prints TLS metadata when present
9. `11-job-runner` - background job processing (uses `IO::Async` directly for timers/subprocesses)
10. `12-utf8` - UTF-8 handling demonstration
11. `13-flow-control` - conflation under backpressure via the `pagi.transport` handle
12. `14-periodic-events` - an in-app periodic event source, the *easy way*: a long-poll endpoint, a long-running `/stream`, and two sources on one `Future::Selector` (handlers pull from a shared hub)
13. `17-event-middleware` - the same source the *right way*: a middleware owns it and delivers its events through `$receive`, so the app just awaits events and switches on `type`
14. `18-bidirectional-websocket` - full-duplex WebSocket: a receive-loop and an unsolicited server send-loop running concurrently (two branches joined with `wait_any`)

## Embedding & event loops

- `15-embedded-ioasync` - embed `PAGI::Server` in a larger IO::Async program (caller owns the loop)
- `16-foreign-loop` - run `PAGI::Server` under an EV-backed IO::Async loop

For the full story -- loop-agnostic apps, non-blocking I/O, and binding a
server to a loop -- see L<PAGI::EventLoops>.

## More examples

Examples that use the convenience helpers (routers, middleware, ready-made
apps, request/response sugar) live with the toolkit, in the `PAGI-Tools`
distribution. The protocol examples here need none of that.

Each example has its own `README.md` explaining how to run it and which spec
sections to review. For an annotated tour of these examples with the key code
inline, see the `PAGI::Cookbook` documentation.
