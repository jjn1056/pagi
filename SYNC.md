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

### B1. `pagi.connection` set on HTTP/2 WebSocket and SSE scopes ☑
- **Type:** fix server.
- **Divergence:** Spec marks `pagi.connection` NOT APPLICABLE for `websocket`/`sse`. HTTP/1.1 correctly omits it; the HTTP/2 paths set it — both a spec violation and version-inconsistent. The attached object was also a dead end (local `ConnectionState`, never stored as `current_connection_state`, never marked disconnected — the HTTP marking path is guarded off for WS/SSE), so its `is_connected()` would read a permanently-stale `true`.
- **Done (PAGI-Server branch `sync-b1-h2-scope-pagi-connection`, commit `2fa6efc`):** removed the `ConnectionState->new` block + `'pagi.connection'` key from `_h2_create_websocket_scope` and `_h2_create_sse_scope`, matching the h1 builders. Both HTTP scope builders (h1 + h2) keep it. New `t/http2/17-h2-ws-sse-no-connection-state.t` (lightweight, no nghttp2) asserts WS/SSE omit the key while HTTP keeps it. Full suite green (85 files / 540 tests). **No PAGI-Tools impact** (verified: only the HTTP `connection` accessors read the key; WS context overrides `is_connected` to handshake state, SSE uses `is_closed`).
- **Spec:** `Spec/Www.pod` "Applicability" (websocket/sse = NOT APPLICABLE) — already correct, no spec change.

### B2. `pagi.features` always advertised as `{}` ☑ (resolved by REMOVING `features`)
- **Type:** was "fix server (populate) — or spec decides" → **decided: remove the mechanism.**
- **Investigation (web + git archaeology):** `pagi.features` is a PAGI original — ASGI has no equivalent (its `scope["asgi"]` is only `{version, spec_version}`; all capability advertisement is the top-level `extensions` key, which advertises *optional message types* by presence, never limits/deployment). Git history: `features` was in the **initial checkin** (`67572f8`, 2025-11-30) with no rationale, identical wording ever since — speculative scaffolding. The same initial commit also defined `extensions` (fullflush), so the two have overlapped since day one; only `extensions` was ever implemented/used. Consumer check: **nothing reads `scope.pagi.features`** anywhere (spec/server/tools/tests) — only 6 always-empty `features => {}` writes.
- **Why not populate:** the scalar use cases are weak (server already enforces its limits; app has no sound action), and a worker-count signal is an outright footgun (it answers "siblings this process forked," not "is my in-process state global" — which is unanswerable from one process behind a load balancer). ASGI's absence of this is informed convergence ("enforce/assume, don't detect"), not an oversight. John: "I was probably wildly speculating it would be useful... if after working on this so long we've never reached for it, lets pull it for now."
- **Done:** removed the `features` key + its 4-key sub-list and the clarification bullet from `Spec.pod` (the `pagi` dict is now `{version, spec_version}`, matching ASGI's `asgi` dict); removed `features => {}` from all 6 scope builders in `Connection.pm`. Capability advertisement lives solely in `extensions` (ASGI-aligned). Pulled "for now" — a properly-motivated scalar-introspection mechanism can be reintroduced deliberately if a concrete need ever appears.

### B3 + B4. `websocket.send` / `sse.send` per-send `timeout` field ignored ☑ (resolved by DROPPING the field)
- **Type:** was "fix server (implement) — or drop" → **decided: drop from spec.**
- **Divergence:** spec defined a per-send `timeout` on `websocket.send` and `sse.send` ("if the write doesn't complete in N s, the Future fails and the connection closes"); both server handlers read only `text`/`bytes`/data, never the field — unimplemented, untested, since 0.2.
- **Deep research (Node `ws`/Socket.IO, ASGI uvicorn/hypercorn/daphne, Mojolicious, RFC 6455, browser/WHATWG):** a per-send-message timeout that closes the connection is **not a recognized pattern anywhere** — RFC 6455 has no "timeout" at all; ASGI's `websocket.send` is just `type`/`bytes`/`text`; `ws`/Mojo/browser have none (Socket.IO's `socket.timeout(ms).emit` is an *app-ack* round-trip, not a write timeout, and doesn't close the connection). Everyone uses the same triad — **backpressure + ping/pong pong-timeout + idle timeout** — which PAGI already has (and ships more of out-of-the-box than `ws`/hypercorn/Mojo). The field targets a real-but-narrow gap (a wedged write below the heartbeat's resolution) but is redundant with the pong-timeout and blunt (tearing down the whole connection over one slow frame — no spec mandates that).
- **Done:** removed the `timeout` field from `websocket.send` and the whole "SSE Send Timeout" section from `Www.pod`, and "send timeouts" from the 0.2 changelog. **No server/tools/example change** — nothing ever read or used it. The `write_timeout` *disconnect reason* stays in the standard vocabulary (a server-emitted cause a server MAY produce via connection-level write timeouts; independent of the app-facing field).
- **Surfaced a real gap instead** → the universal primitive PAGI (like ASGI/Mojo) lacks is **app-visible buffered/queue depth** (the browser/`ws` `bufferedAmount`). Logged for follow-up, NOT part of B3/B4. See TODO.

