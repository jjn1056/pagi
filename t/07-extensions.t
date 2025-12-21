use strict;
use warnings;
use Test2::V0;
use IO::Async::Loop;
use Net::Async::HTTP;
use Future::AsyncAwait;

use PAGI::Server;

# Step 7: Extensions Framework
# Tests for examples/07-extension-fullflush/app.pl

my $loop = IO::Async::Loop->new;

# Load the example app
use FindBin;
use lib "$FindBin::Bin/../lib";
my $app_path = "$FindBin::Bin/../examples/07-extension-fullflush/app.pl";
my $app = do $app_path;
die "Could not load app from $app_path: $@" if $@;
die "App did not return a coderef" unless ref $app eq 'CODE';

# Test 1: Extensions are advertised in scope when enabled
subtest 'Extensions are advertised in scope.extensions' => sub {
    my $captured_scope;

    my $scope_test_app = async sub  {
        my ($scope, $receive, $send) = @_;
        # Handle lifespan scope
        if ($scope->{type} eq 'lifespan') {
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

        die "Unsupported scope type: $scope->{type}" unless $scope->{type} eq 'http';

        $captured_scope = $scope;

        # Drain request body
        while (1) {
            my $event = await $receive->();
            last if $event->{type} ne 'http.request';
            last unless $event->{more};
        }

        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [['content-type', 'text/plain']],
        });

        await $send->({
            type => 'http.response.body',
            body => 'OK',
            more => 0,
        });
    };

    # Test with fullflush extension enabled
    my $server = PAGI::Server->new(
        app        => $scope_test_app,
        host       => '127.0.0.1',
        port       => 0,
        quiet      => 1,
        extensions => { fullflush => {} },
    );

    $loop->add($server);
    $server->listen->get;

    my $http = Net::Async::HTTP->new;
    $loop->add($http);

    my $response = $http->GET("http://127.0.0.1:" . $server->port . "/")->get;

    ok(exists $captured_scope->{extensions}, 'scope.extensions exists');
    ok(ref $captured_scope->{extensions} eq 'HASH', 'scope.extensions is a hashref');
    ok(exists $captured_scope->{extensions}{fullflush}, 'scope.extensions.fullflush exists when enabled');

    $server->shutdown->get;
    $loop->remove($server);
    $loop->remove($http);
};

# Test 2: Extensions are absent when not enabled
subtest 'Extensions are absent when not enabled' => sub {
    my $captured_scope;

    my $scope_test_app = async sub  {
        my ($scope, $receive, $send) = @_;
        # Handle lifespan scope
        if ($scope->{type} eq 'lifespan') {
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

        die "Unsupported scope type: $scope->{type}" unless $scope->{type} eq 'http';

        $captured_scope = $scope;

        # Drain request body
        while (1) {
            my $event = await $receive->();
            last if $event->{type} ne 'http.request';
            last unless $event->{more};
        }

        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [['content-type', 'text/plain']],
        });

        await $send->({
            type => 'http.response.body',
            body => 'OK',
            more => 0,
        });
    };

    # Test without fullflush extension
    my $server = PAGI::Server->new(
        app   => $scope_test_app,
        host  => '127.0.0.1',
        port  => 0,
        quiet => 1,
        # No extensions specified
    );

    $loop->add($server);
    $server->listen->get;

    my $http = Net::Async::HTTP->new;
    $loop->add($http);

    my $response = $http->GET("http://127.0.0.1:" . $server->port . "/")->get;

    ok(exists $captured_scope->{extensions}, 'scope.extensions exists');
    ok(!exists $captured_scope->{extensions}{fullflush}, 'scope.extensions.fullflush does not exist when not enabled');

    $server->shutdown->get;
    $loop->remove($server);
    $loop->remove($http);
};

