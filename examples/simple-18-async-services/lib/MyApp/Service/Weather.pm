package MyApp::Service::Weather;

use strict;
use warnings;
use experimental 'signatures';
use parent 'PAGI::Simple::Service::Factory';
use Future::AsyncAwait;

# =============================================================================
# Weather Service (Factory Scope)
#
# Each call to $c->service('Weather') creates a new instance.
# Uses async methods to simulate fetching weather data.
# =============================================================================

# Simulated weather data (in real app, this would be an API call)
my %weather_data = (
    Seattle   => { temp => 52, conditions => 'Cloudy', humidity => 75 },
    Portland  => { temp => 55, conditions => 'Rainy', humidity => 85 },
    'San Francisco' => { temp => 62, conditions => 'Foggy', humidity => 70 },
    'Los Angeles' => { temp => 75, conditions => 'Sunny', humidity => 45 },
    Denver    => { temp => 45, conditions => 'Clear', humidity => 30 },
    Austin    => { temp => 80, conditions => 'Sunny', humidity => 60 },
);

# Async method - returns a Future
async sub get_forecast ($self, $city) {
    # In a real app, this would be an async HTTP call:
    # my $response = await $http->get("https://api.weather.com/forecast?city=$city");

    # Simulate async operation
    my $data = $weather_data{$city} // { temp => 70, conditions => 'Unknown', humidity => 50 };

    return {
        city => $city,
        temperature => $data->{temp},
        conditions => $data->{conditions},
        humidity => $data->{humidity},
        unit => 'F',
        fetched_at => time(),
    };
}

# Another async method showing multiple awaits
async sub get_extended_forecast ($self, $city, $days) {
    my @forecast;

    for my $day (1..$days) {
        my $base = await $self->get_forecast($city);
        # Simulate variation per day
        $base->{day} = $day;
        $base->{temperature} += int(rand(10)) - 5;
        push @forecast, $base;
    }

    return \@forecast;
}

1;