### B5. keepalive-timeout `websocket.disconnect` reason is empty → **resolved in A2** ☑
- **Type:** fix server (instance of A2). Spec requires the token; server now emits it.
- **Done:** centralized `_ws_disconnect_event` helper + `ws_disconnect_reason`/`ws_disconnect_code`; abnormal WS closes now report `{ code => <real>, reason => <token> }` instead of `{ 1006, '' }`. PAGI-Server commit `eab73cb`; covered by `t/integration/websocket-disconnect-reason.t`.

### B6. `websocket.disconnect` default `code` 1006 vs spec 1005 → **resolved in A2 (server was right)** ☑
- **Type:** DECISION → fix spec. Server's `1006` for abnormal closes is RFC-correct; `1005` is only for a codeless peer close frame.
- **Done:** `Www.pod` WS disconnect `code` field rewritten to spec exactly this (1006 abnormal / 1005 codeless-frame). No server change.
- **Server (unchanged, correct):** `Connection.pm:2618, 2723, 3361, 3404`; h2 `:945, :1006`; codeless-frame `1005` `:3661`.

### B7. Lifespan `state` may be `undef` rather than HashRef/omitted ☑ (false positive — already compliant)
- **Type:** fix server (minor) → turned out to be no fix needed.
- **Finding:** the audit's "even when undef" premise is wrong. `$self->{state}` is assigned `{}` in `_init` (`Server.pm:2209`) and **never** set to undef/deleted anywhere; `_init` runs at construction for every `PAGI::Server->new` (incl. the worker server `:3508`), and both lifespan callers (`listen` `:2559`, worker `:3579`) run after construction. So the lifespan scope's `state` (`:3880`) is invariantly a defined HashRef — verified empirically (`defined=1 ref=HASH`). The bare `state => $self->{state}` is also intentional: lifespan must hand the app the *live* ref so its mutations persist into request scopes. A `// {}` guard would be dead defensive code, so none added.
- **Done (PAGI-Server branch `sync-b1-h2-scope-pagi-connection`, commit `03a9871`):** the real gap was that the contract had only a source-grep test. Added a behavioral subtest in `t/lifespan-worker-fields.t` that boots a real server, runs the lifespan, and asserts `state` is a defined, writable HashRef. No code change.
- **Spec:** `Spec/Lifespan.pod:114` (HashRef or omitted) — already honored.

