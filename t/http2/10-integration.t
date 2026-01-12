#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use FindBin;

# =============================================================================
# HTTP/2 Integration Tests
# =============================================================================

plan skip_all => "Server integration tests not supported on Windows"
    if $^O eq 'MSWin32';

BEGIN {
    plan skip_all => 'HTTP/2 not available'
        unless eval {
            require Net::HTTP2::nghttp2;
            Net::HTTP2::nghttp2->available;
        };
}

BEGIN {
    plan skip_all => 'TLS modules not installed (required for HTTP/2)'
        unless eval {
            require IO::Async::SSL;
            require IO::Socket::SSL;
            1;
        };
}

use IO::Async::Loop;
use IO::Async::SSL;
use Future::AsyncAwait;
use PAGI::Server;

# Load XS before Session (Session.pm doesn't load parent module)
use Net::HTTP2::nghttp2;
use Net::HTTP2::nghttp2::Session;

# Note: Net::HTTP2::nghttp2::Session->send_connection_preface() includes the magic
# So we don't need to prepend it manually

my $cert_dir = "$FindBin::Bin/../certs";
my $server_cert = "$cert_dir/server.crt";
my $server_key = "$cert_dir/server.key";

plan skip_all => 'Test certificates not found'
    unless -f $server_cert && -f $server_key;

my $loop = IO::Async::Loop->new;

# =============================================================================
# Test app
# =============================================================================
my $captured_scope;

my $test_app = async sub {
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

    $captured_scope = $scope;

    await $send->({
        type    => 'http.response.start',
        status  => 200,
        headers => [['content-type', 'text/plain']],
    });

    await $send->({
        type => 'http.response.body',
        body => "Hello HTTP/2!",
        more => 0,
    });
};

# =============================================================================
# Tests
# =============================================================================

subtest 'Server starts with HTTP/2 enabled' => sub {
    my $server = PAGI::Server->new(
        app   => $test_app,
        host  => '127.0.0.1',
        port  => 0,
        quiet => 1,
        http2 => 1,  # Enable HTTP/2 (opt-in)
        ssl   => {
            cert_file => $server_cert,
            key_file  => $server_key,
        },
    );

    $loop->add($server);
    $server->listen->get;
    my $port = $server->port;

    ok($port > 0, "server listening on port $port");
    ok(PAGI::Server->has_http2, 'HTTP/2 support is enabled');

    $server->shutdown->get;
    $loop->remove($server);
};

subtest 'ALPN negotiates HTTP/2' => sub {
    my $server = PAGI::Server->new(
        app   => $test_app,
        host  => '127.0.0.1',
        port  => 0,
        quiet => 1,
        http2 => 1,
        ssl   => {
            cert_file => $server_cert,
            key_file  => $server_key,
        },
    );

    $loop->add($server);
    $server->listen->get;
    my $port = $server->port;

    my $alpn_result;

    my $f = $loop->SSL_connect(
        host        => '127.0.0.1',
        service     => $port,
        SSL_verify_mode => IO::Socket::SSL::SSL_VERIFY_NONE(),
        SSL_alpn_protocols => ['h2', 'http/1.1'],
    );

    my $stream = eval { $f->get };
    if ($stream) {
        my $socket = $stream->read_handle;
        $alpn_result = $socket->alpn_selected // 'none';
        $stream->close_when_empty;
    }

    is($alpn_result, 'h2', 'ALPN negotiated HTTP/2');

    $server->shutdown->get;
    $loop->remove($server);
};

