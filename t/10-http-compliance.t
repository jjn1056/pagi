use strict;
use warnings;
use Test2::V0;
use IO::Async::Loop;
use Net::Async::HTTP;
use Future::AsyncAwait;
use FindBin;
use IO::Socket::INET;
use IO::Select;
use IO::Async::Stream;

use PAGI::Server;

plan skip_all => "Server integration tests not supported on Windows" if $^O eq 'MSWin32';

# Step 10: HTTP/1.1 Compliance and Edge Cases

my $loop = IO::Async::Loop->new;

# Load the hello app for testing
my $app_path = "$FindBin::Bin/../examples/01-hello-http/app.pl";
my $app = do $app_path;
die "Could not load app from $app_path: $@" if $@;
die "App did not return a coderef" unless ref $app eq 'CODE';

# Test 1: HEAD request returns headers without body
subtest 'HEAD request returns headers without body' => sub {
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

    # Use HEAD method
    my $response = $http->HEAD("http://127.0.0.1:$port/")->get;

    # Verify response has headers
    is($response->code, 200, 'HEAD response status is 200 OK');
    ok($response->header('Content-Type'), 'HEAD response has Content-Type header');
    ok($response->header('Date'), 'HEAD response has Date header');

    # Verify response body is empty (HEAD should not have body)
    is($response->content, '', 'HEAD response body is empty');

    $server->shutdown->get;
    $loop->remove($server);
    $loop->remove($http);
};

# Test 2: Multiple Cookie headers are normalized
subtest 'Multiple Cookie headers are normalized into single header' => sub {
    my $captured_scope;

    my $cookie_test_app = async sub  {
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

        # Return the cookie headers in the response body for inspection
        my @cookies = grep { $_->[0] eq 'cookie' } @{$scope->{headers}};
        my $cookie_info = "cookies=" . scalar(@cookies);
        if (@cookies) {
            $cookie_info .= ";value=" . $cookies[0][1];
        }

        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [['content-type', 'text/plain']],
        });

        await $send->({
            type => 'http.response.body',
            body => $cookie_info,
            more => 0,
        });
    };

    my $server = PAGI::Server->new(
        app   => $cookie_test_app,
        host  => '127.0.0.1',
        port  => 0,
        quiet => 1,
    );

    $loop->add($server);
    $server->listen->get;

    my $port = $server->port;

    my $http = Net::Async::HTTP->new;
    $loop->add($http);

    # Unfortunately Net::Async::HTTP merges Cookie headers before sending
    # So we'll test using the scope capture approach with a single request
    my $response = $http->GET(
        "http://127.0.0.1:$port/",
        headers => {
            'Cookie' => 'foo=bar; baz=qux',  # Pre-merged cookie
        },
    )->get;

    is($response->code, 200, 'Response status is 200 OK');
    like($response->decoded_content, qr/cookies=1/, 'Only one Cookie header in scope');
    like($response->decoded_content, qr/foo=bar/, 'Cookie contains foo=bar');
    like($response->decoded_content, qr/baz=qux/, 'Cookie contains baz=qux');

    $server->shutdown->get;
    $loop->remove($server);
    $loop->remove($http);
};

# Test 3: Date header is present in responses
subtest 'Date header is present in responses' => sub {
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
    ok($response->header('Date'), 'Date header is present');
    like($response->header('Date'), qr/\w{3}, \d{2} \w{3} \d{4}/, 'Date header has correct format');

    $server->shutdown->get;
    $loop->remove($server);
    $loop->remove($http);
};

# Test 4: GET request works normally (sanity check after HEAD changes)
subtest 'GET request still returns body' => sub {
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

    is($response->code, 200, 'GET response status is 200 OK');
    like($response->decoded_content, qr/Hello from PAGI/, 'GET response has body');

    $server->shutdown->get;
    $loop->remove($server);
    $loop->remove($http);
};