### B8. TLS `cipher_suite` effectively always `undef` ☑ (server fixed)
- **Type:** fix server.
- **Divergence:** The server left `cipher_suite` `undef` despite terminating TLS locally.
- **Root cause (two layers, both deeper than the audit saw):** (1) the cipher code called `Net::SSLeay::CIPHER_get_id`, which **does not exist** in any Net::SSLeay — the `eval` silently swallowed "Can't locate auto/Net/SSLeay/CIPHER_get_.al", so the field was always `undef`. Net::SSLeay exposes only the cipher *name*, not the numeric IANA id. (2) The server also **never negotiated TLS 1.3**: `SSL_version => 'TLSv1_2:'` pins to exactly 1.2 (the trailing `:` is NOT "or higher", proven by probe), contradicting both its own code comment and `min_version`'s documented floor semantics — so every TLS connection was 1.2. The two compose: no 1.3 + no numeric id = permanent `undef`.
- **Decision (John):** fix the version floor (a real, separate security bug — a 2026 reference server with no TLS 1.3 path) AND provide `cipher_suite` via a TLS 1.3 name→id map (Option A). The name→number mapping is only clean for TLS 1.3 (OpenSSL returns the IANA name; 5 frozen suites); TLS 1.2 uses OpenSSL-specific names → left `undef` (spec-permitted when undeterminable).
- **Done (PAGI-Server `e1b8f68` on `feat-transport-flow-control`):** `SSL_version` rebuilt as a true floor (`SSLv23` minus sub-floor protocols) so TLS 1.3 is offered; `cipher_suite` mapped from the (now TLS 1.3) cipher name via a 5-entry table. `t/08-tls.t`: assert `cipher_suite` is a defined 16-bit id, the tls hash has exactly six keys, and TLS 1.3 is negotiated by default. Full suite 91f/557t green. **No spec change** (server now provides the value when determinable; `undef` stays valid for TLS 1.2).
- **Spec:** `Tls.pod:103-108`.

---

## C. Server is correct; the SPEC needs to catch up — FIX SPEC (document)

**ALL DONE (2026-06-12).** C1-C10 documented in `Www.pod` (PAGI `984ecfd`; C7 reworded so `Date` reads as both-transports after the h2 fix). C1 also added the HTTP/2 `Date` response header for h1/h2 parity (PAGI-Server `d90e180`, `t/http2/21-http-date-header.t`, on both the regular and SSE h2 paths). C11 was resolved with B8 (extraction-error keys removed). C2-C10 needed no server change — the server was already correct; the spec now matches it.

These are legitimate, necessary HTTP/WS/SSE behaviours the spec is simply silent on. Mostly spec writing.

### C1. Server-supplied `Date` header (and H1/H2 inconsistency) ☑
- **Type:** fix spec + fix server (consistency)
- **Divergence:** HTTP/1.1 injects a `Date` response header; HTTP/2 does not; the spec mentions neither. Document that the server supplies `Date`, and make H1/H2 agree.
- **Spec:** silent (`Www.pod:391-405` lists only `type`/`status`/`headers`/`trailers`).
- **Server:** h1 `Connection.pm:2371`; h2 absent `:810-819`.

### C2. Auto chunked Transfer-Encoding when no `Content-Length` ☑
- **Type:** fix spec
- **Divergence:** Server frames the body as chunked when the app set no `Content-Length`; spec says only "ignore app-set Transfer-Encoding," not that the server auto-frames.
- **Spec:** `Www.pod:383`. **Server:** `Connection.pm:2388`.

### C3. HTTP/1.0 `Connection: close`/`keep-alive` injection ☑
- **Type:** fix spec (brief note)
- **Server:** `Connection.pm:2380, 2384`. **Spec:** silent.

### C4. Server-generated error responses (`413/500/403/501`) + bodies/reasons ☑
- **Type:** fix spec (document the server-originated error surface)
- **Server:** `_send_error_response` body `Connection.pm:2517-2536`; `500` `:1996, :2935, :3285`; `413` `:1902, :2217`, h2 `:493, :543`; `403` `:3534`, h2 `:1078`; `501` h2 `:443`. **Spec:** defines no status codes/reason phrases/error bodies.

