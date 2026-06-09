# PAGI Examples

These are raw-protocol PAGI applications -- each is a plain `async sub` working
directly with `$scope`/`$receive`/`$send`, using no helper modules. They
illustrate the protocol itself, which is what the `PAGI` distribution is about.

## Requirements
- Perl 5.18+ with `Future::AsyncAwait`
- For timers/sleeps: `Future::IO` (loop-agnostic)
- A PAGI server to run them. We use the reference server from the `PAGI-Server`
  distribution: `pagi-server examples/01-hello-http/app.pl --port 5000`

Examples assume you understand the core specification -- see L<PAGI::Tutorial>
and L<PAGI::Spec>.

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

Also included: `backpressure-test` and `worker-pool-prototype.pl` -- lower-level
explorations of backpressure and worker pools.

## More examples

Examples that use the convenience helpers (routers, middleware, ready-made
apps, request/response sugar) live with the toolkit, in the `PAGI-Tools`
distribution. The protocol examples here need none of that.

Each example has its own `README.md` explaining how to run it and which spec
sections to review.
