# Spec ↔ Reference-Server Reconciliation

Tracking divergences between the PAGI **specification** (this repo, `lib/PAGI/Spec/*.pod` + `lib/PAGI.pm`) and the reference **server** (`~/Desktop/PAGI-Server`, `lib/PAGI/Server/*.pm`). The spec exists so that an application runs on *any* conforming server; wherever the spec and the reference server disagree, a second-server author would build the wrong thing. The point of this document is to reconcile each item — by **fixing the spec** (the server is doing the right thing, the spec is just silent), **fixing the server** (it violates the spec), or **deciding** (the spec is self-contradictory or a behaviour choice is open).

How to use: work top to bottom (A → E). Each item has an ID, a resolution type, and a status box. Line numbers are point-in-time from the audit — re-grep when you pick up an item.

Citations: `Server:` = `~/Desktop/PAGI-Server/lib/PAGI/Server/`; `Spec:` = this repo's `lib/PAGI/Spec/` (or `lib/PAGI.pm`).

Status: ☐ open · ◐ in progress · ☑ done

---

## A. Spec contradicts itself — DECIDE first, then propagate

### A1. `$send` after disconnect: must-fail vs no-op ☑
- **Type:** DECISION → fix spec (both docs). No server change (already no-op).
- **Divergence:** `Spec::Www` said any `$send` after disconnect MUST fail its Future with a disconnect exception class; the base `PAGI::Spec` said no-op; the server does no-op; no `PAGI::Error::Disconnected` ever existed.
- **RESOLVED (no-op):** chose no-op as a *deliberate* divergence from ASGI (which leans SHOULD-raise a server-specific `OSError` subclass, but only as a SHOULD and "not guaranteed"). Justification: PAGI's disconnect detection is richer than ASGI's — every scope type delivers a disconnect *event*, and HTTP adds the `pagi.connection` state object (`is_connected`/`disconnect_reason`/`on_disconnect`/`disconnect_future`), which exists precisely because HTTP's `receive()` would consume body data (a problem WS/SSE don't have). So no-op is well-backed and ergonomically cleaner (a client closing mid-stream is normal, not exceptional).
- **Done:** `Www.pod` HTTP + WebSocket "Disconnected Client" subsections rewritten to no-op + point at the disconnect event / `pagi.connection`; base `Spec.pod` send-after-close text made affirmative and detection-pointing. (The unrelated `Www:483` file-open-error `$send` failure correctly stays.)
- **Possible future (non-blocking):** WS/SSE have no dedicated disconnect-only Future like HTTP's `disconnect_future`; consider adding one for symmetry someday.

### A2. Disconnect-reason taxonomy is inconsistent and partly non-conformant ☑ (spec + server done)
- **Type:** DECISION/spec → then fix server. **Folds in B5 and B6.**
- **Divergence:** (a) WebSocket and SSE use *different* reason vocabularies. (b) The server emits reasons that are neither in the spec's standard list nor `x-`prefixed, which the spec's *own rule* forbids for custom reasons. (c) SSE emits `client_closed` where the spec documents `client disconnect`. (d) `on_disconnect` fired for *both* abnormal drops and normal completion, so apps couldn't tell them apart, and completion "reasons" (`request_complete`/`stream_complete`/`session_complete`) leaked into the same surface as real disconnect reasons.
- **RESOLVED — one taxonomy, abnormal vs. complete split (spec done):**
  - **One shared underscore vocabulary** across HTTP/WS/SSE, defined once in `Www.pod` L<Standard Disconnect Reasons>: `client_closed`, `client_timeout`, `idle_timeout`, `keepalive_timeout`, `write_timeout`, `write_error`, `read_error`, `protocol_error`, `server_shutdown`, `server_error`, `body_too_large`, `queue_overflow` (added the last three; `x-` still allowed for custom). Every reason is **abnormal** by definition.
  - **HTTP `pagi.connection` gains `on_complete`** (success-only) as the counterpart to `on_disconnect` (abnormal-only). `disconnect_reason()`/`disconnect_future()` are abnormal-only. Exactly one of the two callbacks fires per request — completion reasons no longer masquerade as disconnect reasons.
  - **WS/SSE keep their event model**; their `*.disconnect` events now reference the shared vocabulary (SSE spaces→underscores; WS `reason` MUST carry the real token, not empty = **B5**).
  - **WS close `code`:** `1006` for abnormal drops (no close handshake), `1005` only for a codeless peer close frame — affirms the server's behaviour (= **B6**, server was right; spec said "default 1005" and is now corrected).
