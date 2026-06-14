# PAGI Roadmap

Project-wide roadmap across the three distributions. The **specification**
itself (`PAGI.pm` + `PAGI::Spec::*`) is stable; what follows tracks the
reference server, the toolkit, and tooling. Each item is tagged with its target
distribution:

- **[Server]** — PAGI-Server (`PAGI::Server::*`, `bin/pagi-server`)
- **[Tools]** — PAGI-Tools (`PAGI::Middleware::*`, `PAGI::App::*`, `PAGI::Endpoint::*`, `PAGI::Request`/`Response`/`SSE`/`WebSocket`)
- **[Thunderhorse]** — the framework built on PAGI, not PAGI core
- **[New dist]** — a planned standalone distribution in the PAGI ecosystem

Tiers are ordered by current priority: fix what is broken or misleading first,
then lower the adoption barrier, then add features as demand appears.

---

## Tier 1 — Correctness & honesty

These are either bugs or features the docs promise but the code does not deliver.
Documented-but-missing behaviour is worse than a gap, so these come first.

- **[Tools] Signed cookies are documented but not implemented.**
  `PAGI::Middleware::Cookie` documents `get_signed`/`set_signed` and accepts a
  `secret`, but the secret is stored and never used and the methods do not
  exist. Implement HMAC signing, or remove the option and POD.

- **[Tools] `PAGI::App::WrapCGI` accepts a `timeout` but never enforces it.**
  POD says default 30s; the blocking `open '-|'` read has no alarm/timer.
  Implement the timeout or drop the option.

- **[Tools] `PAGI::App::WrapPSGI` "streaming" buffers the whole body.**
  The streaming-writer closure only pushes chunks and flushes after the PSGI
  responder returns, so it does not actually stream. Fix, or document the
  limitation honestly.

- **[Tools] `PAGI::App::Router` mount prefixes treat `:param` as a literal.**
  `mount('/users/:user_id' => $app)` matches the literal text `:user_id`
  (mount prefixes never go through `_compile_path`). The one critical gap left
  in the router's Phase 1. Either compile prefix params or croak on `:` in a
  mount prefix so it fails loudly.

- **[Tools] IPv6 CIDR matching silently fails.**
  `_ip_in_cidr` in `PAGI::Middleware::Maintenance` and
  `PAGI::Middleware::ReverseProxy` returns false for any non-IPv4 address, so
  allow/deny lists silently no-op on IPv6. A security allow-list that quietly
  ignores v6 is dangerous — support IPv6, or at minimum document IPv4-only
  loudly in POD (not just an inline comment).

- **[Tools] `PAGI::App::Throttle` shares one `%buckets` across all instances.**
  Package-global state means two throttles interfere. Make it per-instance (or
  add a namespace option) and warn in POD.

- **[Server] SSE `id` field is not checked for NUL.**
  The serializer guards SSE fields against newlines but not `\x00`; an `id`
  containing NUL is silently dropped by browsers. Small correctness add
  alongside the existing newline checks.

---

## Tier 2 — Adoption & developer experience

High-value, moderate effort. This is where "make it real" energy pays off.

- **[Server] `--reload` (file-watch dev restart).**
  Every comparable server has it (uvicorn `--reload`). The re-exec machinery
  already exists; add a `Filesys::Notify`-style watcher over `lib/` and the app
  file. Biggest single DX/adoption win on this list. Dev-only.

- **[Server] Ship real deployment artifacts.**
  The guidance exists as POD prose (nginx config, systemd unit, socket
  activation). Provide copy-pasteable files — a `Dockerfile`, `nginx.conf`,
  and `pagi-server.service` — to remove the adoption barrier. Low effort.

- **[Server] Accept an external `IO::Async::Loop` in the constructor.**
  Lets PAGI embed in larger IO::Async apps (DB pools, Redis clients, timers)
  and gives deterministic tests. This is the well-scoped answer to "apps need
  the loop" — preferred over exposing `$scope->{'pagi.loop'}`, which would
  couple apps to IO::Async.

  ```perl
  # run() still owns the loop lifecycle (unchanged)
  $server->run;

  # new: caller owns the loop
  my $server = PAGI::Server->new(app => $app, port => 5000);
  $loop->add($server);     # PAGI::Server is already a Notifier
  $server->start->get;     # begin listening, no $loop->run
  $loop->run;
  ```

  Notes: add a `loop` constructor option and a `start()` that listens without
  running the loop; make signal-handler installation optional (default on for
  `run()`, off for `start()`); multi-worker mode does not apply with an
  external loop.

- **[Server] Structured JSON access logging.**
  The custom access-log-format infrastructure already exists (presets +
  atoms); add a `json` preset/atom. Ops teams expect machine-readable logs.

---

## Tier 3 — When there's demand

Genuinely useful, but pull them forward only when someone asks.

