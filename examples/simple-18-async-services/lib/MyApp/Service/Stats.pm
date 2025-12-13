package MyApp::Service::Stats;

use strict;
use warnings;
use experimental 'signatures';
use parent 'PAGI::Simple::Service::PerApp';
use Future::AsyncAwait;

# =============================================================================
# Stats Service (PerApp Scope - Singleton)
#
# Single instance shared across all requests for the lifetime of the app.
# Uses async methods to simulate fetching statistics.
# Good for: caches, connection pools, shared state.
# =============================================================================

# Simulated stats (in real app, might be from Redis, database, or analytics API)
my $visitor_count = 12345;
my @popular_cities = (
    { city => 'Seattle', visits => 5420 },
    { city => 'Portland', visits => 3210 },
    { city => 'San Francisco', visits => 2890 },
    { city => 'Los Angeles', visits => 2145 },
    { city => 'Denver', visits => 1876 },
);

# Async method - get visitor count
async sub get_visitor_count ($self) {
    # In a real app, this would be an async call to Redis or analytics:
    # my $count = await $redis->get('visitor_count');

    return $visitor_count;
}

# Async method - get popular cities
async sub get_popular_cities ($self) {
    # In a real app, this would be an async database query:
    # my @cities = await $db->query("SELECT city, COUNT(*) as visits FROM visits GROUP BY city ORDER BY visits DESC LIMIT 5");

    return \@popular_cities;
}

# Async method - increment visitor count (demonstrates shared state)
async sub increment_visitors ($self) {
    $visitor_count++;
    return $visitor_count;
}

# Async method - get combined stats
async sub get_dashboard_stats ($self) {
    my $visitors = await $self->get_visitor_count;
    my $cities = await $self->get_popular_cities;

    return {
        total_visitors => $visitors,
        top_cities => $cities,
        generated_at => time(),
    };
}

1;
