use strict;
use warnings;
use Test2::V0;
use FindBin;
use lib "$FindBin::Bin/../../lib";

plan skip_all => "Server integration tests not supported on Windows" if $^O eq 'MSWin32';
BEGIN {
    eval { require Net::HTTP2::nghttp2; Net::HTTP2::nghttp2->VERSION(0.007); 1 }
        or plan(skip_all => 'Net::HTTP2::nghttp2 0.007+ not installed (optional)');
}

# ============================================================
# Test: PAGI::Server::Protocol::HTTP2 module
# ============================================================
# Tests the nghttp2 session wrapper: creation, feed/extract,
# request callbacks, body callbacks, and response submission.

ok(eval { require PAGI::Server::Protocol::HTTP2; 1 },
    'PAGI::Server::Protocol::HTTP2 loads successfully') or diag $@;

ok(PAGI::Server::Protocol::HTTP2->available, 'HTTP/2 (nghttp2) is available');

# Helper: complete client-server HTTP/2 handshake
# Exchanges connection preface and SETTINGS/SETTINGS_ACK between
# a Protocol::HTTP2::Session (server) and a nghttp2 client session.
sub complete_handshake {
    my ($session, $client) = @_;

    # Server sends initial SETTINGS
    my $server_data = $session->extract;

    # Client sends connection preface + SETTINGS
    $client->send_connection_preface;
    my $client_data = $client->mem_send;

    # Feed client preface to server
    $session->feed($client_data);

    # Feed server SETTINGS to client
    $client->mem_recv($server_data) if defined $server_data && length($server_data);

    # Server sends SETTINGS ACK
    my $server_ack = $session->extract;
    $client->mem_recv($server_ack) if defined $server_ack && length($server_ack);

    # Client sends SETTINGS ACK
    my $client_ack = $client->mem_send;
    $session->feed($client_ack) if defined $client_ack && length($client_ack);

    # Flush any remaining server data
    my $extra = $session->extract;
    $client->mem_recv($extra) if defined $extra && length($extra);
}

# Helper: create a client session with common callbacks
sub create_test_client {
    my (%overrides) = @_;

    require Net::HTTP2::nghttp2::Session;

    return Net::HTTP2::nghttp2::Session->new_client(
        callbacks => {
            on_begin_headers   => $overrides{on_begin_headers}   || sub { 0 },
            on_header          => $overrides{on_header}          || sub { 0 },
            on_frame_recv      => $overrides{on_frame_recv}      || sub { 0 },
            on_data_chunk_recv => $overrides{on_data_chunk_recv} || sub { 0 },
            on_stream_close    => $overrides{on_stream_close}    || sub { 0 },
        },
    );
}

# ============================================================
# Session creation with default settings
# ============================================================
subtest 'Session creation with defaults' => sub {
    my $proto = PAGI::Server::Protocol::HTTP2->new;
    isa_ok($proto, 'PAGI::Server::Protocol::HTTP2');

    my $session = $proto->create_session(
        on_request => sub {},
        on_body    => sub {},
        on_close   => sub {},
    );

    isa_ok($session, 'PAGI::Server::Protocol::HTTP2::Session');

    my $data = $session->extract;
    ok(defined $data && length($data) > 0, 'Session produces SETTINGS on creation');
};

# ============================================================
# Session creation with custom settings
# ============================================================
subtest 'Session creation with custom settings' => sub {
    my $proto = PAGI::Server::Protocol::HTTP2->new(
        max_concurrent_streams  => 50,
        initial_window_size     => 32768,
        max_frame_size          => 32768,
        enable_push             => 0,
        enable_connect_protocol => 1,
    );

    my $session = $proto->create_session(
        on_request => sub {},
        on_body    => sub {},
        on_close   => sub {},
    );

    my $data = $session->extract;
    ok(defined $data && length($data) > 0, 'Session with custom settings produces SETTINGS');
};