subtest 'HTTP/2 request and response' => sub {
    my $server = PAGI::Server->new(
        app   => $test_app,
        host  => '127.0.0.1',
        port  => 0,
        quiet => 1,
        http2 => 1,
        ssl   => {
            cert_file => $server_cert,
            key_file  => $server_key,
        },
    );

    $loop->add($server);
    $server->listen->get;
    my $port = $server->port;

    $captured_scope = undef;

    my %responses;
    my $stream_closed = 0;

    my $client = Net::HTTP2::nghttp2::Session->new_client(
        callbacks => {
            on_header => sub {
                my ($stream_id, $name, $value, $flags) = @_;
                push @{$responses{$stream_id}{headers}}, [$name, $value];
                return 0;
            },
            on_data_chunk_recv => sub {
                my ($stream_id, $data, $flags) = @_;
                $responses{$stream_id}{body} //= '';
                $responses{$stream_id}{body} .= $data;
                return 0;
            },
            on_frame_recv => sub { 0 },
            on_stream_close => sub {
                my ($stream_id, $error_code) = @_;
                $responses{$stream_id}{closed} = 1;
                $responses{$stream_id}{error_code} = $error_code;
                $stream_closed = 1;
                return 0;
            },
        },
    );

    # Build client preface
    # Note: send_connection_preface() queues both the magic string AND the SETTINGS frame
    # mem_send() returns everything (magic + SETTINGS), so don't add magic manually
    $client->send_connection_preface();
    my $preface = $client->mem_send() // '';

    # Submit request
    my $stream_id = $client->submit_request(
        method    => 'GET',
        path      => '/',
        scheme    => 'https',
        authority => "127.0.0.1:$port",
        headers   => [['user-agent', 'PAGI-Test']],
    );

    my $request_frame = $client->mem_send() // '';

    # Connect
    my $connect_f = $loop->SSL_connect(
        host        => '127.0.0.1',
        service     => $port,
        SSL_verify_mode => IO::Socket::SSL::SSL_VERIFY_NONE(),
        SSL_alpn_protocols => ['h2'],
    );

    my $stream = eval { $connect_f->get };
    ok($stream, 'SSL connection established') or do {
        diag "Connection error: $@";
        $server->shutdown->get;
        $loop->remove($server);
        return;
    };

    my $socket = $stream->read_handle;
    my $alpn = $socket->alpn_selected // '';
    is($alpn, 'h2', 'ALPN selected h2') or do {
        $stream->close_when_empty;
        $server->shutdown->get;
        $loop->remove($server);
        return;
    };

    # Set up read handling
    my $done = $loop->new_future;

    $stream->configure(
        on_read => sub {
            my ($self, $buffref, $eof) = @_;
            if (length $$buffref) {
                $client->mem_recv($$buffref);
                $$buffref = '';

                my $out = $client->mem_send;
                $self->write($out) if $out && length($out);
            }

            if ($stream_closed) {
                $done->done unless $done->is_ready;
            }

            if ($eof) {
                $done->done unless $done->is_ready;
            }

            return 0;
        },
    );

    $loop->add($stream);

    # Send client preface + request
    $stream->write($preface . $request_frame);

    # Wait for response with timeout
    my $timeout = $loop->timeout_future(after => 5);
    eval { Future->wait_any($done, $timeout)->get };
    my $err = $@;

    if ($err) {
        diag "Error waiting for response: $err";
    }

    ok($responses{$stream_id}, 'got response') or do {
        diag "No response received for stream $stream_id";
        diag "stream_closed: $stream_closed";
        diag "All responses: " . join(", ", keys %responses);
        $stream->close_when_empty;
        $server->shutdown->get;
        $loop->remove($server);
        return;
    };

    diag "Response for stream $stream_id:";
    diag "  headers: " . scalar(@{$responses{$stream_id}{headers} // []});
    diag "  body len: " . length($responses{$stream_id}{body} // '');
    diag "  error_code: " . ($responses{$stream_id}{error_code} // 'none');
    for my $h (@{$responses{$stream_id}{headers} // []}) {
        diag "  header: $h->[0] = $h->[1]";
    }

    my %hdrs = map { $_->[0] => $_->[1] } @{$responses{$stream_id}{headers} // []};
    is($hdrs{':status'}, '200', 'status is 200');
    like($responses{$stream_id}{body} // '', qr/Hello HTTP\/2/, 'body correct');

    ok($captured_scope, 'scope captured') or do {
        $stream->close_when_empty;
        $server->shutdown->get;
        $loop->remove($server);
        return;
    };

    is($captured_scope->{type}, 'http', 'type is http');
    is($captured_scope->{http_version}, '2', 'http_version is 2');
    is($captured_scope->{method}, 'GET', 'method is GET');
    is($captured_scope->{path}, '/', 'path is /');
    ok(exists $captured_scope->{extensions}{http2}, 'http2 extension exists');

    $stream->close_when_empty;
    $server->shutdown->get;
    $loop->remove($server);
};

subtest 'ALPN falls back to HTTP/1.1 when h2 not requested' => sub {
    my $server = PAGI::Server->new(
        app   => $test_app,
        host  => '127.0.0.1',
        port  => 0,
        quiet => 1,
        http2 => 1,
        ssl   => {
            cert_file => $server_cert,
            key_file  => $server_key,
        },
    );

    $loop->add($server);
    $server->listen->get;
    my $port = $server->port;

    my $alpn_result;

    my $f = $loop->SSL_connect(
        host        => '127.0.0.1',
        service     => $port,
        SSL_verify_mode => IO::Socket::SSL::SSL_VERIFY_NONE(),
        SSL_alpn_protocols => ['http/1.1'],
    );

    my $stream = eval { $f->get };
    if ($stream) {
        my $socket = $stream->read_handle;
        $alpn_result = $socket->alpn_selected // 'none';
        $stream->close_when_empty;
    }

    is($alpn_result, 'http/1.1', 'ALPN selected HTTP/1.1 when h2 not requested');

    $server->shutdown->get;
    $loop->remove($server);
};

done_testing;
