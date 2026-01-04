# TODO

## PAGI::Server - Ready for Release

### Completed

- ~~More logging levels and control (like Apache)~~ **DONE** - See `log_level` option (debug, info, warn, error)
- ~~Run compliance tests: HTTP/1.1, WebSocket, TLS, SSE~~ **DONE** - See `perldoc PAGI::Server::Compliance`
  - HTTP/1.1: Full compliance (10/10 tests)
  - WebSocket (Autobahn): 215/301 non-compression tests pass (71%); validation added for RSV bits, reserved opcodes, close codes, control frame sizes
- ~~Verify no memory leaks in PAGI::Server~~ **DONE** - See `perldoc PAGI::Server::Compliance`
- ~~Max requests per worker (--max-requests) for long-running deployments~~ **DONE**
  - Workers restart after N requests via `max_requests` parameter
  - CLI: `pagi-server --workers 4 --max-requests 10000 app.pl`
  - Defense against slow memory growth (~6.5 bytes/request observed)
- ~~Worker reaping in multi-worker mode~~ **DONE** - Uses `$loop->watch_process()` for automatic respawn
- ~~Filesystem-agnostic path handling~~ **DONE** - Uses `File::Spec->catfile()` throughout
- ~~File response streaming~~ **DONE** - Supports `file` and `fh` in response body
  - Small files (<=64KB): direct in-process read
  - Large files: async worker pool reads
  - Range requests with offset/length
  - Use XSendfile middleware for reverse proxy delegation in production

### Future Enhancements (Not Blockers)

- Review common server configuration options (from Uvicorn, Hypercorn, Starman)
- UTF-8 testing for text, HTML, JSON
- Middleware for handling reverse proxy / X-Forwarded-* headers
- Request/body timeouts (low priority - idle timeout handles most cases, typically nginx/HAProxy handles this in production)
- SIGHUP graceful restart for single-process mode (re-exec pattern)
  - Currently only multi-worker mode supports HUP for graceful restart
  - Single-process would need to re-exec itself, inheriting the listen socket via `$ENV{LISTEN_FD}` (like systemd socket activation)
  - Could also support fork-exec with socket passing via SCM_RIGHTS
  - Low priority - production deployments typically use multi-worker or external orchestration (systemd, docker)

## Future Ideas

### API Consistency: on_close Callback Signatures

Consider unifying `on_close` callback signatures for 1.0:

- **Current:** WebSocket passes `($code, $reason)`, SSE passes `($sse)`
- **Reason:** WebSocket has close protocol with codes; SSE has no close frame
- **Options for 1.0:**
  - Option B: Both pass `($self)` - users call `$ws->close_code` if needed
  - Option C: Both pass `($self, $info)` where `$info` is `{code => ..., reason => ...}` for WS, `{}` for SSE

Decision deferred to 1.0 to avoid breaking changes in beta.

### Worker Pool Enhancements

Level 2 (Worker Service Scope) and Level 3 (Named Worker Pools) are documented
in the codebase history but deemed overkill for the current implementation. The
`IO::Async::Function` pool covers the common use case.

### PubSub / Multi-Worker

**Decision:** PubSub remains single-process (in-memory) by design.

- Industry standard: in-memory for dev, Redis for production
- For multi-worker/multi-server: use Redis or similar external broker
- MCE integration explored but adds complexity

## Documentation (Post-Release)

- Scaling guide: single-worker vs multi-worker vs multi-server
- PubSub limitations and Redis migration path
- Performance tuning guide
- Deployment guide (systemd, Docker, nginx)

## Crazy Ideas for a Higher-Order Framework

### Response as Future Collector

The `->retain` footgun (forgetting to await send calls) is a common async mistake.
PAGI intentionally keeps the spec simple like ASGI, but a higher-level framework
could solve this by having `PAGI::Response` (or similar helper) maintain a
`Future::Selector` or `Future::Converge` that collects all spawned futures.

**Concept:**

```perl
# Framework-level helper (not raw PAGI)
my $response = MyFramework::Response->new($send);

# These would register futures with the response's collector
$response->send_header(200, \@headers);  # Returns future, auto-collected
$response->send_body("Hello");           # Returns future, auto-collected

# Framework's finalize() awaits all collected futures
await $response->finalize();  # Waits for everything
```

**Why it might work:**
- All response operations go through the helper
- Helper tracks every future created
- `finalize()` awaits all of them before returning
- No orphaned futures possible at this abstraction level

**Why PAGI doesn't do this:**
- PAGI is a protocol spec, not a framework
- Raw `$send->()` is intentionally low-level
- Frameworks like Dancer3/Mojolicious built on PAGI can implement this pattern
- Keeps PAGI simple and ASGI-compatible