- **[Tools] Router ergonomics people reach for:** trailing-slash policy
  (redirect vs strict), optional path segments (`/users(/:id)`), `pass` /
  fall-through to the next matching route, and route introspection
  (`routes_info`/`walk`). Route introspection also unlocks OpenAPI/tooling
  later.

- **[Tools] Bring `PAGI::Endpoint::Router` to parity with `PAGI::App::Router`.**
  The class-based RouteBuilder is missing `group`, `any`, and chained
  `constraints` even though the underlying router supports them. Matters if the
  endpoint layer is the framework path.

- **[Server/Tools] Prometheus `/metrics` endpoint.**
  The higher-ROI half of the observability story (OpenTelemetry tracing is the
  heavier half). A `Metrics::Any` integration design already exists as a draft
  plan — pick it up from there.

- **[Server] HTTP/2 per-stream stall detection.** *(security hardening, low
  priority — mitigated today by `max_concurrent_streams` and reverse proxies.)*
  The connection idle timer resets on any byte, so an HTTP/2 peer can hold N
  streams open indefinitely with periodic PINGs. Add a per-stream
  `last_activity` and **one** periodic sweep timer per connection (never one
  timer per stream) that RST_STREAMs stale streams; gate on a new
  `h2_stream_timeout` (default 0 = off). Check `submit_rst_stream` is exposed
  by the nghttp2 bindings first.

- **[Server] Early Hints (HTTP 103) extension.**
  Add an `http.response.early_hint` event so apps can push `Link: rel=preload`
  hints before the main response.

- **[New dist] JSON-RPC 2.0 middleware, as its own distribution.**
  A JSON-RPC 2.0 layer over PAGI HTTP — a good idea at low urgency. Ship it as a
  standalone distribution rather than folding it into PAGI-Tools. A pre-split
  reference implementation (middleware + tutorial) lives on the `jsonrpc` branch
  in the PAGI repo to start from.

---

## Framework-layer ideas (Thunderhorse, not PAGI core)

PAGI is a protocol and stays low-level; these belong in a framework built on it.
Kept here so the ideas are not lost — move to Thunderhorse when that repo is
ready.

- **[Thunderhorse] Response as a Future collector.**
  A `Response` helper that registers every send Future it creates and awaits
  them all in `finalize()`, eliminating the "forgot to await `$send`" footgun
  at the framework layer while raw `$send` stays available.

- **[Thunderhorse] Framework as an `IO::Async::Notifier`.**
  Let a framework be a long-lived Notifier in the loop's tree so it can adopt
  per-request and background Futures with proper error propagation and coherent
  shutdown. The server can duck-type-detect a Notifier app and `add_child` it —
  no spec change, opt-in, server-agnostic.

---

## Decisions & non-goals

Settled; recorded so they are not re-litigated.

- **PubSub stays single-process / in-memory by design.** Multi-worker or
  multi-server deployments use an external broker (Redis, etc.).
- **WebSocket permessage-deflate is intentionally unsupported server-side**
  (a `PAGI::Middleware::WebSocket::Compression` exists in Tools for those who
  want it). This is why the Autobahn suite reports ~71% — the bulk of the
  remainder is compression tests.
- **`on_close` callback signatures are deliberately left unaligned until 1.0**
  (WebSocket passes `($code, $reason)`, SSE passes `($self, $reason)`); both
  are documented. Aligning them is a breaking change deferred to 1.0.
- **`$scope->{'pagi.loop'}` is rejected** in favour of the external-loop
  constructor option (avoids coupling apps to IO::Async).
- **Deferred as overkill / YAGNI until asked:** HTTP/3 (QUIC), worker RSS
  memory limits (`max_requests` covers slow growth), config-file/env-var
  configuration, and the router's custom path types, host-based routing,
  `resources` generation, route caching, and versioned routing.

---

## Cross-repo housekeeping

Code health, not user-facing — do opportunistically, do not track as features.

- **[Server] `PAGI::Server::Connection` is a ~3900-line god object;** the
  WebSocket/SSE/HTTP2 handlers could be extracted into modules.
- **[Tools] Duplicated helpers:** `_get_header` is copy-pasted across ~16
  middleware, `_url_decode` across 4 modules, and `PAGI::Endpoint::Router` has
  three near-identical wrapper methods. **[Server]** header-validation is
  duplicated between `Connection` and `Protocol::HTTP1`. Consolidate into base
  classes / shared utils.
- **[Tools] `PAGI::App::Router` matches by linear scan.** Only worth a
  dispatch-table/trie if profiling shows routing is a bottleneck.
- **Shared cross-repo test suite.** Each dist has its own `t/integration/`;
  a shared `xt/` or a small test distribution could cover cross-package
  behaviour once the repos stabilise.
- **Docs to write:** scaling guide (single vs multi-worker vs multi-server),
  PubSub→Redis migration path, performance tuning, and a published benchmark
  comparison against Starman/Twiggy (internal numbers exist; no cross-server
  comparison published).
