#!/usr/bin/env perl
use strict;
use warnings;
use lib 'lib';
use Future::AsyncAwait;

# Configure Future::IO for SSE->every() support
# This must be done before using any Future::IO features
use Future::IO;
Future::IO->load_impl('IOAsync');

use MyApp::Main;
use PAGI::Lifespan;

my $router = MyApp::Main->new;

# Wrap with lifecycle management
PAGI::Lifespan->wrap(
    $router->to_app,
    startup => async sub {
        my ($state) = @_;
        warn "MyApp starting up...\n";

        # Populate state - this is injected into every request
        # Access via $req->state, $ws->state, or $sse->state
        $state->{config} = {
            app_name => 'Endpoint Router Demo',
            version  => '1.0.0',
        };
        $state->{metrics} = {
            requests  => 0,
            ws_active => 0,
        };

        warn "MyApp ready!\n";
    },
    shutdown => async sub {
        my ($state) = @_;
        warn "MyApp shutting down...\n";
        # $state->{db}->disconnect if using database connections
    },
);