**Implementation notes:**
- Could use `Future::Utils::fmap_void` or `Future->wait_all`
- Helper methods return futures AND register them
- `finalize()` is just `await Future->wait_all(@collected_futures)`
- Error in any collected future should propagate

This pattern would eliminate the await footgun for framework users while keeping
raw PAGI available for those who need direct control.

### Framework as IO::Async::Notifier

Building on Paul Evans' ideas about Future trees and notifier hierarchies, a
higher-level framework could itself be an `IO::Async::Notifier` subclass. This
enables proper Future adoption and error propagation through the notifier tree.

**Notifier tree structure:**

```
Loop
└── PAGI::Server (Notifier)
    └── MyFramework (Notifier)  ← long-lived, spans all requests
        └── per-request futures adopted here
```

**Detection via duck typing:**

Server would detect if the app is a Notifier and adopt it automatically:

```perl
# In PAGI::Server startup:
if (blessed($app) && $app->isa('IO::Async::Notifier')) {
    $self->add_child($app);
}
```

**Framework implementation:**

```perl
package MyFramework;
use parent 'IO::Async::Notifier';

sub to_app {
    my $self = shift;
    return sub {
        my ($scope, $receive, $send) = @_;
        # Framework can adopt its own futures - errors propagate up
        $self->adopt_future($self->some_background_work());
        # Request handling...
    };
}
```

**Benefits:**

1. **No spec changes** - $scope stays clean, no new keys needed
2. **Opt-in** - Simple apps (coderefs) work unchanged
3. **Server-agnostic** - Other PAGI servers ignore the Notifier aspect
4. **Natural error propagation** - Adopted futures surface errors properly
5. **Coherent shutdown** - Server shutdown flows down to framework
6. **Framework controls closure** - `to_app` closure captures `$self`

**Open questions:**

- Should Connection also be exposed for request-scoped adoption?
- How does this interact with lifespan.startup/shutdown?
- Should there be a formal interface beyond duck typing?

**Related:** This complements the "Response as Future Collector" pattern above.
Together they address the two main async footguns: orphaned request futures
(collector pattern) and orphaned background futures (notifier tree).

## Things to Think About

### Accept External IO::Async::Loop in Constructor

Allow passing an existing `IO::Async::Loop` instance to `PAGI::Server->new` for embedding into larger systems.

**Use Cases:**

| Use Case | Why It Helps |
|----------|--------------|
| Embedding | Run PAGI alongside other IO::Async components (DB pools, timers, Redis clients) |
| Testing | Control the loop for deterministic tests |
| Hybrid apps | Existing IO::Async app wants to add HTTP endpoint |
| Custom setup | Pre-configured loop with specific settings |

**Proposed API:**

```perl
# Current (still works)
my $server = PAGI::Server->new(app => $app, port => 5000);
$server->run;

# With external loop - new 'start' method
my $loop = IO::Async::Loop->new;
$loop->add($redis_client);  # Other components

my $server = PAGI::Server->new(app => $app, port => 5000);
$loop->add($server);        # Server is a Notifier
$server->start->get;        # Start listening (async)
$loop->run;                 # Caller controls the loop

# Or pass loop to constructor
my $server = PAGI::Server->new(
    app  => $app,
    port => 5000,
    loop => $loop,  # Stores reference, run() uses it
);
```

**Considerations:**

1. **Signal handlers** - With external loop, who installs SIGTERM/SIGINT handlers? Should be optional/configurable
2. **Multi-worker mode** - Doesn't make sense with external loop (workers fork and create their own)
3. **`run()` vs `start()`** - `run()` owns the loop lifecycle; `start()` just begins listening

**Implementation:**

- Add `loop` option to constructor
- `run()` uses `$self->{loop} // $self->_create_loop`
- Add `start()` method that sets up listening without calling `$loop->run`
- Add `install_signals` option (default true for `run()`, false for `start()`)

### `$scope->{'pagi.loop'}` - Exposing the Event Loop

**Idea:** Add the IO::Async::Loop to scope so apps can access it directly:

```perl
my $loop = $scope->{'pagi.loop'};
$loop->delay_future(after => 60)->then(...)->retain;
$loop->add($my_notifier);
```

**Pros:**
- Explicit and discoverable (no magic ambient loop lookup)
- Apps often need loop for timers, custom watchers, adding Notifiers
- Consistent with PAGI's "everything in scope" pattern

**Cons:**
- Ties apps to IO::Async implementation detail
- Apps written for PAGI::Server might not work with other PAGI servers
- Could encourage tight coupling between app and server

**Current workaround:** `IO::Async::Loop->new` returns the ambient loop when
running inside PAGI::Server, but this is implicit.

**Decision:** Deferred. Need to weigh portability vs convenience. For now,
apps needing the loop can use the ambient loop pattern or accept loop as
a constructor parameter and initialize in lifespan.startup.