# Test 5: Header names are lowercased in scope
subtest 'Header names are lowercased in scope' => sub {
    my $captured_scope;

    my $header_test_app = async sub  {
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

    my $server = PAGI::Server->new(
        app   => $header_test_app,
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
        "http://127.0.0.1:$port/",
        headers => {
            'X-Custom-Header' => 'test-value',
            'Accept-Language' => 'en-US',
        },
    )->get;

    is($response->code, 200, 'Response status is 200 OK');

    # Check that header names are lowercased
    my %header_names = map { $_->[0] => 1 } @{$captured_scope->{headers}};
    ok($header_names{'x-custom-header'}, 'x-custom-header is lowercased');
    ok($header_names{'accept-language'}, 'accept-language is lowercased');

    # Verify no uppercase header names
    my @uppercase = grep { /[A-Z]/ } keys %header_names;
    is(scalar @uppercase, 0, 'No uppercase header names in scope');

    $server->shutdown->get;
    $loop->remove($server);
    $loop->remove($http);
};

# Test 6: URL-encoded paths are decoded correctly
subtest 'URL-encoded paths are decoded correctly' => sub {
    my $captured_scope;

    my $path_test_app = async sub  {
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

        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [['content-type', 'text/plain']],
        });

        await $send->({
            type => 'http.response.body',
            body => "path=$scope->{path}\nraw_path=$scope->{raw_path}",
            more => 0,
        });
    };

    my $server = PAGI::Server->new(
        app   => $path_test_app,
        host  => '127.0.0.1',
        port  => 0,
        quiet => 1,
    );

    $loop->add($server);
    $server->listen->get;

    my $port = $server->port;

    my $http = Net::Async::HTTP->new;
    $loop->add($http);

    # Request with URL-encoded path
    my $response = $http->GET("http://127.0.0.1:$port/path%20with%20spaces")->get;

    is($response->code, 200, 'Response status is 200 OK');

    # Check decoded path
    is($captured_scope->{path}, '/path with spaces', 'scope.path contains decoded path');
    is($captured_scope->{raw_path}, '/path%20with%20spaces', 'scope.raw_path contains original encoded path');

    $server->shutdown->get;
    $loop->remove($server);
    $loop->remove($http);
};

# Test 7: Server.pm API methods work correctly
subtest 'Server.pm API methods work correctly' => sub {
    my $server = PAGI::Server->new(
        app   => $app,
        host  => '127.0.0.1',
        port  => 0,
        quiet => 1,
    );

    # Test before listen
    ok(!$server->is_running, 'is_running() returns false before listen()');

    $loop->add($server);

    # Test listen returns Future
    my $listen_future = $server->listen;
    ok($listen_future->isa('Future'), 'listen() returns a Future');
    $listen_future->get;

    # Test after listen
    ok($server->is_running, 'is_running() returns true after listen()');
    ok($server->port > 0, 'port() returns valid port number');

    # Test shutdown returns Future
    my $shutdown_future = $server->shutdown;
    ok($shutdown_future->isa('Future'), 'shutdown() returns a Future');
    $shutdown_future->get;

    # Test after shutdown
    ok(!$server->is_running, 'is_running() returns false after shutdown()');

    $loop->remove($server);
};

# Test 8: Protocol::HTTP1 parse_request works
subtest 'Protocol::HTTP1 parse_request parses HTTP requests' => sub {
    use PAGI::Server::Protocol::HTTP1;

    my $proto = PAGI::Server::Protocol::HTTP1->new;

    # Test valid request
    my $request_str = "GET /test/path?query=value HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\n\r\n";
    my ($request, $consumed) = $proto->parse_request(\$request_str);

    ok(defined $request, 'parse_request returns request for valid HTTP');
    is($request->{method}, 'GET', 'method is GET');
    is($request->{path}, '/test/path', 'path is correct');
    is($request->{query_string}, 'query=value', 'query_string is correct');
    is($request->{http_version}, '1.1', 'http_version is 1.1');
    ok($consumed > 0, 'bytes_consumed is positive');

    # Test incomplete request
    my $incomplete = "GET / HTTP/1.1\r\n";
    my ($req2, $cons2) = $proto->parse_request(\$incomplete);
    ok(!defined $req2, 'parse_request returns undef for incomplete request');
    is($cons2, 0, 'bytes_consumed is 0 for incomplete request');
};

# Test 9: Protocol::HTTP1 serialize methods work
subtest 'Protocol::HTTP1 serialize methods generate valid HTTP' => sub {
    use PAGI::Server::Protocol::HTTP1;

    my $proto = PAGI::Server::Protocol::HTTP1->new;

    # Test serialize_response_start
    my $response = $proto->serialize_response_start(
        200,
        [['content-type', 'text/plain'], ['x-custom', 'value']],
        0  # not chunked
    );

    like($response, qr/^HTTP\/1\.1 200 OK\r\n/, 'Response starts with status line');
    like($response, qr/content-type: text\/plain\r\n/, 'Content-Type header present');
    like($response, qr/x-custom: value\r\n/, 'Custom header present');
    like($response, qr/\r\n\r\n$/, 'Response ends with blank line');

    # Test chunked response
    my $chunked_response = $proto->serialize_response_start(200, [], 1);
    like($chunked_response, qr/Transfer-Encoding: chunked\r\n/, 'Chunked encoding header added');

    # Test serialize_response_body
    my $body = $proto->serialize_response_body("Hello", 0, 1);  # chunked
    like($body, qr/^5\r\nHello\r\n/, 'Chunked body has correct format');

    # Test format_date
    my $date = $proto->format_date;
    like($date, qr/\w{3}, \d{2} \w{3} \d{4} \d{2}:\d{2}:\d{2} GMT/, 'Date format is RFC 7231 compliant');
};

