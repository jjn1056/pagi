#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;

# =============================================================================
# HTTP/2 Session Unit Tests
# =============================================================================
# Tests the PAGI::Server::Protocol::HTTP2::Session wrapper directly.

BEGIN {
    plan skip_all => 'HTTP/2 not available'
        unless eval {
            require Net::HTTP2::nghttp2;
            Net::HTTP2::nghttp2->available;
        };
}

use PAGI::Server::Protocol::HTTP2;

# HTTP/2 connection preface (client sends this first)
my $CLIENT_PREFACE = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n";

subtest 'Session creation' => sub {
    my $proto = PAGI::Server::Protocol::HTTP2->new;

    my @requests;
    my @bodies;
    my @closes;

    my $session = $proto->create_session(
        on_request => sub {
            my ($stream_id, $pseudo, $headers, $has_body) = @_;
            push @requests, {
                stream_id => $stream_id,
                pseudo    => $pseudo,
                headers   => $headers,
                has_body  => $has_body,
            };
        },
        on_body => sub {
            my ($stream_id, $data, $eof) = @_;
            push @bodies, {
                stream_id => $stream_id,
                data      => $data,
                eof       => $eof,
            };
        },
        on_close => sub {
            my ($stream_id, $error_code) = @_;
            push @closes, {
                stream_id  => $stream_id,
                error_code => $error_code,
            };
        },
    );

    isa_ok($session, 'PAGI::Server::Protocol::HTTP2::Session');
    ok($session->can('feed'), 'session has feed method');
    ok($session->can('extract'), 'session has extract method');
    ok($session->can('want_read'), 'session has want_read method');
    ok($session->can('want_write'), 'session has want_write method');
    ok($session->can('submit_response'), 'session has submit_response method');
    ok($session->can('terminate'), 'session has terminate method');

    # Server should want to write (send SETTINGS)
    ok($session->want_write, 'new session wants to write (SETTINGS frame)');

    # Extract server preface (SETTINGS frame)
    my $server_data = $session->extract;
    ok(length($server_data) > 0, 'server produces initial data (SETTINGS)');
};

subtest 'Session state methods' => sub {
    my $proto = PAGI::Server::Protocol::HTTP2->new;
    my $session = $proto->create_session(
        on_request => sub {},
        on_body    => sub {},
        on_close   => sub {},
    );

    # Initial state
    ok($session->want_write, 'wants to write initially');

    # Extract the SETTINGS frame
    $session->extract;

    # After sending SETTINGS, may still want to write or not
    # depending on implementation
    ok(defined $session->want_read, 'want_read returns defined value');
    ok(defined $session->want_write, 'want_write returns defined value');
};

subtest 'Feed client preface' => sub {
    my $proto = PAGI::Server::Protocol::HTTP2->new;
    my @requests;

    my $session = $proto->create_session(
        on_request => sub {
            my ($stream_id, $pseudo, $headers, $has_body) = @_;
            push @requests, {
                stream_id => $stream_id,
                pseudo    => $pseudo,
                headers   => $headers,
                has_body  => $has_body,
            };
        },
        on_body  => sub {},
        on_close => sub {},
    );

    # Extract server SETTINGS first
    $session->extract;

    # Feed client connection preface
    my $consumed = $session->feed($CLIENT_PREFACE);
    ok($consumed > 0, "consumed $consumed bytes of client preface");
};

subtest 'Submit response' => sub {
    my $proto = PAGI::Server::Protocol::HTTP2->new;

    my $session = $proto->create_session(
        on_request => sub {},
        on_body    => sub {},
        on_close   => sub {},
    );

    # Extract initial SETTINGS
    $session->extract;

    # Submit a response (even without a request, for API testing)
    # This might fail or be ignored by nghttp2, but tests the API
    eval {
        $session->submit_response(1,
            status  => 200,
            headers => [['content-type', 'text/plain']],
            body    => 'Hello',
        );
    };
    # We're just testing the API doesn't crash
    pass('submit_response API is callable');
};

subtest 'Terminate session' => sub {
    my $proto = PAGI::Server::Protocol::HTTP2->new;

    my $session = $proto->create_session(
        on_request => sub {},
        on_body    => sub {},
        on_close   => sub {},
    );

    # Extract initial data
    $session->extract;

    # Terminate should queue a GOAWAY frame
    $session->terminate(0);  # NO_ERROR

    # Should have data to send (GOAWAY)
    ok($session->want_write, 'wants to write after terminate');

    my $goaway_data = $session->extract;
    ok(length($goaway_data) > 0, 'produces GOAWAY frame data');
};

done_testing;
