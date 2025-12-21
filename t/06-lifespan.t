use strict;
use warnings;
use Test2::V0;
use IO::Async::Loop;
use Net::Async::HTTP;
use Future::AsyncAwait;
use FindBin;
use lib "$FindBin::Bin/../lib";

use PAGI::Server;

# Step 6: Lifespan Protocol
# Tests for examples/06-lifespan-state/app.pl

my $loop = IO::Async::Loop->new;

# Load the example app
my $app_path = "$FindBin::Bin/../examples/06-lifespan-state/app.pl";
my $app = do $app_path;
die "Could not load app from $app_path: $@" if $@;
die "App did not return a coderef" unless ref $app eq 'CODE';

# Test 1: Lifespan startup initializes shared state
subtest 'Lifespan startup initializes shared state' => sub {
    my $server = PAGI::Server->new(
        app   => $app,
        host  => '127.0.0.1',
        port  => 0,
        quiet => 1,
    );

    $loop->add($server);
    $server->listen->get;

    ok($server->is_running, 'Server started after lifespan startup');

    my $port = $server->port;
    my $http = Net::Async::HTTP->new;
    $loop->add($http);

    my $response = $http->GET("http://127.0.0.1:$port/")->get;

    is($response->code, 200, 'Response status is 200');
    like($response->decoded_content, qr/Hello from lifespan/,
        'Response contains greeting from lifespan state');

    $server->shutdown->get;
    $loop->remove($server);
    $loop->remove($http);
};

# Test 2: Shared state is shallow-copied to each request
subtest 'Shared state is shallow-copied per request' => sub {
    my $lifespan_state;
    my @request_states;

    my $test_app = async sub  {
        my ($scope, $receive, $send) = @_;
        if ($scope->{type} eq 'lifespan') {
            my $state = $scope->{state};
            $state->{counter} = 0;
            $lifespan_state = $state;

            while (1) {
                my $event = await $receive->();
                if ($event->{type} eq 'lifespan.startup') {
                    await $send->({ type => 'lifespan.startup.complete' });
                }
                elsif ($event->{type} eq 'lifespan.shutdown') {
                    await $send->({ type => 'lifespan.shutdown.complete' });
                    last;
                }
            }
            return;
        }

        # Store request state reference and increment counter
        push @request_states, $scope->{state};
        $scope->{state}{counter}++;

        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [['content-type', 'text/plain']],
        });
        await $send->({
            type => 'http.response.body',
            body => "counter: " . $scope->{state}{counter},
            more => 0,
        });
    };

    my $server = PAGI::Server->new(
        app   => $test_app,
        host  => '127.0.0.1',
        port  => 0,
        quiet => 1,
    );

    $loop->add($server);
    $server->listen->get;

    my $port = $server->port;

    # Use separate HTTP clients for each request since keep-alive isn't fully supported
    my $http1 = Net::Async::HTTP->new;
    my $http2 = Net::Async::HTTP->new;
    $loop->add($http1);
    $loop->add($http2);

    # Make two requests
    my $response1 = $http1->GET("http://127.0.0.1:$port/")->get;
    my $response2 = $http2->GET("http://127.0.0.1:$port/")->get;

    is(scalar(@request_states), 2, 'Two request states captured');

    # Each request should get a shallow copy - verify they're different refs
    # but both should have started with counter = 0 (from lifespan) but each
    # modified their own copy
    like($response1->decoded_content, qr/counter: 1/, 'First request counter is 1');
    like($response2->decoded_content, qr/counter: 1/, 'Second request counter is also 1 (shallow copy)');

    $server->shutdown->get;
    $loop->remove($server);
    $loop->remove($http1);
    $loop->remove($http2);
};

# Test 3: Lifespan startup failure prevents connection acceptance
subtest 'Lifespan startup failure prevents server start' => sub {
    my $fail_app = async sub  {
        my ($scope, $receive, $send) = @_;
        if ($scope->{type} eq 'lifespan') {
            while (1) {
                my $event = await $receive->();
                if ($event->{type} eq 'lifespan.startup') {
                    await $send->({
                        type    => 'lifespan.startup.failed',
                        message => 'Intentional failure for test',
                    });
                    last;
                }
            }
            return;
        }
        die "Unsupported scope type: $scope->{type}";
    };

    my $server = PAGI::Server->new(
        app   => $fail_app,
        host  => '127.0.0.1',
        port  => 0,
        quiet => 1,
    );

    $loop->add($server);

    # Suppress warning output
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, @_ };

    my $started = 0;
    eval {
        $server->listen->get;
        $started = 1;
    };

    ok(!$started, 'Server did not start due to lifespan failure');
    ok($@ =~ /startup failed/i, 'Exception mentions startup failure');

    $loop->remove($server);
};

# Test 4: Graceful shutdown sends lifespan.shutdown event
subtest 'Graceful shutdown sends lifespan.shutdown' => sub {
    my $shutdown_received = 0;
    my $shutdown_completed = 0;

    my $test_app = async sub  {
        my ($scope, $receive, $send) = @_;
        if ($scope->{type} eq 'lifespan') {
            while (1) {
                my $event = await $receive->();
                if ($event->{type} eq 'lifespan.startup') {
                    await $send->({ type => 'lifespan.startup.complete' });
                }
                elsif ($event->{type} eq 'lifespan.shutdown') {
                    $shutdown_received = 1;
                    await $send->({ type => 'lifespan.shutdown.complete' });
                    $shutdown_completed = 1;
                    last;
                }
            }
            return;
        }

        die "Unsupported scope type: $scope->{type}" unless $scope->{type} eq 'http';

        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [['content-type', 'text/plain']],
        });
        await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
    };

    my $server = PAGI::Server->new(
        app   => $test_app,
        host  => '127.0.0.1',
        port  => 0,
        quiet => 1,
    );

    $loop->add($server);
    $server->listen->get;

    ok($server->is_running, 'Server is running');
    ok(!$shutdown_received, 'Shutdown not yet received');

    # Shutdown the server
    $server->shutdown->get;

    ok($shutdown_received, 'Shutdown event was received');
    ok($shutdown_completed, 'Shutdown was completed');
    ok(!$server->is_running, 'Server is no longer running');

    $loop->remove($server);
};

# Test 5: Apps that don't support lifespan still work
subtest 'Apps without lifespan support still work' => sub {
    my $simple_app = async sub  {
        my ($scope, $receive, $send) = @_;
        # This app only handles HTTP - throws for other scope types
        die "Unsupported scope type: $scope->{type}" unless $scope->{type} eq 'http';

        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [['content-type', 'text/plain']],
        });
        await $send->({ type => 'http.response.body', body => 'Simple app works', more => 0 });
    };

    my $server = PAGI::Server->new(
        app   => $simple_app,
        host  => '127.0.0.1',
        port  => 0,
        quiet => 1,
    );

    $loop->add($server);
    $server->listen->get;

    ok($server->is_running, 'Server started despite no lifespan support');

    my $port = $server->port;
    my $http = Net::Async::HTTP->new;
    $loop->add($http);

    my $response = $http->GET("http://127.0.0.1:$port/")->get;

    is($response->code, 200, 'Response status is 200');
    like($response->decoded_content, qr/Simple app works/, 'App works without lifespan');

    $server->shutdown->get;
    $loop->remove($server);
    $loop->remove($http);
};

done_testing;