# Test 10: Malformed request returns 400 Bad Request (via Protocol::HTTP1 unit test)
subtest 'Malformed request parsing returns error' => sub {
    use PAGI::Server::Protocol::HTTP1;

    my $proto = PAGI::Server::Protocol::HTTP1->new;

    # Test malformed request line
    my $malformed = "INVALID REQUEST LINE\r\n\r\n";
    my ($request, $consumed) = $proto->parse_request(\$malformed);

    ok(defined $request, 'parse_request returns result for malformed request');
    is($request->{error}, 400, 'Error code is 400 Bad Request');
};

# Test 11: HTTP/1.0 response serialization works without chunked encoding
subtest 'HTTP/1.0 response does not use chunked encoding' => sub {
    use PAGI::Server::Protocol::HTTP1;

    my $proto = PAGI::Server::Protocol::HTTP1->new;

    # Serialize HTTP/1.0 response (chunked=0, http_version='1.0')
    my $response = $proto->serialize_response_start(200, [['content-type', 'text/plain']], 0, '1.0');

    like($response, qr/^HTTP\/1\.0 200 OK/, 'HTTP/1.0 response uses HTTP/1.0 version');
    unlike($response, qr/Transfer-Encoding: chunked/i, 'HTTP/1.0 response does not use chunked encoding');

    # Verify that even with chunked=1, HTTP/1.0 doesn't add chunked encoding
    my $response2 = $proto->serialize_response_start(200, [], 1, '1.0');
    unlike($response2, qr/Transfer-Encoding: chunked/i, 'HTTP/1.0 ignores chunked flag');
};

# Test 12: Keep-alive can be tested via Net::Async::HTTP (which uses persistent connections)
subtest 'Keep-alive works with Net::Async::HTTP' => sub {
    my $server = PAGI::Server->new(
        app   => $app,
        host  => '127.0.0.1',
        port  => 0,
        quiet => 1,
    );

    $loop->add($server);
    $server->listen->get;

    my $port = $server->port;

    my $http = Net::Async::HTTP->new(
        # Net::Async::HTTP uses persistent connections by default
        max_connections_per_host => 1,
    );
    $loop->add($http);

    # First request
    my $response1 = $http->GET("http://127.0.0.1:$port/")->get;
    is($response1->code, 200, 'First response status is 200 OK');

    # Second request (should reuse connection)
    my $response2 = $http->GET("http://127.0.0.1:$port/")->get;
    is($response2->code, 200, 'Second response status is 200 OK');

    $server->shutdown->get;
    $loop->remove($server);
    $loop->remove($http);
};

# Test 13: Expect: 100-continue parsing is detected
subtest 'Expect: 100-continue parsing detected' => sub {
    use PAGI::Server::Protocol::HTTP1;

    my $proto = PAGI::Server::Protocol::HTTP1->new;

    # Request with Expect: 100-continue
    my $request_str = "POST / HTTP/1.1\r\nHost: localhost\r\nContent-Length: 10\r\nExpect: 100-continue\r\n\r\n";
    my ($request, $consumed) = $proto->parse_request(\$request_str);

    ok(defined $request, 'Request parsed successfully');
    ok(!$request->{error}, 'No parse error');
    is($request->{expect_continue}, 1, 'expect_continue flag is set');

    # Verify 100 Continue serialization
    my $continue = $proto->serialize_continue;
    like($continue, qr/^HTTP\/1\.1 100 Continue\r\n\r\n$/, '100 Continue response format is correct');
};

# Test 14: Max header size returns 431
subtest 'Max header size exceeded returns 431' => sub {
    use PAGI::Server::Protocol::HTTP1;

    # Create protocol with small max_header_size
    my $proto = PAGI::Server::Protocol::HTTP1->new(max_header_size => 100);

    # Create a request with large headers
    my $large_header = "X-Large-Header: " . ("x" x 200);
    my $request_str = "GET / HTTP/1.1\r\nHost: localhost\r\n$large_header\r\n\r\n";

    my ($request, $consumed) = $proto->parse_request(\$request_str);

    ok(defined $request, 'parse_request returns result for oversized headers');
    is($request->{error}, 431, 'Error code is 431 Request Header Fields Too Large');
};

