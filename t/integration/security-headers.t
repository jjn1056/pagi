use strict;
use warnings;
use Test2::V0;
use IO::Async::Loop;
use Net::Async::HTTP;
use Future::AsyncAwait;

use PAGI::Server;

plan skip_all => "Server integration tests not supported on Windows" if $^O eq 'MSWin32';
use PAGI::Middleware::Builder;

my $loop = IO::Async::Loop->new;

# Simple test app that returns 200 OK
my $simple_app = async sub  {
        my ($scope, $receive, $send) = @_;
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

# Test 1: Default security headers are added
subtest 'Default security headers are added' => sub {
    my $app = builder {
        enable 'SecurityHeaders';
        $simple_app;
    };

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

    is($response->code, 200, 'Response status is 200');

    # Check default security headers
    is($response->header('X-Frame-Options'), 'SAMEORIGIN', 'X-Frame-Options default is SAMEORIGIN');
    is($response->header('X-Content-Type-Options'), 'nosniff', 'X-Content-Type-Options default is nosniff');
    is($response->header('X-XSS-Protection'), '1; mode=block', 'X-XSS-Protection default is 1; mode=block');
    is($response->header('Referrer-Policy'), 'strict-origin-when-cross-origin', 'Referrer-Policy default is strict-origin-when-cross-origin');

    # HSTS should NOT be present for HTTP (only HTTPS)
    ok(!$response->header('Strict-Transport-Security'), 'No HSTS header for HTTP');

    $server->shutdown->get;
    $loop->remove($server);
    $loop->remove($http);
};

# Test 2: Custom header values
subtest 'Custom header values are respected' => sub {
    my $app = builder {
        enable 'SecurityHeaders',
            x_frame_options        => 'DENY',
            x_content_type_options => 'nosniff',
            x_xss_protection       => '0',
            referrer_policy        => 'no-referrer';
        $simple_app;
    };

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

    is($response->code, 200, 'Response status is 200');
    is($response->header('X-Frame-Options'), 'DENY', 'X-Frame-Options is DENY');
    is($response->header('X-XSS-Protection'), '0', 'X-XSS-Protection is 0');
    is($response->header('Referrer-Policy'), 'no-referrer', 'Referrer-Policy is no-referrer');

    $server->shutdown->get;
    $loop->remove($server);
    $loop->remove($http);
};

# Test 3: Headers can be disabled with undef
subtest 'Headers can be disabled with undef' => sub {
    my $app = builder {
        enable 'SecurityHeaders',
            x_frame_options        => undef,
            x_xss_protection       => undef;
        $simple_app;
    };

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

    is($response->code, 200, 'Response status is 200');
    ok(!$response->header('X-Frame-Options'), 'X-Frame-Options disabled');
    ok(!$response->header('X-XSS-Protection'), 'X-XSS-Protection disabled');

    # These should still be present (not disabled)
    is($response->header('X-Content-Type-Options'), 'nosniff', 'X-Content-Type-Options still present');
    is($response->header('Referrer-Policy'), 'strict-origin-when-cross-origin', 'Referrer-Policy still present');

    $server->shutdown->get;
    $loop->remove($server);
    $loop->remove($http);
};

# Test 4: Content-Security-Policy can be set
subtest 'Content-Security-Policy can be set' => sub {
    my $csp = "default-src 'self'; script-src 'self' 'unsafe-inline'";

    my $app = builder {
        enable 'SecurityHeaders',
            content_security_policy => $csp;
        $simple_app;
    };

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

    is($response->code, 200, 'Response status is 200');
    is($response->header('Content-Security-Policy'), $csp, 'CSP header is set correctly');

    $server->shutdown->get;
    $loop->remove($server);
    $loop->remove($http);
};

# Test 5: Permissions-Policy can be set
subtest 'Permissions-Policy can be set' => sub {
    my $permissions = "geolocation=(), microphone=(), camera=()";

    my $app = builder {
        enable 'SecurityHeaders',
            permissions_policy => $permissions;
        $simple_app;
    };

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

    is($response->code, 200, 'Response status is 200');
    is($response->header('Permissions-Policy'), $permissions, 'Permissions-Policy header is set correctly');

    $server->shutdown->get;
    $loop->remove($server);
    $loop->remove($http);
};

# Test 6: Non-HTTP scopes are passed through
subtest 'Non-HTTP scopes pass through unchanged' => sub {
    my $ws_connected = 0;

    my $ws_app = async sub  {
        my ($scope, $receive, $send) = @_;
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

        if ($scope->{type} eq 'websocket') {
            $ws_connected = 1;
            await $send->({ type => 'websocket.close' });
            return;
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

    my $app = builder {
        enable 'SecurityHeaders';
        $ws_app;
    };

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

    # Normal HTTP should work with headers
    my $response = $http->GET("http://127.0.0.1:$port/")->get;
    is($response->code, 200, 'HTTP response is 200');
    ok($response->header('X-Frame-Options'), 'Security headers present for HTTP');

    $server->shutdown->get;
    $loop->remove($server);
    $loop->remove($http);
};

# Test 7: All headers together (comprehensive test)
subtest 'All security headers together' => sub {
    my $app = builder {
        enable 'SecurityHeaders',
            x_frame_options           => 'DENY',
            x_content_type_options    => 'nosniff',
            x_xss_protection          => '1; mode=block',
            referrer_policy           => 'strict-origin',
            content_security_policy   => "default-src 'self'",
            permissions_policy        => "geolocation=()";
        $simple_app;
    };

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

    is($response->code, 200, 'Response status is 200');
    is($response->header('X-Frame-Options'), 'DENY', 'X-Frame-Options');
    is($response->header('X-Content-Type-Options'), 'nosniff', 'X-Content-Type-Options');
    is($response->header('X-XSS-Protection'), '1; mode=block', 'X-XSS-Protection');
    is($response->header('Referrer-Policy'), 'strict-origin', 'Referrer-Policy');
    is($response->header('Content-Security-Policy'), "default-src 'self'", 'Content-Security-Policy');
    is($response->header('Permissions-Policy'), "geolocation=()", 'Permissions-Policy');

    $server->shutdown->get;
    $loop->remove($server);
    $loop->remove($http);
};

done_testing;