- **Spec edits (done):** `Www.pod` Connection Object Interface (+`on_complete`), Standard Disconnect Reasons (abnormal framing + 3 new tokens), Server Requirements, State Transition Order (abnormal + completion paths), Cleanup example (on_disconnect/on_complete symmetry), WS disconnect event (vocab + `code` + `reason`), SSE disconnect event (vocab); `Cookbook.pod` recipe updated.
- **Server (DONE — PAGI-Server branch `sync-a2-disconnect-complete-split`):**
  - `ConnectionState.pm`: added `on_complete`/`_mark_complete` with a `connected → {disconnected, completed}` state machine; `on_disconnect`/`disconnect_reason`/`disconnect_future` are abnormal-only; a late `on_disconnect` after completion (and vice versa) is inert. (commit `67a4a97`)
  - `Connection.pm`: HTTP completion fires `_mark_complete` on both the keep-alive and close paths (the keep-alive path previously dropped the state entirely, so `on_complete` could never fire). (commit `0fb4ed6`)
  - `Connection.pm`: WS disconnect event now carries a standard reason token + the real close code via a centralized `_ws_disconnect_event` helper (`ws_disconnect_reason` set in `_handle_disconnect`, `ws_disconnect_code` recorded in `_send_close_frame`); `policy_violation`→`queue_overflow`; completion reasons recognized and never recorded as abnormal. (commit `eab73cb`) **B5/B6 server side done.**
  - **Tests:** full suite green (84 files / 537 tests, 3 signal tests skipped). New `t/integration/connection-complete.t` (on_complete on both completion paths) + `t/integration/websocket-disconnect-reason.t` (reason=`queue_overflow`, code=1008). Examples branch on disconnect `type` only → unaffected.
  - **PAGI-Tools (DONE — branch `sync-a2-disconnect-complete-split`, commit `9394284`):** added the `on_complete` delegate to `PAGI::Request` (returns `$self`, mirrors `on_disconnect`) and `PAGI::Context`, with POD framing `on_disconnect` abnormal-only / `on_complete` success-only. WS/SSE helpers (`PAGI::WebSocket` `close_reason`/`close_code`, `PAGI::SSE` `disconnect_reason`) already read the event fields → no change, just better values. Full Tools suite green (123 files / 1111 tests).
  - **Still deferred:** the HTTP/2 WebSocket receive path (RFC 8441) keeps its own per-stream disconnect mapping → folded into **D1**.
- **Server citations (point-in-time, pre-change):** `keepalive_timeout` `Connection.pm:1789`; `policy_violation` `:3637, :3650`; `request_complete` `:2038`; `stream_complete` `:2951`; `session_complete` `:3294`; `server_error` `:326, :2004`. SSE `client_closed` `:588, :2622, :2727, :2999`, h2 `:1158`. WS empty reason `:2618, :2723`. ConnectionState `_mark_disconnected` single callback list `ConnectionState.pm:253`.

---

## B. Server violates the spec as written — FIX SERVER

### B1. `pagi.connection` set on HTTP/2 WebSocket and SSE scopes ☐
- **Type:** fix server
- **Divergence:** Spec marks `pagi.connection` NOT APPLICABLE for `websocket`/`sse`. HTTP/1.1 correctly omits it; the HTTP/2 paths set it — so it's both a spec violation and version-inconsistent.
- **Spec:** `Www.pod:762-769`.
- **Server:** h2 WS `Connection.pm:935`, h2 SSE `:1146` (set it); h1 WS `:3318`, h1 SSE `:2957` (correctly omit).

### B2. `pagi.features` always advertised as `{}` ☐
- **Type:** fix server (populate) — or spec decides features stay optional/empty
- **Divergence:** Every scope sets `features => {}` though the server implements streaming, trailers, body limits, and H2 concurrency — the exact keys the spec defines. Feature detection is silently broken.
- **Spec:** `Spec.pod:110-131` (`supports_streaming`, `max_request_body_size`, `max_concurrent_streams`, `supports_trailers`).
- **Server:** `Connection.pm:682, 918, 1129, 2087, 2962, 3323`.