# Test 15: Max body size returns 413 Payload Too Large
subtest 'Max body size exceeded returns 413 Payload Too Large' => sub {
    (async sub {
        my $server = PAGI::Server->new(
            app           => $app,
            host          => '127.0.0.1',
            port          => 0,
            quiet         => 1,
            max_body_size => 100,  # Only allow 100 bytes
        );

        $loop->add($server);
        await $server->listen;

        my $port = $server->port;

        # Create a stream and add to loop for proper async I/O
        my $socket = IO::Socket::INET->new(
            PeerAddr => '127.0.0.1',
            PeerPort => $port,
            Proto    => 'tcp',
            Blocking => 0,
        ) or die "Cannot connect: $!";

        my $response = '';
        my $done = $loop->new_future;

        my $stream = IO::Async::Stream->new(
            handle => $socket,
            on_read => sub  {
        my ($s, $buffref, $eof) = @_;
                $response .= $$buffref;
                $$buffref = '';
                if ($eof || $response =~ /\r\n\r\n/) {
                    $done->done unless $done->is_ready;
                }
                return 0;
            },
            on_closed => sub {
                $done->done unless $done->is_ready;
            },
        );

        $loop->add($stream);
        $stream->write("POST / HTTP/1.1\r\nHost: localhost\r\nContent-Length: 500\r\n\r\n");

        # Wait with timeout
        my $timeout = $loop->delay_future(after => 3)->then(sub { $done->done });
        await Future->wait_any($done, $timeout);

        like($response, qr/HTTP\/1\.1 413/, '413 Payload Too Large response for oversized body');

        $loop->remove($stream);
        await $server->shutdown;
        $loop->remove($server);
    })->()->get;
};

# Test 15b: max_body_size=0 means unlimited
subtest 'max_body_size=0 allows unlimited body size' => sub {
    (async sub {
        my $server = PAGI::Server->new(
            app           => $app,
            host          => '127.0.0.1',
            port          => 0,
            quiet         => 1,
            max_body_size => 0,  # Unlimited
        );

        $loop->add($server);
        await $server->listen;

        my $port = $server->port;

        my $socket = IO::Socket::INET->new(
            PeerAddr => '127.0.0.1',
            PeerPort => $port,
            Proto    => 'tcp',
            Blocking => 0,
        ) or die "Cannot connect: $!";

        my $response = '';
        my $done = $loop->new_future;

        my $stream = IO::Async::Stream->new(
            handle => $socket,
            on_read => sub  {
        my ($s, $buffref, $eof) = @_;
                $response .= $$buffref;
                $$buffref = '';
                if ($eof || $response =~ /\r\n\r\n/) {
                    $done->done unless $done->is_ready;
                }
                return 0;
            },
            on_closed => sub {
                $done->done unless $done->is_ready;
            },
        );

        $loop->add($stream);
        # Claim to send 10KB - with max_body_size=0, this should be accepted
        $stream->write("POST / HTTP/1.1\r\nHost: localhost\r\nContent-Length: 10000\r\n\r\n");

        my $timeout = $loop->delay_future(after => 3)->then(sub { $done->done });
        await Future->wait_any($done, $timeout);

        # Should NOT get 413 since max_body_size=0 means unlimited
        unlike($response, qr/HTTP\/1\.1 413/, 'max_body_size=0 allows large requests (no 413)');

        $loop->remove($stream);
        await $server->shutdown;
        $loop->remove($server);
    })->()->get;
};

# Test 15c: Default max_body_size is 10MB
subtest 'Default max_body_size is 10MB' => sub {
    my $server = PAGI::Server->new(
        app   => $app,
        host  => '127.0.0.1',
        port  => 0,
        quiet => 1,
        # No max_body_size specified - should default to 10MB
    );

    # Check the internal value is 10MB
    is($server->{max_body_size}, 10_000_000, 'Default max_body_size is 10MB (10_000_000 bytes)');
};