# ============================================================
# Feed client preface + SETTINGS → verify SETTINGS ACK
# ============================================================
subtest 'Feed client preface and SETTINGS' => sub {
    my $proto = PAGI::Server::Protocol::HTTP2->new;

    my $session = $proto->create_session(
        on_request => sub {},
        on_body    => sub {},
        on_close   => sub {},
    );

    $session->extract;

    # Build client preface: magic + empty SETTINGS frame
    my $client_preface = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n";
    my $settings_frame = pack('nCCCN', 0, 0, 0x04, 0x00, 0);

    $session->feed($client_preface . $settings_frame);

    my $response_data = $session->extract;
    ok(defined $response_data && length($response_data) > 0,
        'Server produces SETTINGS ACK after client preface');
};

# ============================================================
# GET request triggers on_request callback
# ============================================================
subtest 'GET request triggers on_request callback' => sub {
    my $proto = PAGI::Server::Protocol::HTTP2->new;

    my @requests;
    my $session = $proto->create_session(
        on_request => sub { push @requests, [@_] },
        on_body    => sub {},
        on_close   => sub {},
    );

    my $client = create_test_client();
    complete_handshake($session, $client);

    # Client sends GET /
    $client->submit_request(
        method    => 'GET',
        path      => '/',
        scheme    => 'https',
        authority => 'localhost',
    );

    my $request_data = $client->mem_send;
    $session->feed($request_data);
    $session->extract;

    ok(scalar @requests >= 1, 'on_request callback was called');

    if (@requests) {
        my ($stream_id, $pseudo, $headers, $has_body) = @{$requests[0]};
        ok($stream_id > 0, "stream_id is positive: $stream_id");
        is($pseudo->{':method'}, 'GET', 'Method is GET');
        is($pseudo->{':path'}, '/', 'Path is /');
        is($pseudo->{':scheme'}, 'https', 'Scheme is https');
        ok(!$has_body, 'GET has no body (END_STREAM set)');
    }
};

# ============================================================
# POST request with body triggers on_body callback
# ============================================================
subtest 'POST request with body triggers on_body callback' => sub {
    my $proto = PAGI::Server::Protocol::HTTP2->new;

    my @requests;
    my @bodies;

    my $session = $proto->create_session(
        on_request => sub { push @requests, [@_] },
        on_body    => sub { push @bodies, [@_] },
        on_close   => sub {},
    );

    my $client = create_test_client();
    complete_handshake($session, $client);

    # Client sends POST with body
    my $body = "hello=world";
    $client->submit_request(
        method    => 'POST',
        path      => '/submit',
        scheme    => 'https',
        authority => 'localhost',
        headers   => [['content-type', 'application/x-www-form-urlencoded']],
        body      => $body,
    );

    my $request_data = $client->mem_send;
    $session->feed($request_data);
    $session->extract;

    ok(scalar @requests >= 1, 'on_request was called for POST');
    if (@requests) {
        my ($stream_id, $pseudo, $headers, $has_body) = @{$requests[0]};
        is($pseudo->{':method'}, 'POST', 'Method is POST');
        is($pseudo->{':path'}, '/submit', 'Path is /submit');
        ok($has_body, 'POST has body (END_STREAM not set)');
    }

    ok(scalar @bodies >= 1, 'on_body was called');
    if (@bodies) {
        my $received_body = join('', map { $_->[1] } @bodies);
        is($received_body, $body, 'Received correct body data');

        # Last body call should have eof=1
        my $last_body = $bodies[-1];
        ok($last_body->[2], 'Last body chunk has eof=1');
    }
};

