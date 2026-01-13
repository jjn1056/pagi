# PAGI::Lifespan Redesign

**Status**: Design Draft
**Date**: 2026-01-06

## Background

The current `PAGI::Lifespan` implementation has several issues:

1. **Broken flow in `to_app`**: Calls the wrapped app with lifespan scope BEFORE running handlers, causing the app to consume `$receive` events before `handle()` gets a chance
2. **Awkward aggregation**: Uses `$scope->{'pagi.lifespan.handlers'}` side-channel for composing handlers
3. **No introspection**: Can't detect if a wrapped app has lifespan handlers for automatic aggregation
4. **Confusing API**: Mix of `wrap()`, `to_app()`, `for_scope()`, `register()`, `handle()` methods

## Goals

1. Clean, simple API with explicit startup/shutdown callbacks
2. Automatic handler aggregation when wrapping apps that have lifespan
3. Introspectable via blessed coderef pattern
4. Shared state across all handlers
5. Fail hard on first startup error
6. Preserve `PAGI::Utils::handle_lifespan` behavior exactly

## Design

### New Module Structure

```
lib/PAGI/Lifespan.pm          # Main wrapper class (redesigned) + PAGI::Lifespan::App package
lib/PAGI/Utils.pm             # Keep handle_lifespan working (self-contained)
```

### PAGI::Lifespan (Redesigned)

**Public API:**

```perl
# Primary interface - wrap an app with lifespan handlers
my $app = PAGI::Lifespan->wrap(
    $inner_app,
    startup  => async sub { my ($state) = @_; ... },
    shutdown => async sub { my ($state) = @_; ... },
);

# $app is now a blessed coderef (PAGI::Lifespan::App)
# - Callable as a normal PAGI app
# - Introspectable for handler aggregation
```

**Behavior:**

1. When called with `lifespan` scope: runs all handlers, sends completion events
2. When called with other scopes: passes through to inner app with state injected
3. Automatic aggregation: if `$inner_app` is a `PAGI::Lifespan::App`, its handlers are collected and run first

**Handler Execution Order:**

- Startup: child first → parent last (child initializes, parent can depend on it)
- Shutdown: parent first → child last (parent releases, child cleans up)

Implementation: Store handlers with child first, parent last:
```perl
push @handlers, @{ $child->lifespan_handlers };  # Child handlers first
push @handlers, { startup => ..., shutdown => ... };  # Parent handlers last
```

Then:
- Startup: iterate forward (child → parent)
- Shutdown: iterate reverse (parent → child)

### PAGI::Lifespan::App (New)

Blessed coderef class providing introspection:

```perl
package PAGI::Lifespan::App;

# Introspection methods
sub has_lifespan;        # Returns true
sub lifespan_handlers;   # Returns arrayref of { startup, shutdown }

# Callable via blessed coderef (no overload needed)
# $app->($scope, $receive, $send) just works
```

**Implementation**: Inside-out object pattern using `Scalar::Util::refaddr` to store handlers keyed by coderef address.

### PAGI::Utils::handle_lifespan (Preserved)

Make self-contained by copying the handler execution logic. No longer depends on `PAGI::Lifespan->for_scope()` or `->register()` or `->handle()`.

```perl
async sub handle_lifespan {
    my ($scope, $receive, $send, %opts) = @_;

    croak "..." unless $scope->{type} eq 'lifespan';

    # Collect handlers from scope key (backward compat) + opts
    my @handlers;
    push @handlers, @{ $scope->{'pagi.lifespan.handlers'} // [] };
    push @handlers, { startup => $opts{startup}, shutdown => $opts{shutdown} }
        if $opts{startup} || $opts{shutdown};

    my $state = $scope->{state} //= {};

    # Event loop
    while (1) {
        my $msg = await $receive->();

        if ($msg->{type} eq 'lifespan.startup') {
            for my $h (@handlers) {
                next unless $h->{startup};
                eval { await $h->{startup}->($state) };
                if ($@) {
                    await $send->({ type => 'lifespan.startup.failed', message => "$@" });
                    return;
                }
            }
            await $send->({ type => 'lifespan.startup.complete' });
        }
        elsif ($msg->{type} eq 'lifespan.shutdown') {
            for my $h (reverse @handlers) {
                next unless $h->{shutdown};
                eval { await $h->{shutdown}->($state) };
                # Log but continue on shutdown errors
            }
            await $send->({ type => 'lifespan.shutdown.complete' });
            return 1;
        }
    }
}
```

## API Comparison

| Current | New | Notes |
|---------|-----|-------|
| `PAGI::Lifespan->new(app => $app, ...)` | `PAGI::Lifespan->wrap($app, ...)` | Simplified |
| `$lifespan->to_app` | Returns blessed coderef directly | No separate step |
| `$lifespan->wrap($app, ...)` | `PAGI::Lifespan->wrap($app, ...)` | Class method only |
| `PAGI::Lifespan->for_scope($scope)` | Removed | Not needed |
| `$lifespan->register(...)` | Removed | Pass to wrap() |
| `$lifespan->handle(...)` | Internal only | Not public |
| `$lifespan->on_startup($cb)` | Removed | Pass to wrap() |
| `$lifespan->on_shutdown($cb)` | Removed | Pass to wrap() |
| `$lifespan->state` | Removed | Use $scope->{state} |

## Removed Methods

These methods are removed from PAGI::Lifespan (breaking change):

- `new()` - Use `wrap()` instead
- `to_app()` - `wrap()` returns the app directly
- `for_scope()` - No longer needed
- `register()` - Pass handlers to `wrap()`
- `on_startup()` - Pass handlers to `wrap()`
- `on_shutdown()` - Pass handlers to `wrap()`
- `state()` - Access via `$scope->{state}`
- `handle()` - Internal implementation detail

## Handler Aggregation Example

```perl
# Inner app with its own lifespan (child)
my $db_app = PAGI::Lifespan->wrap(
    $some_app,
    startup  => async sub { my ($s) = @_; $s->{db} = connect() },
    shutdown => async sub { my ($s) = @_; $s->{db}->disconnect },
);

# Outer app wrapping it (parent) - handlers auto-aggregate
my $app = PAGI::Lifespan->wrap(
    $db_app,
    startup  => async sub { my ($s) = @_; $s->{cache} = Cache->new($s->{db}) },
    shutdown => async sub { my ($s) = @_; $s->{cache}->flush },
);

# Execution order:
# Startup:  db init → cache init (child first, parent can use $s->{db})
# Shutdown: cache flush → db disconnect (parent first, child last)
```

## State Sharing

All handlers share the same `$state` hashref. This is passed to each handler's startup/shutdown callback and also injected into `$scope->{state}` for all subsequent requests.

## Error Handling

- **Startup failure**: First handler that throws stops the chain, sends `lifespan.startup.failed`
- **Shutdown failure**: Log error, continue to next handler, send `lifespan.shutdown.complete`

## Files to Modify

1. `lib/PAGI/Lifespan.pm` - Complete rewrite (includes `PAGI::Lifespan::App` package)
2. `lib/PAGI/Utils.pm` - Make `handle_lifespan` self-contained
3. `t/06-lifespan.t` - Update tests
4. `t/utils-lifespan.t` - Ensure still passes

## Migration

This is a breaking change. Users of the old API will need to update:

```perl
# Old
my $lifespan = PAGI::Lifespan->new(app => $app, startup => ..., shutdown => ...);
my $wrapped = $lifespan->to_app;

# New
my $wrapped = PAGI::Lifespan->wrap($app, startup => ..., shutdown => ...);
```

`PAGI::Utils::handle_lifespan` continues to work unchanged.
