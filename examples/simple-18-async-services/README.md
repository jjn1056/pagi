# Async Services Example

Demonstrates async/await support in PAGI::Simple services using `Future::AsyncAwait`.

## Running

```bash
pagi-server --app examples/simple-18-async-services/app.pl
```

## Features Demonstrated

### Service Scopes with Async Methods

All three service scopes support async methods:

1. **Factory** (`MyApp::Service::Weather`) - New instance per `$c->service()` call
2. **PerRequest** (`MyApp::Service::UserProfile`) - Cached per request
3. **PerApp** (`MyApp::Service::Stats`) - Singleton for app lifetime

### Async Method Pattern

Services use `Future::AsyncAwait` for async methods:

```perl
package MyApp::Service::Weather;
use parent 'PAGI::Simple::Service::Factory';
use Future::AsyncAwait;

async sub get_forecast ($self, $city) {
    # In real code: my $data = await $http->get("https://api.weather.com/$city");
    return { city => $city, temp => 72, conditions => 'Sunny' };
}
```

### Calling Async Services in Routes

Routes can use `async sub` and `await` service methods:

```perl
$app->get('/weather/:city' => async sub ($c) {
    my $weather = $c->service('Weather');
    my $forecast = await $weather->get_forecast($c->param('city'));
    $c->json($forecast);
});
```

## Routes

- `GET /` - Overview with sample weather data
- `GET /weather/:city` - Get weather forecast (async fetch)
- `GET /users/:id` - Get user profile (demonstrates PerRequest caching)
- `GET /stats` - Multiple async calls

## Service Files

```
lib/MyApp/Service/
├── Weather.pm      # Factory scope - async weather fetching
├── UserProfile.pm  # PerRequest scope - cached user data
└── Stats.pm        # PerApp scope - singleton stats
```

## Key Concepts

### Why Use Async Services?

- Non-blocking I/O for database queries, HTTP calls, etc.
- Better resource utilization under load
- Natural integration with Perl's `Future::AsyncAwait`

### PerRequest Caching Benefit

The `UserProfile` service demonstrates PerRequest caching:

```perl
# Both calls use the same service instance
my $user = await $profile->get_user($id);     # Creates instance, fetches user
my $prefs = await $profile->get_preferences($id);  # Reuses same instance
```

### PerApp Singleton for Shared State

The `Stats` service shows singleton behavior:

```perl
# All requests share one instance - good for caches, counters, connection pools
my $stats = $c->service('Stats');
my $count = await $stats->get_visitor_count;
```