### B3. `websocket.send` `timeout` field ignored (HTTP/1.1) ☐
- **Type:** fix server (implement) — or drop from spec
- **Divergence:** Spec defines `websocket.send` `timeout` ("Future fails and connection closes"); the server's send handler reads only `text`/`bytes`.
- **Spec:** `Www.pod:992`.
- **Server:** `Connection.pm:3500-3530`.

### B4. `sse.send` `timeout` field ignored ☐
- **Type:** fix server (implement) — or drop from spec
- **Divergence:** Spec defines `sse.send` `timeout`; the server's SSE send handler never reads it.
- **Spec:** `Www.pod:1292`.
- **Server:** `Connection.pm:3200-3216`.

### B5. keepalive-timeout `websocket.disconnect` reason is empty → **resolved in A2** ☑
- **Type:** fix server (instance of A2). Spec requires the token; server now emits it.
- **Done:** centralized `_ws_disconnect_event` helper + `ws_disconnect_reason`/`ws_disconnect_code`; abnormal WS closes now report `{ code => <real>, reason => <token> }` instead of `{ 1006, '' }`. PAGI-Server commit `eab73cb`; covered by `t/integration/websocket-disconnect-reason.t`.

### B6. `websocket.disconnect` default `code` 1006 vs spec 1005 → **resolved in A2 (server was right)** ☑
- **Type:** DECISION → fix spec. Server's `1006` for abnormal closes is RFC-correct; `1005` is only for a codeless peer close frame.
- **Done:** `Www.pod` WS disconnect `code` field rewritten to spec exactly this (1006 abnormal / 1005 codeless-frame). No server change.
- **Server (unchanged, correct):** `Connection.pm:2618, 2723, 3361, 3404`; h2 `:945, :1006`; codeless-frame `1005` `:3661`.

### B7. Lifespan `state` may be `undef` rather than HashRef/omitted ☐
- **Type:** fix server (minor)
- **Divergence:** Server always sets `state => $self->{state}` even when undef; spec implies a HashRef or omission.
- **Spec:** `Lifespan.pod:114`.
- **Server:** `Server.pm:3880`.

### B8. TLS `cipher_suite` effectively always `undef` ☐
- **Type:** fix server — or accept + document
- **Divergence:** The server leaves `cipher_suite` `undef` despite terminating TLS locally, where the value is determinable; spec permits `undef` only when the server cannot determine it.
- **Spec:** `Tls.pod:103-108`.
- **Server:** `Connection.pm:2800-2814`.

---

## C. Server is correct; the SPEC needs to catch up — FIX SPEC (document)

These are legitimate, necessary HTTP/WS/SSE behaviours the spec is simply silent on. Mostly spec writing.

### C1. Server-supplied `Date` header (and H1/H2 inconsistency) ☐
- **Type:** fix spec + fix server (consistency)
- **Divergence:** HTTP/1.1 injects a `Date` response header; HTTP/2 does not; the spec mentions neither. Document that the server supplies `Date`, and make H1/H2 agree.
- **Spec:** silent (`Www.pod:391-405` lists only `type`/`status`/`headers`/`trailers`).
- **Server:** h1 `Connection.pm:2371`; h2 absent `:810-819`.

### C2. Auto chunked Transfer-Encoding when no `Content-Length` ☐
- **Type:** fix spec
- **Divergence:** Server frames the body as chunked when the app set no `Content-Length`; spec says only "ignore app-set Transfer-Encoding," not that the server auto-frames.
- **Spec:** `Www.pod:383`. **Server:** `Connection.pm:2388`.

### C3. HTTP/1.0 `Connection: close`/`keep-alive` injection ☐
- **Type:** fix spec (brief note)
- **Server:** `Connection.pm:2380, 2384`. **Spec:** silent.

### C4. Server-generated error responses (`413/500/403/501`) + bodies/reasons ☐
- **Type:** fix spec (document the server-originated error surface)
- **Server:** `_send_error_response` body `Connection.pm:2517-2536`; `500` `:1996, :2935, :3285`; `413` `:1902, :2217`, h2 `:493, :543`; `403` `:3534`, h2 `:1078`; `501` h2 `:443`. **Spec:** defines no status codes/reason phrases/error bodies.

