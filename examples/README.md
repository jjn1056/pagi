# PAGI Examples

This directory contains progressively more advanced PAGI examples. Each subdirectory is prefixed with a two-digit number so you can follow along in order.

## Requirements
- Perl 5.18+ with `Future::AsyncAwait` and `IO::Async`
- Run examples with: `pagi-server examples/01-hello-http/app.pl --port 5000`

Examples assume you understand the core spec (`docs/specs/main.mkdn`) plus the relevant protocol documents.

## Example List
1. `01-hello-http` - minimal HTTP response
2. `02-streaming-response` - chunked body, trailers, disconnect handling
3. `03-request-body` - reads multi-event request bodies
4. `04-websocket-echo` - handshake and echo loop
5. `05-sse-broadcaster` - server-sent events
6. `06-lifespan-state` - lifespan protocol with shared state
7. `07-extension-fullflush` - middleware using the `fullflush` extension
8. `08-tls-introspection` - prints TLS metadata when present
9. `09-psgi-bridge` - wraps a PSGI app for PAGI use (via `PAGI::App::WrapPSGI`)
10. `10-chat-showcase` - WebSocket chat demo with multiple clients
11. `11-job-runner` - background job processing example
12. `12-utf8` - UTF-8 handling demonstration

## Built-in Apps
Additional example apps are bundled in `lib/PAGI/App/`:
- `app-01-file` - static file serving with PAGI::App::File

Each example has its own `README.md` explaining how to run it and which spec sections to review.

## PAGI::Simple Examples

For higher-level Express/Sinatra-style examples, see the [PAGI-Simple](https://github.com/jjn1056/PAGI-Simple) distribution.