# Test 3: Fullflush extension works - 07-extension-fullflush app
subtest 'Fullflush extension forces immediate flush' => sub {
    my $server = PAGI::Server->new(
        app        => $app,
        host       => '127.0.0.1',
        port       => 0,
        quiet      => 1,
        extensions => { fullflush => {} },
    );

    $loop->add($server);
    $server->listen->get;

    my $http = Net::Async::HTTP->new;
    $loop->add($http);

    my $response = $http->GET("http://127.0.0.1:" . $server->port . "/")->get;

    is($response->code, 200, 'Response status is 200');
    like($response->content_type, qr{text/plain}, 'Content-Type is text/plain');

    my $body = $response->decoded_content;
    like($body, qr/Line 1/, 'Response contains Line 1');
    like($body, qr/Line 2/, 'Response contains Line 2');
    like($body, qr/Line 3/, 'Response contains Line 3');

    $server->shutdown->get;
    $loop->remove($server);
    $loop->remove($http);
};

# Test 4: Unknown extension events are rejected
subtest 'Unknown extension events are rejected' => sub {
    my $error_caught = 0;
    my $error_message = '';

    my $fullflush_test_app = async sub  {
        my ($scope, $receive, $send) = @_;
        # Handle lifespan scope
        if ($scope->{type} eq 'lifespan') {
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

        die "Unsupported scope type: $scope->{type}" unless $scope->{type} eq 'http';

        # Drain request body
        while (1) {
            my $event = await $receive->();
            last if $event->{type} ne 'http.request';
            last unless $event->{more};
        }

        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [['content-type', 'text/plain']],
        });

        await $send->({
            type => 'http.response.body',
            body => 'Line 1',
            more => 1,
        });

        # Try to use fullflush when it's not enabled - should cause error
        eval {
            await $send->({ type => 'http.fullflush' });
        };
        if ($@) {
            $error_caught = 1;
            $error_message = $@;
        }

        await $send->({
            type => 'http.response.body',
            body => 'Line 2',
            more => 0,
        });
    };

    # Server WITHOUT fullflush extension - should reject http.fullflush
    my $server = PAGI::Server->new(
        app   => $fullflush_test_app,
        host  => '127.0.0.1',
        port  => 0,
        quiet => 1,
        # No extensions - fullflush not enabled
    );

    $loop->add($server);
    $server->listen->get;

    my $http = Net::Async::HTTP->new;
    $loop->add($http);

    # Suppress expected warning
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, @_ };

    my $response = $http->GET("http://127.0.0.1:" . $server->port . "/")->get;

    # The app should have caught an error when trying to use fullflush
    ok($error_caught, 'Error was caught when using fullflush without extension');
    like($error_message, qr/fullflush/i, 'Error message mentions fullflush');

    $server->shutdown->get;
    $loop->remove($server);
    $loop->remove($http);
};

# Test 5: Fullflush works with SSE
subtest 'Fullflush extension works with SSE' => sub {
    my $sse_fullflush_app = async sub  {
        my ($scope, $receive, $send) = @_;
        # Handle lifespan scope
        if ($scope->{type} eq 'lifespan') {
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

        die "Unsupported scope type: $scope->{type}" unless $scope->{type} eq 'sse';

        await $send->({
            type   => 'sse.start',
            status => 200,
        });

        await $send->({
            type  => 'sse.send',
            event => 'test',
            data  => 'Event 1',
        });

        # Use fullflush after SSE event
        await $send->({ type => 'http.fullflush' });

        await $send->({
            type  => 'sse.send',
            event => 'done',
            data  => 'finished',
        });
    };

    my $server = PAGI::Server->new(
        app        => $sse_fullflush_app,
        host       => '127.0.0.1',
        port       => 0,
        quiet      => 1,
        extensions => { fullflush => {} },
    );

    $loop->add($server);
    $server->listen->get;

    my $http = Net::Async::HTTP->new;
    $loop->add($http);

    my $response = $http->GET(
        "http://127.0.0.1:" . $server->port . "/",
        headers => { 'Accept' => 'text/event-stream' }
    )->get;

    is($response->code, 200, 'SSE response status is 200');
    like($response->content_type, qr{text/event-stream}, 'Content-Type is text/event-stream');

    my $body = $response->decoded_content;
    like($body, qr/event: test/, 'SSE contains test event');
    like($body, qr/data: Event 1/, 'SSE contains Event 1 data');
    like($body, qr/event: done/, 'SSE contains done event');

    $server->shutdown->get;
    $loop->remove($server);
    $loop->remove($http);
};

done_testing;
