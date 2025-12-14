#!/usr/bin/env perl

# =============================================================================
# Test: CRLF Header Injection Prevention
#
# This test exposes issues 1.2-1.5 from SERVER_ISSUES.md:
#
# 1.2: HTTP response header injection - headers not validated for CRLF
# 1.3: WebSocket custom header injection - extra headers not validated
# 1.4: WebSocket subprotocol injection - subprotocol value not validated
# 1.5: HTTP trailer injection - trailer headers not validated
#
# Attack vector: Injecting \r\n into header values allows:
# - HTTP Response Splitting attacks
# - Cache poisoning
# - Session hijacking via injected Set-Cookie
# - XSS via injected Content-Type
#
# Expected behavior (after fix):
# - Any header name/value containing CR (\r) or LF (\n) is rejected
# - Any header containing null bytes (\0) is rejected
# - Server returns error or strips dangerous characters
#
# Current behavior (before fix):
# - CRLF sequences pass through unvalidated, enabling header injection
# =============================================================================

use strict;
use warnings;
use experimental 'signatures';
use Test2::V0;
use IO::Async::Loop;
use IO::Socket::INET;
use Future::AsyncAwait;
use FindBin;
use lib "$FindBin::Bin/../lib";

use PAGI::Server;
use PAGI::Server::Protocol::HTTP1;

my $loop = IO::Async::Loop->new;

# =============================================================================
# Unit Tests: Protocol-level header serialization
# =============================================================================

subtest 'HTTP1 Protocol - serialize_response_start header injection' => sub {
    my $proto = PAGI::Server::Protocol::HTTP1->new;

    # Test 1: Normal headers should work fine
    my $normal = $proto->serialize_response_start(200, [
        ['Content-Type', 'text/html'],
        ['X-Custom', 'safe-value'],
    ]);
    like($normal, qr/Content-Type: text\/html\r\n/, 'Normal headers serialize correctly');

    # Test 2: Header value with CRLF injection attempt
    # Attack: inject a fake Set-Cookie header
    my $malicious_value = "innocent\r\nSet-Cookie: evil=hacked";

    # CURRENT BEHAVIOR (vulnerable): This will succeed and inject the header
    # EXPECTED BEHAVIOR (after fix): Should die or sanitize
    my $result;
    my $died = 0;
    eval {
        $result = $proto->serialize_response_start(200, [
            ['X-Custom', $malicious_value],
        ]);
    };
    $died = 1 if $@;

    # For now, document the vulnerable behavior
    if (!$died && defined $result) {
        # Check if the injection succeeded
        my $has_injected_cookie = ($result =~ /Set-Cookie: evil=hacked/);

        # THIS TEST WILL FAIL UNTIL THE FIX IS APPLIED
        # After fix, either $died should be true, or $has_injected_cookie should be false
        ok(!$has_injected_cookie,
            'CRLF in header value should NOT allow header injection');

        if ($has_injected_cookie) {
            diag("VULNERABILITY CONFIRMED: Header injection succeeded!");
            diag("Injected response:\n$result");
        }
    } else {
        pass('CRLF in header value correctly rejected (died)');
    }

    # Test 3: Header value with just LF
    my $lf_value = "value\ninjected";
    eval { $result = $proto->serialize_response_start(200, [['X-Test', $lf_value]]); };
    if ($@) {
        pass('LF in header value correctly rejected');
    } else {
        my $has_lf = ($result =~ /value\ninjected/);
        ok(!$has_lf, 'LF in header value should be sanitized or rejected');
    }

    # Test 4: Header value with just CR
    my $cr_value = "value\rinjected";
    eval { $result = $proto->serialize_response_start(200, [['X-Test', $cr_value]]); };
    if ($@) {
        pass('CR in header value correctly rejected');
    } else {
        my $has_cr = ($result =~ /value\rinjected/);
        ok(!$has_cr, 'CR in header value should be sanitized or rejected');
    }

    # Test 5: Header value with null byte
    my $null_value = "value\0hidden";
    eval { $result = $proto->serialize_response_start(200, [['X-Test', $null_value]]); };
    if ($@) {
        pass('Null byte in header value correctly rejected');
    } else {
        my $has_null = ($result =~ /value\0hidden/);
        ok(!$has_null, 'Null byte in header value should be sanitized or rejected');
    }

    # Test 6: Header NAME with CRLF (even more dangerous)
    my $malicious_name = "X-Custom\r\nEvil-Header";
    eval { $result = $proto->serialize_response_start(200, [[$malicious_name, 'value']]); };
    if ($@) {
        pass('CRLF in header name correctly rejected');
    } else {
        my $has_evil = ($result =~ /Evil-Header/);
        ok(!$has_evil, 'CRLF in header name should NOT be allowed');
    }
};

