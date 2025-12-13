#!/usr/bin/env perl

# =============================================================================
# Async Services Example
#
# Demonstrates async/await support in PAGI::Simple services.
# Services can use Future::AsyncAwait for async methods.
#
# Run with: pagi-server --app examples/simple-18-async-services/app.pl
# =============================================================================

use strict;
use warnings;
use experimental 'signatures';
use lib 'lib';
use lib 'examples/simple-18-async-services/lib';

use PAGI::Simple;
use Future::AsyncAwait;

my $app = PAGI::Simple->new(
    name      => 'Async Services Demo',
    namespace => 'MyApp',
);

# -----------------------------------------------------------------------------
# Routes demonstrating async service usage
# -----------------------------------------------------------------------------

# Basic async service call
$app->get('/' => async sub ($c) {
    my $weather = $c->service('Weather');

    # Async method returns a Future - await it
    my $data = await $weather->get_forecast('Seattle');

    $c->json({
        message => 'Async Services Demo',
        routes => [
            { path => '/', description => 'This page' },
            { path => '/weather/:city', description => 'Get weather (async fetch)' },
            { path => '/users/:id', description => 'Get user profile (async with cache)' },
            { path => '/stats', description => 'Multiple async calls in parallel' },
        ],
        sample_weather => $data,
    });
});

# Weather service (Factory scope - new instance each request)
$app->get('/weather/:city' => async sub ($c) {
    my $city = $c->param('city');
    my $weather = $c->service('Weather');

    my $forecast = await $weather->get_forecast($city);

    $c->json($forecast);
});

# User profile with PerRequest caching
$app->get('/users/:id' => async sub ($c) {
    my $user_id = $c->param('id');

    # UserProfile is PerRequest scoped - cached per request
    my $profile = $c->service('UserProfile');

    # First call fetches the user
    my $user = await $profile->get_user($user_id);

    # Second call uses cached data (demonstrating PerRequest caching)
    my $prefs = await $profile->get_preferences($user_id);

    $c->json({
        user => $user,
        preferences => $prefs,
        note => 'UserProfile service was only instantiated once (PerRequest scope)',
    });
});

# Multiple async operations
$app->get('/stats' => async sub ($c) {
    my $weather = $c->service('Weather');
    my $stats = $c->service('Stats');

    # Run multiple async operations
    # In a real app, these could be concurrent with Future->wait_all
    my $weather_data = await $weather->get_forecast('Portland');
    my $visitor_count = await $stats->get_visitor_count;
    my $popular_cities = await $stats->get_popular_cities;

    $c->json({
        weather => $weather_data,
        visitors => $visitor_count,
        popular_cities => $popular_cities,
    });
});

$app->to_app;
