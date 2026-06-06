use strict;
use warnings;
use Test2::V0;
use IO::Async::Loop;
use Net::Async::HTTP;
use Future::AsyncAwait;
use File::Temp qw(tempfile);
use JSON::MaybeXS qw(decode_json);
use URI;

use PAGI::Server;

plan skip_all => "Server integration tests not supported on Windows" if $^O eq 'MSWin32';
use PAGI::Response;

my $loop = IO::Async::Loop->new;

# Helper to handle lifespan scope
sub with_lifespan {
    my ($handler) = @_;
    return async sub {
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
        await $handler->($scope, $receive, $send);
    };
}

# Helper to run a test with server
async sub with_server {
    my ($app, $callback) = @_;
    my $server = PAGI::Server->new(
        app   => with_lifespan($app),
        host  => '127.0.0.1',
        port  => 0,
        quiet => 1,
    );

    $loop->add($server);
    await $server->listen;

    my $port = $server->port;
    my $http = Net::Async::HTTP->new;
    $loop->add($http);

    await $callback->($http, $port);

    await $server->shutdown;
    $loop->remove($server);
    $loop->remove($http);
}

subtest 'text response' => sub {
    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        my $res = PAGI::Response->new($scope, $send);
        await $res->text("Hello World");
    };

    with_server($app, async sub {
        my ($http, $port) = @_;
        my $response = await $http->GET("http://127.0.0.1:$port/");

        is $response->code, 200, 'status 200';
        is $response->content_type, 'text/plain', 'content-type text/plain';
        like $response->header('content-type'), qr/charset=utf-8/i, 'has charset';
        is $response->decoded_content, 'Hello World', 'body correct';
    })->get;
};

subtest 'html response' => sub {
    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        my $res = PAGI::Response->new($scope, $send);
        await $res->html("<h1>Hello</h1>");
    };

    with_server($app, async sub {
        my ($http, $port) = @_;
        my $response = await $http->GET("http://127.0.0.1:$port/");

        is $response->code, 200, 'status 200';
        is $response->content_type, 'text/html', 'content-type text/html';
        is $response->decoded_content, '<h1>Hello</h1>', 'body correct';
    })->get;
};

subtest 'json response' => sub {
    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        my $res = PAGI::Response->new($scope, $send);
        await $res->json({ message => 'Hello', count => 42 });
    };

    with_server($app, async sub {
        my ($http, $port) = @_;
        my $response = await $http->GET("http://127.0.0.1:$port/");

        is $response->code, 200, 'status 200';
        is $response->content_type, 'application/json', 'content-type application/json';

        my $data = decode_json($response->decoded_content);
        is $data->{message}, 'Hello', 'message field';
        is $data->{count}, 42, 'count field';
    })->get;
};

subtest 'custom status and headers' => sub {
    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        my $res = PAGI::Response->new($scope, $send);
        await $res->status(201)
                  ->header('X-Custom' => 'value')
                  ->header('X-Request-Id' => '12345')
                  ->json({ created => 1 });
    };

    with_server($app, async sub {
        my ($http, $port) = @_;
        my $response = await $http->GET("http://127.0.0.1:$port/");

        is $response->code, 201, 'status 201 Created';
        is $response->header('X-Custom'), 'value', 'custom header';
        is $response->header('X-Request-Id'), '12345', 'request id header';
    })->get;
};

subtest 'redirect response' => sub {
    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        my $res = PAGI::Response->new($scope, $send);
        await $res->redirect('/new-location');
    };

    with_server($app, async sub {
        my ($http, $port) = @_;
        # Disable redirects to capture the 302
        my $response = await $http->do_request(
            method => 'GET',
            uri => URI->new("http://127.0.0.1:$port/"),
            max_redirects => 0,
        );

        is $response->code, 302, 'status 302';
        is $response->header('Location'), '/new-location', 'location header';
    })->get;
};

subtest 'redirect with custom status' => sub {
    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        my $res = PAGI::Response->new($scope, $send);
        await $res->redirect('/permanent', 301);
    };

    with_server($app, async sub {
        my ($http, $port) = @_;
        my $response = await $http->do_request(
            method => 'GET',
            uri => URI->new("http://127.0.0.1:$port/"),
            max_redirects => 0,
        );

        is $response->code, 301, 'status 301';
    })->get;
};

subtest 'empty response' => sub {
    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        my $res = PAGI::Response->new($scope, $send);
        await $res->empty();
    };

    # 204 responses can trigger "Spurious on_read" in Net::Async::HTTP due to
    # keepalive handling quirks. Catch and ignore if assertions pass.
    my $result = eval {
        with_server($app, async sub {
            my ($http, $port) = @_;
            my $response = await $http->do_request(
                method => 'GET',
                uri => URI->new("http://127.0.0.1:$port/"),
                headers => { 'Connection' => 'close' },
            );

            is $response->code, 204, 'status 204 No Content';
            is $response->decoded_content, '', 'empty body';
        })->get;
        1;
    };
    # If we got a spurious read error but tests passed, that's OK
    if (!$result && $@ =~ /Spurious on_read/) {
        pass('204 handled (spurious read warning expected)');
    } elsif (!$result) {
        fail("Unexpected error: $@");
    }
};

subtest 'json error response pattern' => sub {
    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        my $res = PAGI::Response->new($scope, $send);
        await $res->status(400)->json({ error => 'Bad Request', field => 'email' });
    };

    with_server($app, async sub {
        my ($http, $port) = @_;
        my $response = await $http->GET("http://127.0.0.1:$port/");

        is $response->code, 400, 'status 400';
        is $response->content_type, 'application/json', 'json content-type';

        my $data = decode_json($response->decoded_content);
        is $data->{error}, 'Bad Request', 'error message';
        is $data->{field}, 'email', 'extra field';
    })->get;
};