subtest 'HTTP1 Protocol - serialize_trailers header injection' => sub {
    my $proto = PAGI::Server::Protocol::HTTP1->new;

    # Test trailer with CRLF injection
    my $malicious_trailer = "checksum\r\nSet-Cookie: evil=trailer";
    my $result;

    eval {
        $result = $proto->serialize_trailers([
            ['X-Checksum', $malicious_trailer],
        ]);
    };

    if ($@) {
        pass('CRLF in trailer value correctly rejected');
    } else {
        my $has_injected = ($result =~ /Set-Cookie: evil=trailer/);
        ok(!$has_injected,
            'CRLF in trailer value should NOT allow header injection');

        if ($has_injected) {
            diag("VULNERABILITY CONFIRMED: Trailer injection succeeded!");
            diag("Injected trailers:\n$result");
        }
    }
};

# =============================================================================
# Integration Tests: Full server WebSocket header injection
# =============================================================================

# App that echoes back subprotocol and custom headers from the accept event
my $ws_test_app = async sub ($scope, $receive, $send) {
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
        my $connect = await $receive->();  # websocket.connect

        # Get test parameters from query string
        my $qs = $scope->{query_string} // '';
        my %params = map { split /=/, $_, 2 } split /&/, $qs;

        my $accept_event = { type => 'websocket.accept' };

        # If 'subprotocol' param, use it (for testing injection)
        if ($params{subprotocol}) {
            # URL-decode basic escapes
            my $sp = $params{subprotocol};
            $sp =~ s/%0D/\r/g;
            $sp =~ s/%0A/\n/g;
            $sp =~ s/%00/\0/g;
            $accept_event->{subprotocol} = $sp;
        }

        # If 'header' param, add custom header (for testing injection)
        if ($params{header}) {
            my $hval = $params{header};
            $hval =~ s/%0D/\r/g;
            $hval =~ s/%0A/\n/g;
            $hval =~ s/%00/\0/g;
            $accept_event->{headers} = [
                ['X-Custom', $hval],
            ];
        }

        await $send->($accept_event);

        # Wait for disconnect
        while (1) {
            my $msg = await $receive->();
            last if $msg->{type} eq 'websocket.disconnect';
        }
    }
};