# ============================================================
# submit_response produces response frames
# ============================================================
subtest 'submit_response produces response frames' => sub {
    my $proto = PAGI::Server::Protocol::HTTP2->new;

    my @requests;
    my $session = $proto->create_session(
        on_request => sub { push @requests, [@_] },
        on_body    => sub {},
        on_close   => sub {},
    );

    my %client_headers;
    my $client_body = '';

    my $client = create_test_client(
        on_header => sub {
            my ($stream_id, $name, $value) = @_;
            $client_headers{$name} = $value;
            return 0;
        },
        on_data_chunk_recv => sub {
            my ($stream_id, $data) = @_;
            $client_body .= $data;
            return 0;
        },
    );

    complete_handshake($session, $client);

    # Client sends GET
    $client->submit_request(
        method    => 'GET',
        path      => '/',
        scheme    => 'https',
        authority => 'localhost',
    );
    my $request_data = $client->mem_send;
    $session->feed($request_data);
    $session->extract;

    ok(scalar @requests >= 1, 'Request received by server');

    # Server submits response
    my $stream_id = $requests[0][0];
    $session->submit_response($stream_id,
        status  => 200,
        headers => [['content-type', 'text/plain']],
        body    => "Hello, HTTP/2!\n",
    );

    # Exchange response frames
    my $response_frames = $session->extract;
    ok(defined $response_frames && length($response_frames) > 0,
        'submit_response produces frames');

    $client->mem_recv($response_frames);

    # May need additional rounds
    for (1..3) {
        my $more = $session->extract;
        last unless defined $more && length($more);
        $client->mem_recv($more);
    }

    is($client_headers{':status'}, '200', 'Client received 200 status');
    is($client_headers{'content-type'}, 'text/plain', 'Client received content-type');
    is($client_body, "Hello, HTTP/2!\n", 'Client received response body');
};

# ============================================================
# detect_preface class method
# ============================================================
subtest 'detect_preface identifies HTTP/2 client preface' => sub {
    my $preface = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n";

    ok(PAGI::Server::Protocol::HTTP2->detect_preface($preface),
        'Detects valid HTTP/2 preface');
    ok(PAGI::Server::Protocol::HTTP2->detect_preface($preface . "extra data"),
        'Detects preface with trailing data');
    ok(!PAGI::Server::Protocol::HTTP2->detect_preface("GET / HTTP/1.1\r\n"),
        'Rejects HTTP/1.1 request');
    ok(!PAGI::Server::Protocol::HTTP2->detect_preface(""),
        'Rejects empty string');
    ok(!PAGI::Server::Protocol::HTTP2->detect_preface("PRI * HTTP/2.0"),
        'Rejects incomplete preface');
};

# ============================================================
# want_read / want_write
# ============================================================
subtest 'want_read and want_write' => sub {
    my $proto = PAGI::Server::Protocol::HTTP2->new;

    my $session = $proto->create_session(
        on_request => sub {},
        on_body    => sub {},
        on_close   => sub {},
    );

    ok($session->want_write, 'Session wants to write before extract');
    $session->extract;
    ok($session->want_read, 'Session wants to read after init');
};

# ============================================================
# terminate sends GOAWAY
# ============================================================
subtest 'terminate sends GOAWAY' => sub {
    my $proto = PAGI::Server::Protocol::HTTP2->new;

    my $session = $proto->create_session(
        on_request => sub {},
        on_body    => sub {},
        on_close   => sub {},
    );

    $session->extract;

    $session->terminate(0);
    my $goaway_data = $session->extract;
    ok(defined $goaway_data && length($goaway_data) > 0,
        'terminate produces GOAWAY frame');
};

# ============================================================
# max_header_list_size is advertised in SETTINGS
# ============================================================
subtest 'max_header_list_size is advertised in SETTINGS' => sub {
    my $proto = PAGI::Server::Protocol::HTTP2->new;

    my $session = $proto->create_session(
        on_request => sub {},
        on_body    => sub {},
        on_close   => sub {},
    );

    my $data = $session->extract;
    ok(defined $data && length($data) > 0, 'Session produces SETTINGS');

    # Parse the SETTINGS frame to find MAX_HEADER_LIST_SIZE (id=0x06)
    # Frame format: 3-byte length + 1-byte type + 1-byte flags + 4-byte stream_id + payload
    # SETTINGS payload: 2-byte id + 4-byte value per setting
    my $found = 0;
    my $value;
    while (length($data) >= 9) {
        my $len = unpack('N', "\0" . substr($data, 0, 3));
        my $type = unpack('C', substr($data, 3, 1));
        my $flags = unpack('C', substr($data, 4, 1));
        my $payload = substr($data, 9, $len);

        # SETTINGS frame = type 0x04, not ACK (flags & 0x01 == 0)
        if ($type == 0x04 && !($flags & 0x01)) {
            while (length($payload) >= 6) {
                my ($id, $val) = unpack('nN', $payload);
                if ($id == 0x06) {  # MAX_HEADER_LIST_SIZE
                    $found = 1;
                    $value = $val;
                }
                $payload = substr($payload, 6);
            }
        }

        $data = substr($data, 9 + $len);
    }

    ok($found, 'MAX_HEADER_LIST_SIZE setting is present');
    is($value, 65536, 'MAX_HEADER_LIST_SIZE defaults to 64KB');
};