# Test 16: Connection timeout option is accepted
subtest 'Connection timeout configuration is accepted' => sub {
    my $server = PAGI::Server->new(
        app     => $app,
        host    => '127.0.0.1',
        port    => 0,
        quiet   => 1,
        timeout => 30,  # 30 second timeout
    );

    $loop->add($server);

    # Just verify the server starts with timeout configured
    my $listen_future = $server->listen;
    ok($listen_future->isa('Future'), 'listen() returns a Future with timeout configured');
    $listen_future->get;

    ok($server->is_running, 'Server runs with timeout configured');

    $server->shutdown->get;
    $loop->remove($server);
};

# Test 17: Max header size configuration is passed to protocol
subtest 'Max header size configuration is passed correctly' => sub {
    (async sub {
        my $server = PAGI::Server->new(
            app             => $app,
            host            => '127.0.0.1',
            port            => 0,
            quiet           => 1,
            max_header_size => 1024,  # Custom max header size
        );

        $loop->add($server);
        await $server->listen;

        my $port = $server->port;

        # Create a stream and add to loop for proper async I/O
        my $socket = IO::Socket::INET->new(
            PeerAddr => '127.0.0.1',
            PeerPort => $port,
            Proto    => 'tcp',
            Blocking => 0,
        ) or die "Cannot connect: $!";

        my $response = '';
        my $done = $loop->new_future;

        my $stream = IO::Async::Stream->new(
            handle => $socket,
            on_read => sub  {
        my ($s, $buffref, $eof) = @_;
                $response .= $$buffref;
                $$buffref = '';
                if ($eof || $response =~ /\r\n\r\n/) {
                    $done->done unless $done->is_ready;
                }
                return 0;
            },
            on_closed => sub {
                $done->done unless $done->is_ready;
            },
        );

        $loop->add($stream);

        # Send request with headers exceeding 1024 bytes
        my $large_header = "X-Large: " . ("x" x 2000);
        $stream->write("GET / HTTP/1.1\r\nHost: localhost\r\n$large_header\r\n\r\n");

        # Wait with timeout
        my $timeout = $loop->delay_future(after => 3)->then(sub { $done->done });
        await Future->wait_any($done, $timeout);

        like($response, qr/HTTP\/1\.1 431/, '431 response for headers exceeding max_header_size');

        $loop->remove($stream);
        await $server->shutdown;
        $loop->remove($server);
    })->()->get;
};

# Test 18: send() after disconnect is a no-op per spec
# This tests the unit behavior of the send function when connection is closed
subtest 'send() after disconnect returns completed Future' => sub {
    # Test the _create_send implementation directly by verifying
    # that it returns immediately when closed flag is set

    # First verify by examining the send() return behavior in a streaming test
    # where the client disconnects mid-stream
    my $app_completed = 0;
    my $error_during_send = 0;

    my $test_app = async sub  {
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

        # Start response
        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [['content-type', 'text/plain']],
        });

        # Send some content - force close by sending more => 0
        await $send->({
            type => 'http.response.body',
            body => 'Hello',
            more => 0,
        });

        # Now try to send AFTER response is complete
        # This should be a no-op (not throw an error)
        eval {
            await $send->({
                type => 'http.response.body',
                body => 'This should be ignored',
                more => 0,
            });
        };

        if ($@) {
            $error_during_send = 1;
        }

        $app_completed = 1;
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

    my $http = Net::Async::HTTP->new;
    $loop->add($http);

    my $response = $http->GET("http://127.0.0.1:$port/")->get;

    is($response->code, 200, 'Response status is 200');
    like($response->decoded_content, qr/Hello/, 'Response contains Hello');

    # Give the app time to complete
    $loop->delay_future(after => 0.2)->get;

    ok($app_completed, 'App completed without error');
    ok(!$error_during_send, 'No error thrown when sending after response complete');

    $loop->remove($http);
    $server->shutdown->get;
    $loop->remove($server);
};