### C5. `max_body_size` enforced as `413` ☐
- **Type:** fix spec
- **Server:** `Connection.pm:1899-1906, 2215-2221`, h2 `:481-502`. **Spec:** `Spec.pod:122` (feature key only, no enforcement contract).

### C6. `Expect: 100-continue` → interim `100 Continue` ☐
- **Type:** fix spec
- **Server:** `Connection.pm:2176-2178`. **Spec:** silent.

### C7. SSE auto-injected `Cache-Control: no-cache` / `Connection: keep-alive` ☐
- **Type:** fix spec
- **Server:** `Connection.pm:3180-3182`, h2 `:1280`. **Spec:** `Www.pod:1167-1178` (content-type auto-add is spec'd; these are not).

### C8. WebSocket close-code / protocol-error enforcement (RFC 6455) ☐
- **Type:** fix spec (enumerate or reference RFC 6455)
- **Divergence:** Server enforces `1002` (RSV/reserved-opcode/oversized-control/invalid-close-code), `1007` (invalid UTF-8), `1008` (receive-queue overflow); spec mentions only the `1007` UTF-8 rule.
- **Server:** `Connection.pm:3603, 3612, 3620, 3689` (1002); `:3630, :3699` (1007); `:3636, :3649` (1008). **Spec:** `Www.pod:971, 1074`.

### C9. `max_ws_frame_size` frame-size enforcement ☐
- **Type:** fix spec
- **Server:** `Connection.pm:3483-3485`, caught `:300-327`. **Spec:** silent.

### C10. SSE `event`/`id`/`retry` newline-injection validation (throws) ☐
- **Type:** fix spec
- **Server:** `_format_sse_event` `Connection.pm:3097, 3108, 3114`. **Spec:** `Www.pod:1193-1205` (fields defined, no validation/error behaviour).

### C11. TLS extra diagnostic keys (`*_error`) ☐
- **Type:** fix spec (document as optional) — or fix server (remove)
- **Divergence:** Server may add `cipher_extraction_error`, `server_cert_error`, `client_cert_extraction_error` to `extensions->{tls}`; the spec defines exactly six keys and no diagnostics.
- **Server:** `Connection.pm:2818, 2834, 2878`. **Spec:** `Tls.pod:56-109`.

---

## D. A whole feature the spec doesn't describe — FIX SPEC (new section)

### D1. WebSocket over HTTP/2 (RFC 8441) ☐
- **Type:** fix spec (new section)
- **Divergence:** The server implements WebSocket-over-HTTP/2: Extended CONNECT detection, `websocket.accept` answered with HTTP `200` (not `101`), and `websocket.disconnect`/`sse.disconnect` mappings on `RST_STREAM`/stream-close. The spec's WebSocket section describes only the HTTP/1.1 `101`/`403` handshake.
- **Server:** detect `Connection.pm:429-449`; `200` accept `:1015, :1034`; h2 close→disconnect `:578-591`.
- **Spec:** `Www.pod:835` (HTTP/1.1 only).

---

## E. The ASGI gap that started this — FIX SPEC (extension) + FIX SERVER

### E1. WebSocket Denial Response ☐
- **Type:** fix spec (new extension) + fix server
- **Divergence:** ASGI's `websocket.http.response` extension lets an app refuse a handshake with a *custom* HTTP response (status + headers + body). PAGI can only reject with a hardcoded bare `403 Forbidden` (`websocket.close` before `accept`) — no custom status, headers, or body, in either protocol path.
- **Server:** h1 `Connection.pm:3534` (`_send_error_response(403,'Forbidden')`); h2 `:1075-1078` (hardcoded `403`).
- **Spec:** `Www.pod:835` (bare 403 only).

---

## Matched — no action (recorded so we don't re-litigate)

`pagi.is_worker`/`worker_num` lifespan keys (`Lifespan.pod:106-110`); SSE-for-all-methods + `sse.request` (`Www.pod:1120-1148`); SSE content-type auto-add (`Www.pod:1177`); the lifespan event set; Cookie normalization + `:authority`→`host` override; TLS extension omitted on cleartext; `http.fullflush` rejection when the extension is absent; unrecognized-event-type exceptions; `websocket.accept` `headers` field is supported (`EventValidator.pm:118`) — parity with ASGI 2.1.

Minor non-protocol cleanup: stale "spec 0.3" code comments in the server (`Connection.pm:2075, 2105`) while emitted versions are `0.2`.
