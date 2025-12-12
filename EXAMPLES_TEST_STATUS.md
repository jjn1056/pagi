# Examples Test Status

Testing all examples with Playwright to verify they work after recent changes.

## Test Progress

| # | Example | Status | Notes |
|---|---------|--------|-------|
| 1 | 01-hello-http | ✅ Pass | Shows "Hello from PAGI at [timestamp]" |
| 2 | 02-streaming-response | ✅ Pass | Shows "Chunk 1 Chunk 2 Chunk 3" |
| 3 | 03-request-body | ✅ Pass | POST echoes body correctly |
| 4 | 04-websocket-echo | ⚠️ Skip | Pure WebSocket app, no HTTP - requires WS client |
| 5 | 05-sse-broadcaster | ⚠️ Skip | Pure SSE app, no HTTP - requires SSE client |
| 6 | 06-lifespan-state | ✅ Pass | Shows "Hello from lifespan via shared state" |
| 7 | 07-extension-fullflush | ✅ Pass | Shows "Line 1, Line 2, Line 3" |
| 8 | 08-tls-introspection | ⚠️ Skip | Requires TLS certs and --tls flag |
| 9 | 09-psgi-bridge | ✅ Pass | Shows "PSGI says hi" |
| 10 | 10-chat-showcase | ✅ Pass | Shows login page HTML |
| 11 | 11-job-runner | ✅ Pass | Shows job runner HTML (needs -Iexamples/.../lib) |
| 12 | 12-utf8 | ✅ Pass | Shows UTF-8 test page with λ, 🔥, 中文 |
| 13 | simple-01-hello | ✅ Pass | Shows "Hello, World!" |
| 14 | simple-02-forms | ✅ Pass | Shows contact form HTML |
| 15 | simple-03-websocket | ✅ Pass | Shows WebSocket chat HTML |
| 16 | simple-04-sse | ✅ Pass | Shows SSE notifications HTML |
| 17 | simple-05-streaming | ✅ Pass | Shows streaming demo HTML |
| 18 | simple-06-negotiation | ✅ Pass | Shows content negotiation demo HTML |
| 19 | simple-07-uploads | ✅ Pass | Shows file upload demo HTML |
| 20 | simple-08-cookies | ✅ Pass | Shows cookie demo HTML |
| 21 | simple-09-cors | ✅ Pass | Shows CORS demo HTML |
| 22 | simple-10-logging | ✅ Pass | Shows logging demo HTML |
| 23 | simple-11-named-routes | ✅ Pass | Shows named routes demo HTML |
| 24 | simple-12-mount | ✅ Pass | Shows mount demo HTML (run from its dir) |
| 25 | simple-13-utf8 | ✅ Pass | Shows UTF-8 test page with λ, 🔥, 中文 |
| 26 | simple-14-streaming | ✅ Pass | Shows streaming bodies demo HTML |
| 27 | simple-15-views | ✅ Pass | Shows views demo HTML |
| 28 | simple-16-layouts | ✅ Pass | Shows layouts demo HTML |
| 29 | simple-17-htmx-poll | ✅ Pass | Shows htmx poll demo HTML |
| 30 | simple-18-async-services | ✅ Pass | Returns JSON (fixed missing signatures pragma) |
| 31 | simple-19-valiant-forms | ✅ Pass | Shows Valiant forms demo HTML |
| 32 | view-nested | ⚠️ Skip | No app.pl - library/template only |
| 33 | view-todo | ⚠️ Skip | No app.pl - library/template only |
| 34 | view-users | ⚠️ Skip | No app.pl - library/template only |

## Legend
- ✅ Pass - Example works correctly
- ❌ Fail - Example has issues
- ⏳ Pending - Not yet tested
- ⚠️ Skip - Cannot test (e.g., requires special setup)

## Summary

**Tested**: 2025-12-12

- **Pass**: 28 examples
- **Skip**: 6 examples (pure WS/SSE apps, TLS required, or template-only)
- **Fail**: 0 examples

**Fix Applied**: Added `use experimental 'signatures';` to `simple-18-async-services/app.pl`

All runnable examples are working correctly after the recent changes.