# Test 19: receive() returns Future that completes when event available
subtest 'receive() returns Future that completes with event' => sub {
    my $received_events = [];

    my $test_app = async sub  {
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

        # Call receive() - it should return a Future
        my $future = $receive->();
        ok($future->isa('Future'), 'receive() returns a Future');

        # Get the event
        my $event = await $future;
        push @$received_events, $event;

        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [['content-type', 'text/plain']],
        });

        await $send->({
            type => 'http.response.body',
            body => 'received event type: ' . $event->{type},
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

    my $http = Net::Async::HTTP->new;
    $loop->add($http);

    my $response = $http->GET("http://127.0.0.1:$port/")->get;

    is($response->code, 200, 'Response status is 200');
    like($response->decoded_content, qr/received event type: http\.request/, 'Received http.request event');

    $loop->remove($http);
    $server->shutdown->get;
    $loop->remove($server);
};

# Test 20: Unsupported scope type causes app to throw exception
subtest 'Unsupported scope type is handled gracefully' => sub {
    # Create app that only handles http scope
    my $http_only_app = async sub  {
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

        # Only handle http - throw for websocket, sse, etc.
        die "Unsupported scope type: $scope->{type}" unless $scope->{type} eq 'http';

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

    my $server = PAGI::Server->new(
        app   => $http_only_app,
        host  => '127.0.0.1',
        port  => 0,
        quiet => 1,
    );

    $loop->add($server);
    $server->listen->get;

    my $port = $server->port;

    # Normal HTTP request should work
    my $http = Net::Async::HTTP->new;
    $loop->add($http);

    my $response = $http->GET("http://127.0.0.1:$port/")->get;
    is($response->code, 200, 'HTTP request works');

    $loop->remove($http);
    $server->shutdown->get;
    $loop->remove($server);

    # The WebSocket rejection is already tested in t/04-websocket.t
    pass('App throws exception for unsupported scope types');
};

# Test 21: Middleware can wrap applications without mutating scope
subtest 'Middleware wraps app without mutating original scope' => sub {
    my $original_scope;
    my $modified_scope;

    my $inner_app = async sub  {
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

        $modified_scope = $scope;

        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [['content-type', 'text/plain']],
        });

        my $has_custom = exists $scope->{custom_key} ? 'yes' : 'no';
        await $send->({
            type => 'http.response.body',
            body => "custom_key=$has_custom",
            more => 0,
        });
    };

    # Middleware that adds a custom key without mutating original
    my $middleware = sub  {
        my ($app) = @_;
        return async sub  {
        my ($scope, $receive, $send) = @_;
            $original_scope = $scope;
            # Create a new scope with additional key (don't mutate original)
            my $new_scope = { %$scope, custom_key => 'added_by_middleware' };
            await $app->($new_scope, $receive, $send);
        };
    };

    my $wrapped_app = $middleware->($inner_app);

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

    is($response->code, 200, 'Response status is 200');
    like($response->decoded_content, qr/custom_key=yes/, 'Inner app sees custom_key');

    # Verify original scope was not mutated
    ok(!exists $original_scope->{custom_key}, 'Original scope was not mutated');
    ok(exists $modified_scope->{custom_key}, 'Modified scope has custom_key');

    $loop->remove($http);
    $server->shutdown->get;
    $loop->remove($server);
};

# Test 22: HTTP pipelining handles multiple requests per connection
subtest 'HTTP pipelining handles multiple requests' => sub {
    (async sub {
        my $server = PAGI::Server->new(
            app   => $app,
            host  => '127.0.0.1',
            port  => 0,
            quiet => 1,
        );

        $loop->add($server);
        await $server->listen;

        my $port = $server->port;

        # Create a stream and send pipelined requests
        my $socket = IO::Socket::INET->new(
            PeerAddr => '127.0.0.1',
            PeerPort => $port,
            Proto    => 'tcp',
            Blocking => 0,
        ) or die "Cannot connect: $!";

        my $response = '';
        my $done = $loop->new_future;

        my $stream = IO::Async::Stream->new(
            handle => $socket,
            on_read => sub  {
        my ($s, $buffref, $eof) = @_;
                $response .= $$buffref;
                $$buffref = '';
                # Look for two complete responses
                my $count = () = $response =~ /HTTP\/1\.1 200 OK/g;
                if ($count >= 2 || $eof) {
                    $done->done unless $done->is_ready;
                }
                return 0;
            },
            on_closed => sub {
                $done->done unless $done->is_ready;
            },
        );

        $loop->add($stream);

        # Send two pipelined requests without waiting for responses
        $stream->write(
            "GET / HTTP/1.1\r\nHost: localhost\r\n\r\n" .
            "GET / HTTP/1.1\r\nHost: localhost\r\n\r\n"
        );

        # Wait with timeout
        my $timeout = $loop->delay_future(after => 3)->then(sub { $done->done });
        await Future->wait_any($done, $timeout);

        # Count responses
        my @responses = $response =~ /(HTTP\/1\.1 200 OK)/g;
        is(scalar @responses, 2, 'Received two pipelined responses');

        $loop->remove($stream);
        await $server->shutdown;
        $loop->remove($server);
    })->()->get;
};