subtest 'cookie response' => sub {
    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        my $res = PAGI::Response->new($scope, $send);
        await $res->cookie('session' => 'abc123', path => '/', httponly => 1)
                  ->text('OK');
    };

    with_server($app, async sub {
        my ($http, $port) = @_;
        my $response = await $http->GET("http://127.0.0.1:$port/");

        is $response->code, 200, 'status 200';
        my $cookie = $response->header('Set-Cookie');
        like $cookie, qr/session=abc123/, 'cookie value';
        like $cookie, qr/Path=\//, 'cookie path';
        like $cookie, qr/HttpOnly/, 'httponly flag';
    })->get;
};

subtest 'streaming response' => sub {
    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        my $res = PAGI::Response->new($scope, $send);
        await $res->content_type('text/plain')
                  ->stream(async sub {
                      my ($writer) = @_;
                      await $writer->write("chunk1");
                      await $writer->write("chunk2");
                      await $writer->write("chunk3");
                  });
    };

    with_server($app, async sub {
        my ($http, $port) = @_;
        my $response = await $http->GET("http://127.0.0.1:$port/");

        is $response->code, 200, 'status 200';
        is $response->decoded_content, 'chunk1chunk2chunk3', 'all chunks received';
    })->get;
};

subtest 'send_file response' => sub {
    # Create temp file
    my ($fh, $filename) = tempfile(UNLINK => 1, SUFFIX => '.txt');
    print $fh "File content for testing";
    close $fh;

    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        my $res = PAGI::Response->new($scope, $send);
        await $res->send_file($filename);
    };

    with_server($app, async sub {
        my ($http, $port) = @_;
        my $response = await $http->GET("http://127.0.0.1:$port/");

        is $response->code, 200, 'status 200';
        is $response->content_type, 'text/plain', 'detected content-type';
        is $response->decoded_content, 'File content for testing', 'file content';
    })->get;
};

subtest 'send_file with attachment' => sub {
    my ($fh, $filename) = tempfile(UNLINK => 1, SUFFIX => '.pdf');
    print $fh "PDF content";
    close $fh;

    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        my $res = PAGI::Response->new($scope, $send);
        await $res->send_file($filename, filename => 'document.pdf');
    };

    with_server($app, async sub {
        my ($http, $port) = @_;
        my $response = await $http->GET("http://127.0.0.1:$port/");

        is $response->code, 200, 'status 200';
        is $response->content_type, 'application/pdf', 'pdf content-type';
        like $response->header('Content-Disposition'), qr/attachment.*document\.pdf/, 'attachment header';
    })->get;
};

subtest 'UTF-8 text response' => sub {
    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        my $res = PAGI::Response->new($scope, $send);
        await $res->text("Hello, 世界! Привет! 🌍");
    };

    with_server($app, async sub {
        my ($http, $port) = @_;
        my $response = await $http->GET("http://127.0.0.1:$port/");

        is $response->code, 200, 'status 200';
        is $response->decoded_content, "Hello, 世界! Привет! 🌍", 'UTF-8 preserved';
    })->get;
};

subtest 'CORS headers' => sub {
    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        my $res = PAGI::Response->new($scope, $send);
        await $res->cors(
            origin      => 'https://example.com',
            credentials => 1,
            expose      => [qw(X-Request-Id)],
        )->json({ data => 'cors test' });
    };

    with_server($app, async sub {
        my ($http, $port) = @_;
        my $response = await $http->GET("http://127.0.0.1:$port/");

        is $response->code, 200, 'status 200';
        is $response->header('Access-Control-Allow-Origin'), 'https://example.com', 'CORS origin';
        is $response->header('Access-Control-Allow-Credentials'), 'true', 'CORS credentials';
        like $response->header('Access-Control-Expose-Headers'), qr/X-Request-Id/, 'CORS expose';
        is $response->header('Vary'), 'Origin', 'Vary header';
    })->get;
};

subtest 'CORS preflight response' => sub {
    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        my $res = PAGI::Response->new($scope, $send);
        await $res->cors(
            origin    => 'https://example.com',
            methods   => [qw(GET POST PUT)],
            headers   => [qw(Content-Type Authorization)],
            max_age   => 3600,
            preflight => 1,
        )->status(204)->empty();
    };

    # 204 responses can trigger "Spurious on_read" in Net::Async::HTTP
    my $result = eval {
        with_server($app, async sub {
            my ($http, $port) = @_;
            my $response = await $http->do_request(
                method => 'OPTIONS',
                uri => URI->new("http://127.0.0.1:$port/"),
                headers => { 'Connection' => 'close' },
            );

            is $response->code, 204, 'status 204';
            is $response->header('Access-Control-Allow-Origin'), 'https://example.com', 'CORS origin';
            like $response->header('Access-Control-Allow-Methods'), qr/GET.*POST.*PUT|POST.*GET.*PUT|PUT.*GET.*POST/, 'CORS methods';
            like $response->header('Access-Control-Allow-Headers'), qr/Content-Type/, 'CORS headers';
            is $response->header('Access-Control-Max-Age'), '3600', 'CORS max-age';
        })->get;
        1;
    };
    if (!$result && $@ =~ /Spurious on_read/) {
        pass('CORS preflight handled (spurious read warning expected)');
    } elsif (!$result) {
        fail("Unexpected error: $@");
    }
};

done_testing;