subtest 'WebSocket subprotocol header injection (issue 1.4)' => sub {
    my $server = PAGI::Server->new(
        app   => $ws_test_app,
        host  => '127.0.0.1',
        port  => 0,
        quiet => 1,
    );

    $loop->add($server);
    $server->listen->get;
    my $port = $server->port;

    # Test: Subprotocol with CRLF injection attempt
    # Tries to inject: graphql\r\nSet-Cookie: evil=1
    my $sock = IO::Socket::INET->new(
        PeerAddr => '127.0.0.1',
        PeerPort => $port,
        Proto    => 'tcp',
        Timeout  => 5,
    );

    SKIP: {
        skip "Cannot connect to server", 1 unless $sock;

        # Request with malicious subprotocol in query string
        # %0D = CR, %0A = LF
        my $key = 'dGhlIHNhbXBsZSBub25jZQ==';
        print $sock "GET /?subprotocol=graphql%0D%0ASet-Cookie:%20evil=1 HTTP/1.1\r\n";
        print $sock "Host: 127.0.0.1:$port\r\n";
        print $sock "Upgrade: websocket\r\n";
        print $sock "Connection: Upgrade\r\n";
        print $sock "Sec-WebSocket-Key: $key\r\n";
        print $sock "Sec-WebSocket-Version: 13\r\n";
        print $sock "Sec-WebSocket-Protocol: graphql\r\n";
        print $sock "\r\n";

        # Read response
        $sock->blocking(0);
        my $response = '';
        my $deadline = time + 3;
        while (time < $deadline) {
            my $buf;
            my $n = sysread($sock, $buf, 4096);
            if (defined $n && $n > 0) {
                $response .= $buf;
                last if $response =~ /\r\n\r\n/;
            }
            $loop->loop_once(0.1);
        }

        # Check if the evil Set-Cookie was injected
        my $has_evil_cookie = ($response =~ /Set-Cookie:\s*evil=1/i);

        ok(!$has_evil_cookie,
            'Subprotocol CRLF injection should NOT inject Set-Cookie header');

        if ($has_evil_cookie) {
            diag("VULNERABILITY CONFIRMED: Subprotocol header injection!");
            diag("Response headers:\n$response");
        }

        close $sock;
    }

    $server->shutdown->get;
};

subtest 'WebSocket custom header injection (issue 1.3)' => sub {
    my $server = PAGI::Server->new(
        app   => $ws_test_app,
        host  => '127.0.0.1',
        port  => 0,
        quiet => 1,
    );

    $loop->add($server);
    $server->listen->get;
    my $port = $server->port;

    my $sock = IO::Socket::INET->new(
        PeerAddr => '127.0.0.1',
        PeerPort => $port,
        Proto    => 'tcp',
        Timeout  => 5,
    );

    SKIP: {
        skip "Cannot connect to server", 1 unless $sock;

        # Request with malicious custom header value
        # Tries to inject: safe-value\r\nSet-Cookie: stolen=session
        my $key = 'dGhlIHNhbXBsZSBub25jZQ==';
        print $sock "GET /?header=safe%0D%0ASet-Cookie:%20stolen=session HTTP/1.1\r\n";
        print $sock "Host: 127.0.0.1:$port\r\n";
        print $sock "Upgrade: websocket\r\n";
        print $sock "Connection: Upgrade\r\n";
        print $sock "Sec-WebSocket-Key: $key\r\n";
        print $sock "Sec-WebSocket-Version: 13\r\n";
        print $sock "\r\n";

        $sock->blocking(0);
        my $response = '';
        my $deadline = time + 3;
        while (time < $deadline) {
            my $buf;
            my $n = sysread($sock, $buf, 4096);
            if (defined $n && $n > 0) {
                $response .= $buf;
                last if $response =~ /\r\n\r\n/;
            }
            $loop->loop_once(0.1);
        }

        my $has_stolen_cookie = ($response =~ /Set-Cookie:\s*stolen=session/i);

        ok(!$has_stolen_cookie,
            'Custom header CRLF injection should NOT inject Set-Cookie header');

        if ($has_stolen_cookie) {
            diag("VULNERABILITY CONFIRMED: Custom header injection!");
            diag("Response headers:\n$response");
        }

        close $sock;
    }

    $server->shutdown->get;
};

# =============================================================================
# Integration Test: HTTP response header injection via app
# =============================================================================