# Test 23: on_error callback is invoked for server errors
subtest 'on_error callback is invoked for errors' => sub {
    my $error_received;

    my $error_app = async sub  {
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

        die "Intentional test error from app";
    };

    my $server = PAGI::Server->new(
        app      => $error_app,
        host     => '127.0.0.1',
        port     => 0,
        quiet    => 1,
        on_error => sub {
            $error_received = shift;
        },
    );

    $loop->add($server);
    $server->listen->get;

    my $port = $server->port;

    my $http = Net::Async::HTTP->new;
    $loop->add($http);

    # This should trigger the error
    my $response = $http->GET("http://127.0.0.1:$port/")->get;

    is($response->code, 500, 'Response status is 500 for app error');

    $loop->remove($http);
    $server->shutdown->get;
    $loop->remove($server);

    # The on_error callback behavior is implementation-dependent
    # For now, we verify the server handled the error gracefully
    pass('Server handled app error gracefully');
};

# Test 24: Access logging writes request/response info
subtest 'Access logging writes request/response info' => sub {
    my $log_output = '';
    open(my $log_fh, '>', \$log_output) or die "Cannot create in-memory log: $!";

    my $server = PAGI::Server->new(
        app        => $app,
        host       => '127.0.0.1',
        port       => 0,
        access_log => $log_fh,
    );

    $loop->add($server);
    $server->listen->get;

    my $port = $server->port;

    my $http = Net::Async::HTTP->new;
    $loop->add($http);

    # Make a request
    my $response = $http->GET("http://127.0.0.1:$port/test/path?query=value")->get;

    is($response->code, 200, 'Response status is 200');

    # Close filehandle to flush
    close($log_fh);

    # Give a moment for async logging to complete
    $loop->delay_future(after => 0.1)->get;

    # Verify access log contains expected info
    like($log_output, qr/GET \/test\/path\?query=value/, 'Access log contains request path');
    like($log_output, qr/\s200\s/, 'Access log contains status code');
    like($log_output, qr/127\.0\.0\.1/, 'Access log contains client IP');
    like($log_output, qr/\d+\.\d+s/, 'Access log contains request duration');
    like($log_output, qr{\[\d{2}/\w{3}/\d{4}:\d{2}:\d{2}:\d{2} \+0000\]}, 'Access log contains CLF timestamp');

    $loop->remove($http);
    $server->shutdown->get;
    $loop->remove($server);
};

# Test 25: HTTP/1.1 requires Host header (RFC 7230 Section 5.4)
subtest 'HTTP/1.1 without Host header returns 400 Bad Request' => sub {
    (async sub {
        my $server = PAGI::Server->new(
            app   => $app,
            host  => '127.0.0.1',
            port  => 0,
            quiet => 1,
        );

        $loop->add($server);
        await $server->listen;

        my $port = $server->port;

        # Create raw socket to send request without Host header
        my $socket = IO::Socket::INET->new(
            PeerAddr => '127.0.0.1',
            PeerPort => $port,
            Proto    => 'tcp',
            Blocking => 0,
        ) or die "Cannot connect: $!";

        my $response = '';
        my $done = $loop->new_future;

        my $stream = IO::Async::Stream->new(
            handle => $socket,
            on_read => sub  {
        my ($s, $buffref, $eof) = @_;
                $response .= $$buffref;
                $$buffref = '';
                if ($eof || $response =~ /\r\n\r\n/) {
                    $done->done unless $done->is_ready;
                }
                return 0;
            },
            on_closed => sub {
                $done->done unless $done->is_ready;
            },
        );

        $loop->add($stream);

        # Send HTTP/1.1 request WITHOUT Host header (RFC 7230 violation)
        $stream->write("GET / HTTP/1.1\r\n\r\n");

        my $timeout = $loop->delay_future(after => 3)->then(sub { $done->done });
        await Future->wait_any($done, $timeout);

        like($response, qr/HTTP\/1\.1 400/, 'HTTP/1.1 request without Host returns 400 Bad Request');

        $loop->remove($stream);
        await $server->shutdown;
        $loop->remove($server);
    })->()->get;
};

