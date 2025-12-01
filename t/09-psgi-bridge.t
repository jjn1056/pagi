use strict;
use warnings;
use experimental 'signatures';
use Test2::V0;
use IO::Async::Loop;
use Net::Async::HTTP;
use Future::AsyncAwait;
use FindBin;

use PAGI::Server;
use PAGI::App::WrapPSGI;

# Step 9: PSGI Compatibility Bridge
# Tests for examples/09-psgi-bridge/app.pl

my $loop = IO::Async::Loop->new;

# Load the example app
my $app_path = "$FindBin::Bin/../examples/09-psgi-bridge/app.pl";
my $app = do $app_path;
die "Could not load app from $app_path: $@" if $@;
die "App did not return a coderef" unless ref $app eq 'CODE';

# Test 1: PSGI bridge runs legacy PSGI apps
subtest 'PSGI bridge runs legacy PSGI apps - 09-psgi-bridge app' => sub {
    my $server = PAGI::Server->new(
        app   => $app,
        host  => '127.0.0.1',
        port  => 0,
        quiet => 1,
    );

    $loop->add($server);
    $server->listen->get;

    my $port = $server->port;

    my $http = Net::Async::HTTP->new;
    $loop->add($http);

    my $response = $http->GET("http://127.0.0.1:$port/")->get;

    is($response->code, 200, 'Response status is 200 OK');
    like($response->decoded_content, qr/PSGI says hi/, 'Response contains "PSGI says hi"');

    $server->shutdown->get;
    $loop->remove($server);
    $loop->remove($http);
};

# Test 2: PSGI bridge passes request body to psgi.input
subtest 'PSGI bridge passes request body to psgi.input' => sub {
    my $server = PAGI::Server->new(
        app   => $app,
        host  => '127.0.0.1',
        port  => 0,
        quiet => 1,
    );

    $loop->add($server);
    $server->listen->get;

    my $port = $server->port;

    my $http = Net::Async::HTTP->new;
    $loop->add($http);

    my $response = $http->POST(
        "http://127.0.0.1:$port/",
        'test data',
        content_type => 'text/plain',
    )->get;

    is($response->code, 200, 'POST response status is 200 OK');
    like($response->decoded_content, qr/Body: test data/, 'Response contains "Body: test data"');

    $server->shutdown->get;
    $loop->remove($server);
    $loop->remove($http);
};

# Test 3: PSGI env contains all required keys
subtest 'PSGI env contains all required keys' => sub {
    my $captured_env;

    my $env_dump_psgi = sub {
        my ($env) = @_;
        $captured_env = { %$env };
        delete $captured_env->{'psgi.input'};  # Can't easily serialize filehandle
        delete $captured_env->{'psgi.errors'}; # Can't easily serialize filehandle
        return [200, ['Content-Type' => 'text/plain'], ['OK']];
    };

    my $wrapper = PAGI::App::WrapPSGI->new(psgi_app => $env_dump_psgi);
    my $pagi_app = $wrapper->to_app;

    # Wrap with lifespan handler
    my $wrapped_app = async sub ($scope, $receive, $send) {
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
        await $pagi_app->($scope, $receive, $send);
    };

    my $server = PAGI::Server->new(
        app   => $wrapped_app,
        host  => '127.0.0.1',
        port  => 0,
        quiet => 1,
    );

    $loop->add($server);
    $server->listen->get;

    my $port = $server->port;

    my $http = Net::Async::HTTP->new;
    $loop->add($http);

    my $response = $http->GET(
        "http://127.0.0.1:$port/test/path?query=value",
        headers => {
            'X-Custom-Header' => 'custom-value',
        },
    )->get;

    is($response->code, 200, 'Response status is 200 OK');

    # Verify required PSGI env keys
    is($captured_env->{REQUEST_METHOD}, 'GET', 'REQUEST_METHOD is GET');
    is($captured_env->{SCRIPT_NAME}, '', 'SCRIPT_NAME is set');
    is($captured_env->{PATH_INFO}, '/test/path', 'PATH_INFO is correct');
    is($captured_env->{QUERY_STRING}, 'query=value', 'QUERY_STRING is correct');
    is($captured_env->{SERVER_PROTOCOL}, 'HTTP/1.1', 'SERVER_PROTOCOL is correct');
    is($captured_env->{SERVER_NAME}, '127.0.0.1', 'SERVER_NAME is correct');
    ok($captured_env->{SERVER_PORT} > 0, 'SERVER_PORT is set');
    is($captured_env->{REMOTE_ADDR}, '127.0.0.1', 'REMOTE_ADDR is correct');
    ok($captured_env->{REMOTE_PORT} > 0, 'REMOTE_PORT is set');
    is($captured_env->{HTTP_X_CUSTOM_HEADER}, 'custom-value', 'HTTP_* headers are set');

    # Verify psgi.* keys
    is(ref $captured_env->{'psgi.version'}, 'ARRAY', 'psgi.version is arrayref');
    is($captured_env->{'psgi.url_scheme'}, 'http', 'psgi.url_scheme is http');

    $server->shutdown->get;
    $loop->remove($server);
    $loop->remove($http);
};

