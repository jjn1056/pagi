# TODO

## PAGI::Server

- When in multi-worker mode, add timeout to allow reaping children
- Review common server configuration options (from Uvicorn, Hypercorn, Starman)
- More logging levels and control (like Apache)
- Run compliance tests: HTTP/1.1, WebSocket, TLS, SSE
- UTF-8 testing for text, HTML, JSON
- middleware for handling Reverse proxy / reverse proxy path
- Verify no memory leaks in PAGI::Server and PAGI::Simple

## PAGI::Simple

- Static file serving: pass-through trick for reverse proxy (like Plack)
- CSRF protection middleware/helper for Valiant form integration
  - Valiant::HTML::Util::Form uses context to detect Catalyst CSRF plugin
  - PAGI::Simple needs its own CSRF token generation/validation mechanism
  - Consider: middleware that sets token in session, helper to embed in forms
- ~~Strong parameters (like Rails) for form param handling~~ **DONE**
  - Implemented as `PAGI::Simple::StructuredParams`
  - See `perldoc PAGI::Simple::StructuredParams` for full documentation
  - Usage: `(await $c->structured_body)->namespace('x')->permitted(...)->to_hash`
- Controller pattern (`$c->controller` or similar)
  - Group related routes into controller classes
  - Consider: `$app->controller('/orders' => 'MyApp::Controller::Orders')`
  - Or: `$c->controller->action_name` for current controller context
  - Look at: Mojolicious controllers, Catalyst controllers, Rails controllers
  - Benefits: better organization for larger apps, reusable action logic, before/after filters per controller

- Path param injection into handler signatures (future - nice to have)
  - Dream: `$app->get('/todos/:id' => async sub ($c, $id) { ... })` with `$id` auto-populated
  - Challenge: Native Perl signatures don't expose param names at runtime
  - Options explored:
    - Positional matching (simple, pass params in URL order) - recommended approach
    - Name matching via Function::Parameters (preserves metadata, adds dependency)
    - Custom keyword via XS::Parse::Sublike (significant work)
    - B::Deparse hack (fragile)
  - Benefit: ~1 line saved per path param, cleaner signatures, more "modern" feel
  - Priority: Low - polish, not substance. Form objects would reduce more friction.

- Form Objects (future - Django/Reform inspired)
  - Problem: `form_for` and `structured_body` are two halves that should be connected
  - Currently: view renders fields, controller separately declares `permitted()` - easy to get out of sync
  - Solution: explicit Form classes that handle BOTH rendering AND parsing
  - Example vision:
    ```perl
    package TodoApp::Form::CreateTodo;
    use Moo;
    with 'PAGI::Simple::Form';

    sub model_class { 'TodoApp::Entity::Todo' }
    sub fields { [qw(title)] }

    # Controller usage:
    my $form = TodoApp::Form::CreateTodo->new(params => await $c->body_params);
    if ($form->valid) {
        my $todo = $todos->build($form->data);
    }

    # View usage - same form object:
    <%= form_for($form, sub { ... }) %>
    ```
  - Benefits: single source of truth, testable, explicit, common pattern
  - Look at: Django ModelForm, Reform/Trailblazer, Phoenix.HTML.Form
  - Consider: how to integrate with existing Valiant forms without duplication
  - Note: This would reduce current boilerplate where you need namespace_for + permitted

## Worker Pool / Blocking Operations

### Level 1: `$c->run_blocking()` - IMPLEMENTED

Simple context method to run blocking code in worker processes. Opt-in via config.

```perl
my $app = PAGI::Simple->new(
    workers => { max_workers => 4 },
);

$app->get('/search' => async sub ($c) {
    my $results = await $c->run_blocking(sub {
        # Blocking DBI query runs in worker process
        my $dbh = DBI->connect(...);
        return $dbh->selectall_arrayref(...);
    });
    $c->json($results);
});
```

See `PLAN_WORKER_LEVEL1.md` for implementation plan.

### Level 2: Worker Service Scope (Future)

A new service scope `Worker` that automatically runs service methods in workers:

```perl
package MyApp::Service::DB;
use parent 'PAGI::Simple::Service::Worker';

# Methods automatically return Futures, run in worker processes
sub find_all ($self, $table) {
    $self->{dbh}->selectall_arrayref("SELECT * FROM $table");
}
```

Registration:
```perl
$app->service('DB', 'MyApp::Service::DB', 'Worker', { dsn => '...' });
```

Usage (methods return Futures):
```perl
my $todos = await $c->service('DB')->find_all('todos');
```

Benefits:
- Reusable across routes
- Per-worker state (DB connections created once per worker)
- Clean separation of concerns

Challenges:
- More complex implementation (method call serialization)
- Worker initialization lifecycle
- Proxy object to intercept method calls

### Level 3: Named Worker Pools (Future - Probably Overkill)

Multiple worker pools with different configurations:

```perl
$app->worker_pool('db', {
    max_workers => 4,
    init => sub ($worker) {
        $worker->{dbh} = DBI->connect(...);
    },
});

$app->worker_pool('compute', {
    max_workers => 2,  # CPU-bound, fewer workers
});

$app->worker_operation('db.find_all', sub ($worker, $table) {
    $worker->{dbh}->selectall_arrayref("SELECT * FROM $table");
});
```

Usage:
```perl
my $todos = await $c->worker('db.find_all', 'todos');
```

Benefits: Separate pools for different workloads, worker-local state.
Drawback: Probably too complex for a micro-framework. Document as pattern instead.

## Mount Enhancements (Future)

- **404 pass-through**: Option to try parent routes if mounted app returns 404
  - `$app->mount('/api' => $sub_app, { pass_through => 1 })`
  - Use case: fallback routes in parent app

- **Shared state via $scope**: Allow mounted apps to access parent services/stash
  - Add `$scope->{'pagi.services'}` and `$scope->{'pagi.stash'}`
  - Follows PSGI convention for framework-specific data
  - Enables composition without tight coupling

## PubSub / Multi-Worker Considerations

**Decision (2024-12):** PubSub remains single-process (in-memory) by design.

### What We Learned

We explored adding IPC between parent and workers at the PAGI::Server level
to enable cross-worker PubSub. After research, we decided against it:

1. **Industry standard**: All major frameworks (Django Channels, Socket.io,
   Starlette) use in-memory for dev and Redis for production. Nobody does IPC.

2. **Why no IPC?**
   - IPC only works on one machine; Redis works across machines
   - If you need multi-worker, you'll soon need multi-server
   - External brokers provide: persistence, monitoring, pub/sub patterns
   - IPC adds complexity for a transitional use case

3. **PAGI philosophy**: PAGI::Server is a reference implementation, not the
   only option. Building IPC into it would couple PAGI::Simple to PAGI::Server.

### Current Design

- `PAGI::Simple::PubSub` uses in-memory backend (single-process)
- For multi-worker/multi-server: use Redis or similar external broker
- Document this limitation clearly in PubSub docs

### Future Options (if needed)

- Add pluggable backend API to PubSub (easy to add later)
- Provide Redis backend example in documentation
- Users can implement their own backends

## Documentation

- Scaling guide: single-worker vs multi-worker vs multi-server
- PubSub limitations and Redis migration path
- Performance tuning guide
- Streaming request body support shipped (opt-in, backpressure, limits, decoding) - see PLAN.md and the simple-14-streaming example