# ============================================================
# Custom max_header_list_size is respected
# ============================================================
subtest 'custom max_header_list_size is respected' => sub {
    my $proto = PAGI::Server::Protocol::HTTP2->new(
        max_header_list_size => 32768,
    );

    my $session = $proto->create_session(
        on_request => sub {},
        on_body    => sub {},
        on_close   => sub {},
    );

    my $data = $session->extract;

    my $found = 0;
    my $value;
    while (length($data) >= 9) {
        my $len = unpack('N', "\0" . substr($data, 0, 3));
        my $type = unpack('C', substr($data, 3, 1));
        my $flags = unpack('C', substr($data, 4, 1));
        my $payload = substr($data, 9, $len);

        if ($type == 0x04 && !($flags & 0x01)) {
            while (length($payload) >= 6) {
                my ($id, $val) = unpack('nN', $payload);
                if ($id == 0x06) {
                    $found = 1;
                    $value = $val;
                }
                $payload = substr($payload, 6);
            }
        }

        $data = substr($data, 9 + $len);
    }

    ok($found, 'MAX_HEADER_LIST_SIZE setting is present');
    is($value, 32768, 'MAX_HEADER_LIST_SIZE is custom 32KB');
};

# ============================================================
# Oversized headers are rejected with RST_STREAM
# ============================================================
subtest 'oversized headers rejected with RST_STREAM' => sub {
    # Use a very small limit to make the test easy
    my $proto = PAGI::Server::Protocol::HTTP2->new(
        max_header_list_size => 128,
    );

    my @requests;
    my @closed;
    my $session = $proto->create_session(
        on_request => sub { push @requests, [@_] },
        on_body    => sub {},
        on_close   => sub { push @closed, [@_] },
    );

    my $client = create_test_client();
    complete_handshake($session, $client);

    # Send a request with headers that exceed 128 bytes
    # RFC 7541: each entry size = name_len + value_len + 32
    # :method=GET (3+3+32=38), :path=/ (5+1+32=38), :scheme=https (7+5+32=44),
    # :authority=localhost (10+9+32=51) = 171 bytes already > 128
    $client->submit_request(
        method    => 'GET',
        path      => '/',
        scheme    => 'https',
        authority => 'localhost',
    );
    my $request_data = $client->mem_send;
    $session->feed($request_data);

    # Extract response — should contain RST_STREAM
    my $response = $session->extract;
    ok(defined $response && length($response) > 0, 'Server produced response');

    # Feed response to client
    $client->mem_recv($response) if defined $response;

    # The request should NOT have been delivered to on_request
    is(scalar @requests, 0, 'Oversized request was not delivered to app');
};

# ============================================================
# Normal-sized headers pass through fine
# ============================================================
subtest 'normal-sized headers pass through with enforcement active' => sub {
    my $proto = PAGI::Server::Protocol::HTTP2->new(
        max_header_list_size => 65536,  # 64KB — plenty of room
    );

    my @requests;
    my $session = $proto->create_session(
        on_request => sub { push @requests, [@_] },
        on_body    => sub {},
        on_close   => sub {},
    );

    my $client = create_test_client();
    complete_handshake($session, $client);

    $client->submit_request(
        method    => 'GET',
        path      => '/normal',
        scheme    => 'https',
        authority => 'localhost',
    );
    my $request_data = $client->mem_send;
    $session->feed($request_data);
    $session->extract;

    is(scalar @requests, 1, 'Normal request was delivered');
    is($requests[0][1]{':path'}, '/normal', 'Path is correct');
};