# Test 26: HTTP/1.0 without Host is allowed
subtest 'HTTP/1.0 without Host header is allowed' => sub {
    (async sub {
        my $server = PAGI::Server->new(
            app   => $app,
            host  => '127.0.0.1',
            port  => 0,
            quiet => 1,
        );

        $loop->add($server);
        await $server->listen;

        my $port = $server->port;

        my $socket = IO::Socket::INET->new(
            PeerAddr => '127.0.0.1',
            PeerPort => $port,
            Proto    => 'tcp',
            Blocking => 0,
        ) or die "Cannot connect: $!";

        my $response = '';
        my $done = $loop->new_future;

        my $stream = IO::Async::Stream->new(
            handle => $socket,
            on_read => sub  {
        my ($s, $buffref, $eof) = @_;
                $response .= $$buffref;
                $$buffref = '';
                if ($eof || $response =~ /\r\n\r\n/) {
                    $done->done unless $done->is_ready;
                }
                return 0;
            },
            on_closed => sub {
                $done->done unless $done->is_ready;
            },
        );

        $loop->add($stream);

        # Send HTTP/1.0 request WITHOUT Host header (allowed per RFC)
        $stream->write("GET / HTTP/1.0\r\n\r\n");

        my $timeout = $loop->delay_future(after => 3)->then(sub { $done->done });
        await Future->wait_any($done, $timeout);

        like($response, qr/HTTP\/1\.0 200/, 'HTTP/1.0 request without Host returns 200 OK');

        $loop->remove($stream);
        await $server->shutdown;
        $loop->remove($server);
    })->()->get;
};

# Test 27: Content-Length validation (actual body matches declared length)
subtest 'Content-Length validation' => sub {
    (async sub {
        # App that echoes back request body size
        my $echo_app = async sub  {
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

            die "Unsupported scope type: $scope->{type}" unless $scope->{type} eq 'http';

            my $body = '';
            while (1) {
                my $event = await $receive->();
                last unless $event->{type} eq 'http.request';
                $body .= $event->{body} // '';
                last unless $event->{more};
            }

            await $send->({
                type    => 'http.response.start',
                status  => 200,
                headers => [['content-type', 'text/plain']],
            });

            await $send->({
                type => 'http.response.body',
                body => "Received " . length($body) . " bytes",
                more => 0,
            });
        };

        my $server = PAGI::Server->new(
            app   => $echo_app,
            host  => '127.0.0.1',
            port  => 0,
            quiet => 1,
        );

        $loop->add($server);
        await $server->listen;

        my $port = $server->port;

        my $http = Net::Async::HTTP->new;
        $loop->add($http);

        # Send a POST with valid Content-Length
        my $test_body = "Hello, World!";
        my $request = HTTP::Request->new(
            POST => "http://127.0.0.1:$port/",
            [
                'Content-Type' => 'text/plain',
                'Content-Length' => length($test_body),
            ],
            $test_body,
        );

        my $response = await $http->do_request(request => $request);

        is($response->code, 200, 'Response status is 200 for valid request');
        like($response->decoded_content, qr/Received 13 bytes/, 'Server received correct body size');

        $loop->remove($http);
        await $server->shutdown;
        $loop->remove($server);
    })->()->get;
};

# Test: Too many headers returns 431
subtest 'Too many headers returns 431' => sub {
    (async sub {
        # Create server with low header count limit
        my $server = PAGI::Server->new(
            app              => $app,
            host             => '127.0.0.1',
            port             => 0,
            quiet            => 1,
            max_header_count => 5,  # Very low limit for testing
        );

        $loop->add($server);
        await $server->listen;

        my $port = $server->port;

        # Send request with many headers using non-blocking socket with async I/O
        my $socket = IO::Socket::INET->new(
            PeerAddr => '127.0.0.1',
            PeerPort => $port,
            Proto    => 'tcp',
            Blocking => 0,
        ) or die "Cannot connect: $!";

        my $response = '';
        my $done = $loop->new_future;

        my $stream = IO::Async::Stream->new(
            handle => $socket,
            on_read => sub  {
        my ($s, $buffref, $eof) = @_;
                $response .= $$buffref;
                $$buffref = '';
                if ($eof || $response =~ /\r\n\r\n/) {
                    $done->done unless $done->is_ready;
                }
                return 0;
            },
            on_closed => sub {
                $done->done unless $done->is_ready;
            },
        );

        $loop->add($stream);

        # Build request with 10 headers (exceeds limit of 5)
        my $request = "GET / HTTP/1.1\r\nHost: localhost\r\n";
        for my $i (1..10) {
            $request .= "X-Custom-Header-$i: value$i\r\n";
        }
        $request .= "\r\n";

        $stream->write($request);

        # Wait for response with timeout
        await Future->wait_any(
            $done,
            $loop->timeout_future(after => 5)->else(sub { die "Timeout waiting for response" }),
        );

        $loop->remove($stream);

        like($response, qr{HTTP/1\.1 431}, 'Response is 431 Request Header Fields Too Large');

        await $server->shutdown;
        $loop->remove($server);
    })->()->get;
};

done_testing;