### C5. `max_body_size` enforced as `413` ☑
- **Type:** fix spec
- **Server:** `Connection.pm:1899-1906, 2215-2221`, h2 `:481-502`. **Spec:** `Spec.pod:122` (feature key only, no enforcement contract).

### C6. `Expect: 100-continue` → interim `100 Continue` ☑
- **Type:** fix spec
- **Server:** `Connection.pm:2176-2178`. **Spec:** silent.

### C7. SSE auto-injected `Cache-Control: no-cache` / `Connection: keep-alive` ☑
- **Type:** fix spec
- **Server:** `Connection.pm:3180-3182`, h2 `:1280`. **Spec:** `Www.pod:1167-1178` (content-type auto-add is spec'd; these are not).

### C8. WebSocket close-code / protocol-error enforcement (RFC 6455) ☑
- **Type:** fix spec (enumerate or reference RFC 6455)
- **Divergence:** Server enforces `1002` (RSV/reserved-opcode/oversized-control/invalid-close-code), `1007` (invalid UTF-8), `1008` (receive-queue overflow); spec mentions only the `1007` UTF-8 rule.
- **Server:** `Connection.pm:3603, 3612, 3620, 3689` (1002); `:3630, :3699` (1007); `:3636, :3649` (1008). **Spec:** `Www.pod:971, 1074`.

### C9. `max_ws_frame_size` frame-size enforcement ☑
- **Type:** fix spec
- **Server:** `Connection.pm:3483-3485`, caught `:300-327`. **Spec:** silent.

### C10. SSE `event`/`id`/`retry` newline-injection validation (throws) ☑
- **Type:** fix spec
- **Server:** `_format_sse_event` `Connection.pm:3097, 3108, 3114`. **Spec:** `Www.pod:1193-1205` (fields defined, no validation/error behaviour).

### C11. TLS extra diagnostic keys (`*_error`) ☑ (server fixed — keys removed)
- **Type:** was "fix spec (document) — or fix server (remove)" → **decided: remove from server.**
- **Divergence:** Server could add `cipher_extraction_error`, `server_cert_error`, `client_cert_extraction_error` to `extensions->{tls}`; the spec defines exactly six keys and no extraction diagnostics.
- **Research (ASGI TLS extension + nginx):** ASGI's TLS extension (which PAGI's mirrors) defines exactly the same six keys, uses `None`/empty for "can't determine," and has **no** server-extraction-error key; its one error field, `client_cert_error`, is for cert *verification* failure (a security event), not retrieval failure. nginx is the same (empty value when unavailable; `$ssl_client_verify` for the verify case). So extraction-error keys are not a recognized need anywhere, are redundant with the spec's `undef`-means-unavailable convention, and would bless one implementation's internals into a cross-server spec. (Steel-manned an app use case with John; none survives — apps branch on the *fact* a value is absent, not the server-side *reason*, which is a log concern.)
- **Done (PAGI-Server `e1b8f68`):** removed the three key assignments; the `tls` hash now carries exactly the six spec keys (verified by `t/08-tls.t` exact-keys assertions, with and without a client cert). Extraction failures are still `warn`-logged. The documented `client_cert_error` (verification failure) stays.
- **Spec:** `Tls.pod:56-109` (already correct — no spec change).

---

## D. A whole feature the spec doesn't describe — FIX SPEC (new section)

**DONE (2026-06-12).** Documented as a new "WebSocket over HTTP/2 (RFC 8441)" section in `Www.pod` (PAGI `984ecfd`) — Extended CONNECT detection, `200`-not-`101` accept, RST/close → `websocket.disconnect`. Transparent to the app (same `websocket` scope + events). Server already implemented it; spec-only.

### D1. WebSocket over HTTP/2 (RFC 8441) ☑
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