# ============================================================
# :authority pseudo-header → host header conversion
# ============================================================
subtest ':authority pseudo-header is converted to host header' => sub {
    my $proto = PAGI::Server::Protocol::HTTP2->new;

    my @requests;
    my $session = $proto->create_session(
        on_request => sub { push @requests, [@_] },
        on_body    => sub {},
        on_close   => sub {},
    );

    my $client = create_test_client();
    complete_handshake($session, $client);

    # Send GET with :authority
    $client->submit_request(
        method    => 'GET',
        path      => '/test',
        scheme    => 'https',
        authority => 'example.com',
    );
    my $request_data = $client->mem_send;
    $session->feed($request_data);
    $session->extract;

    ok(scalar @requests >= 1, 'on_request was called');
    if (@requests) {
        my ($stream_id, $pseudo, $headers, $has_body) = @{$requests[0]};
        # Verify :authority is in pseudo hash
        is($pseudo->{':authority'}, 'example.com', ':authority is in pseudo hash');
        # Verify host header was synthesized from :authority
        my @host_headers = grep { $_->[0] eq 'host' } @$headers;
        ok(scalar @host_headers >= 1, 'host header exists in headers array');
        is($host_headers[0][1], 'example.com', 'host header value matches :authority');
    }
};

# ============================================================
# :authority takes precedence over explicit host header
# ============================================================
subtest ':authority takes precedence over explicit host header' => sub {
    my $proto = PAGI::Server::Protocol::HTTP2->new;

    my @requests;
    my $session = $proto->create_session(
        on_request => sub { push @requests, [@_] },
        on_body    => sub {},
        on_close   => sub {},
    );

    my $client = create_test_client();
    complete_handshake($session, $client);

    # Send request with :authority AND an explicit host header
    $client->submit_request(
        method    => 'GET',
        path      => '/test',
        scheme    => 'https',
        authority => 'authority.example.com',
        headers   => [['host', 'host.example.com']],
    );
    my $request_data = $client->mem_send;
    $session->feed($request_data);
    $session->extract;

    ok(scalar @requests >= 1, 'on_request was called');
    if (@requests) {
        my ($stream_id, $pseudo, $headers, $has_body) = @{$requests[0]};
        # :authority should take precedence per RFC 9113 Section 8.3.1
        my @host_headers = grep { $_->[0] eq 'host' } @$headers;
        is(scalar @host_headers, 1, 'Exactly one host header');
        is($host_headers[0][1], 'authority.example.com',
           ':authority value takes precedence over explicit host');
    }
};

# ============================================================
# Multiple cookie headers are normalized to single header
# ============================================================
subtest 'multiple cookie headers normalized to single header' => sub {
    my $proto = PAGI::Server::Protocol::HTTP2->new;

    my @requests;
    my $session = $proto->create_session(
        on_request => sub { push @requests, [@_] },
        on_body    => sub {},
        on_close   => sub {},
    );

    my $client = create_test_client();
    complete_handshake($session, $client);

    # Send request with multiple cookie headers
    $client->submit_request(
        method    => 'GET',
        path      => '/cookies',
        scheme    => 'https',
        authority => 'localhost',
        headers   => [
            ['cookie', 'a=1'],
            ['cookie', 'b=2'],
        ],
    );
    my $request_data = $client->mem_send;
    $session->feed($request_data);
    $session->extract;

    ok(scalar @requests >= 1, 'on_request was called');
    if (@requests) {
        my ($stream_id, $pseudo, $headers, $has_body) = @{$requests[0]};
        my @cookie_headers = grep { $_->[0] eq 'cookie' } @$headers;
        is(scalar @cookie_headers, 1, 'Exactly one cookie header after normalization');
        is($cookie_headers[0][1], 'a=1; b=2', 'Cookie values joined with "; "');
    }
};

done_testing;