my $http_test_app = async sub ($scope, $receive, $send) {
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

    if ($scope->{type} eq 'http') {
        await $receive->();  # http.request

        # Parse query string for test params
        my $qs = $scope->{query_string} // '';
        my %params = map { split /=/, $_, 2 } split /&/, $qs;

        my @headers = (['Content-Type', 'text/plain']);

        if ($params{inject}) {
            # URL-decode and add malicious header
            my $val = $params{inject};
            $val =~ s/%0D/\r/g;
            $val =~ s/%0A/\n/g;
            push @headers, ['X-User-Input', $val];
        }

        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => \@headers,
        });

        await $send->({
            type => 'http.response.body',
            body => 'OK',
        });
    }
};

subtest 'HTTP response header injection via application (issue 1.2)' => sub {
    my $server = PAGI::Server->new(
        app   => $http_test_app,
        host  => '127.0.0.1',
        port  => 0,
        quiet => 1,
    );

    $loop->add($server);
    $server->listen->get;
    my $port = $server->port;

    my $sock = IO::Socket::INET->new(
        PeerAddr => '127.0.0.1',
        PeerPort => $port,
        Proto    => 'tcp',
        Timeout  => 5,
    );

    SKIP: {
        skip "Cannot connect to server", 1 unless $sock;

        # Request that triggers header injection
        # inject=safe%0D%0ASet-Cookie:%20pwned=true
        print $sock "GET /?inject=safe%0D%0ASet-Cookie:%20pwned=true HTTP/1.1\r\n";
        print $sock "Host: 127.0.0.1:$port\r\n";
        print $sock "Connection: close\r\n";
        print $sock "\r\n";

        $sock->blocking(0);
        my $response = '';
        my $deadline = time + 3;
        while (time < $deadline) {
            my $buf;
            my $n = sysread($sock, $buf, 4096);
            if (defined $n && $n > 0) {
                $response .= $buf;
            } elsif (!defined $n && $! == 11) {  # EAGAIN
                $loop->loop_once(0.1);
            } else {
                last;  # EOF or error
            }
        }

        my $has_pwned_cookie = ($response =~ /Set-Cookie:\s*pwned=true/i);

        ok(!$has_pwned_cookie,
            'HTTP header CRLF injection should NOT inject Set-Cookie header');

        if ($has_pwned_cookie) {
            diag("VULNERABILITY CONFIRMED: HTTP response header injection!");
            diag("Response:\n$response");
        }

        close $sock;
    }

    $server->shutdown->get;
};

# =============================================================================
# Edge cases and additional injection vectors
# =============================================================================

subtest 'Various CRLF encoding attacks' => sub {
    my $proto = PAGI::Server::Protocol::HTTP1->new;
    my $result;
    my @attacks = (
        # [description, malicious_value, detection_pattern]
        ['Bare CR', "foo\rbar", qr/foo\rbar/],
        ['Bare LF', "foo\nbar", qr/foo\nbar/],
        ['CRLF', "foo\r\nbar", qr/foo\r\nbar/],
        ['LFCR', "foo\n\rbar", qr/foo\n\rbar/],
        ['Multiple CRLF', "a\r\nb\r\nc", qr/\r\n.*\r\n/s],
        ['Null byte', "foo\0bar", qr/foo\0bar/],
        ['Tab (valid)', "foo\tbar", qr/foo\tbar/],  # Tabs ARE valid in headers
    );

    for my $attack (@attacks) {
        my ($desc, $value, $pattern) = @$attack;

        eval {
            $result = $proto->serialize_response_start(200, [
                ['X-Test', $value],
            ]);
        };

        if ($@) {
            # Good - rejected with exception
            if ($desc eq 'Tab (valid)') {
                fail("$desc should be allowed in headers but was rejected");
            } else {
                pass("$desc correctly rejected with exception");
            }
        } else {
            # Check if dangerous chars made it through
            if ($desc eq 'Tab (valid)') {
                # Tabs should be allowed
                like($result, $pattern, "$desc is correctly allowed");
            } else {
                unlike($result, $pattern, "$desc should be stripped or cause rejection");
            }
        }
    }
};

done_testing;