# Test 4: PSGI array body response works
subtest 'PSGI array body response works' => sub {
    my $array_body_psgi = sub {
        my ($env) = @_;
        return [200, ['Content-Type' => 'text/plain'], ['Part 1', ' ', 'Part 2']];
    };

    my $wrapper = PAGI::App::WrapPSGI->new(psgi_app => $array_body_psgi);
    my $pagi_app = $wrapper->to_app;

    # Wrap with lifespan handler
    my $wrapped_app = async sub ($scope, $receive, $send) {
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
        await $pagi_app->($scope, $receive, $send);
    };

    my $server = PAGI::Server->new(
        app   => $wrapped_app,
        host  => '127.0.0.1',
        port  => 0,
        quiet => 1,
    );

    $loop->add($server);
    $server->listen->get;

    my $port = $server->port;

    my $http = Net::Async::HTTP->new;
    $loop->add($http);

    my $response = $http->GET("http://127.0.0.1:$port/")->get;

    is($response->code, 200, 'Response status is 200 OK');
    is($response->decoded_content, 'Part 1 Part 2', 'Array body parts are joined');

    $server->shutdown->get;
    $loop->remove($server);
    $loop->remove($http);
};

# Test 5: PSGI filehandle body response works
subtest 'PSGI filehandle body response works' => sub {
    my $content = "Hello from filehandle";
    open my $fh, '<', \$content;

    my $fh_body_psgi = sub {
        my ($env) = @_;
        open my $body_fh, '<', \$content;
        return [200, ['Content-Type' => 'text/plain'], $body_fh];
    };

    my $wrapper = PAGI::App::WrapPSGI->new(psgi_app => $fh_body_psgi);
    my $pagi_app = $wrapper->to_app;

    # Wrap with lifespan handler
    my $wrapped_app = async sub ($scope, $receive, $send) {
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
        await $pagi_app->($scope, $receive, $send);
    };

    my $server = PAGI::Server->new(
        app   => $wrapped_app,
        host  => '127.0.0.1',
        port  => 0,
        quiet => 1,
    );

    $loop->add($server);
    $server->listen->get;

    my $port = $server->port;

    my $http = Net::Async::HTTP->new;
    $loop->add($http);

    my $response = $http->GET("http://127.0.0.1:$port/")->get;

    is($response->code, 200, 'Response status is 200 OK');
    is($response->decoded_content, 'Hello from filehandle', 'Filehandle body is read correctly');

    $server->shutdown->get;
    $loop->remove($server);
    $loop->remove($http);
};

# Test 6: PSGI streaming response (coderef body) works
subtest 'PSGI streaming response (coderef body) works' => sub {
    my $streaming_psgi = sub {
        my ($env) = @_;
        return sub {
            my ($responder) = @_;
            # Immediate response with streaming body
            my $writer = $responder->([200, ['Content-Type' => 'text/plain']]);
            $writer->write("Streaming ");
            $writer->write("response");
            $writer->close;
        };
    };

    my $wrapper = PAGI::App::WrapPSGI->new(psgi_app => $streaming_psgi);
    my $pagi_app = $wrapper->to_app;

    # Wrap with lifespan handler
    my $wrapped_app = async sub ($scope, $receive, $send) {
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
        await $pagi_app->($scope, $receive, $send);
    };

    my $server = PAGI::Server->new(
        app   => $wrapped_app,
        host  => '127.0.0.1',
        port  => 0,
        quiet => 1,
    );

    $loop->add($server);
    $server->listen->get;

    my $port = $server->port;

    my $http = Net::Async::HTTP->new;
    $loop->add($http);

    my $response = $http->GET("http://127.0.0.1:$port/")->get;

    is($response->code, 200, 'Streaming response status is 200 OK');
    is($response->decoded_content, 'Streaming response', 'Streaming body is collected correctly');

    $server->shutdown->get;
    $loop->remove($server);
    $loop->remove($http);
};

done_testing;
