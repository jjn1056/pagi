#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use File::Temp qw(tempfile);

use lib 'lib';
use PAGI::Test::Client;

# Simple test app
my $app = async sub {
    my ($scope, $receive, $send) = @_;

    await $send->({
        type    => 'http.response.start',
        status  => 200,
        headers => [['content-type', 'text/plain']],
    });

    await $send->({
        type => 'http.response.body',
        body => 'Hello World',
        more => 0,
    });
};

subtest 'basic GET request' => sub {
    my $client = PAGI::Test::Client->new(app => $app);
    my $res = $client->get('/');

    is $res->status, 200, 'status 200';
    is $res->text, 'Hello World', 'body';
    is $res->header('content-type'), 'text/plain', 'content-type';
};

subtest 'captures filehandle response bodies' => sub {
    my $fh_app = async sub {
        my ($scope, $receive, $send) = @_;
        my $content = "Hello from filehandle";

        open my $fh, '<', \$content or die "Cannot open scalar handle: $!";

        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [
                ['content-type', 'text/plain'],
                ['content-length', length($content)],
            ],
        });

        await $send->({
            type => 'http.response.body',
            fh   => $fh,
        });

        close $fh;
    };

    my $client = PAGI::Test::Client->new(app => $fh_app);
    my $res = $client->get('/');

    is $res->status, 200, 'status 200';
    is $res->content, 'Hello from filehandle', 'filehandle body captured';
};

subtest 'captures file response bodies' => sub {
    my ($fh, $path) = tempfile();
    print {$fh} 'Hello from file';
    close $fh;

    my $file_app = async sub {
        my ($scope, $receive, $send) = @_;

        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [['content-type', 'text/plain']],
        });

        await $send->({
            type => 'http.response.body',
            file => $path,
        });
    };

    my $client = PAGI::Test::Client->new(app => $file_app);
    my $res = $client->get('/');

    is $res->status, 200, 'status 200';
    is $res->content, 'Hello from file', 'file body captured';
};

subtest 'captures filehandle response offset and length' => sub {
    my $fh_app = async sub {
        my ($scope, $receive, $send) = @_;
        my $content = '0123456789';

        open my $fh, '<', \$content or die "Cannot open scalar handle: $!";

        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [['content-type', 'text/plain']],
        });

        await $send->({
            type   => 'http.response.body',
            fh     => $fh,
            offset => 2,
            length => 4,
        });

        close $fh;
    };

    my $client = PAGI::Test::Client->new(app => $fh_app);
    my $res = $client->get('/');

    is $res->content, '2345', 'filehandle offset/length respected';
};

subtest 'captures file response offset and length' => sub {
    my ($fh, $path) = tempfile();
    print {$fh} 'abcdefghij';
    close $fh;

    my $file_app = async sub {
        my ($scope, $receive, $send) = @_;

        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [['content-type', 'text/plain']],
        });

        await $send->({
            type   => 'http.response.body',
            file   => $path,
            offset => 3,
            length => 3,
        });
    };

    my $client = PAGI::Test::Client->new(app => $file_app);
    my $res = $client->get('/');

    is $res->content, 'def', 'file offset/length respected';
};

subtest 'HEAD suppresses response body transport semantics' => sub {
    my $head_app = async sub {
        my ($scope, $receive, $send) = @_;
        my $content = 'Body that HEAD must suppress';

        open my $fh, '<', \$content or die "Cannot open scalar handle: $!";

        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [
                ['content-type', 'text/plain'],
                ['content-length', length($content)],
            ],
        });

        await $send->({
            type => 'http.response.body',
            fh   => $fh,
        });

        close $fh;
    };

    my $client = PAGI::Test::Client->new(app => $head_app);

    is $client->get('/')->content, 'Body that HEAD must suppress', 'GET still returns body';
    is $client->head('/')->content, '', 'HEAD response body suppressed';
};

subtest 'ignores duplicate response.start events' => sub {
    my $dup_start_app = async sub {
        my ($scope, $receive, $send) = @_;

        await $send->({
            type    => 'http.response.start',
            status  => 201,
            headers => [['content-type', 'text/plain']],
        });

        await $send->({
            type    => 'http.response.start',
            status  => 500,
            headers => [['content-type', 'application/json']],
        });

        await $send->({
            type => 'http.response.body',
            body => 'first start wins',
        });
    };

    my $client = PAGI::Test::Client->new(app => $dup_start_app);
    my $res = $client->get('/');

    is $res->status, 201, 'first status preserved';
    is $res->header('content-type'), 'text/plain', 'first headers preserved';
    is $res->content, 'first start wins', 'body still captured';
};

subtest 'ignores body events after response completion' => sub {
    my $extra_body_app = async sub {
        my ($scope, $receive, $send) = @_;

        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [['content-type', 'text/plain']],
        });

        await $send->({
            type => 'http.response.body',
            body => 'done',
            more => 0,
        });

        await $send->({
            type => 'http.response.body',
            body => 'ignored',
            more => 0,
        });
    };

    my $client = PAGI::Test::Client->new(app => $extra_body_app);
    my $res = $client->get('/');

    is $res->content, 'done', 'body after completion ignored';
};

subtest 'GET with path' => sub {
    my $path_app = async sub {
        my ($scope, $receive, $send) = @_;

        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [['content-type', 'text/plain']],
        });

        await $send->({
            type => 'http.response.body',
            body => "Path: $scope->{path}",
            more => 0,
        });
    };

    my $client = PAGI::Test::Client->new(app => $path_app);
    my $res = $client->get('/users/123');

    is $res->text, 'Path: /users/123', 'path passed to app';
};

subtest 'POST with JSON body' => sub {
    my $json_app = async sub {
        my ($scope, $receive, $send) = @_;

        # Read request body
        my $event = await $receive->();
        my $body = $event->{body};

        require JSON::MaybeXS;
        my $data = JSON::MaybeXS::decode_json($body);

        await $send->({
            type    => 'http.response.start',
            status  => 201,
            headers => [['content-type', 'application/json']],
        });

        await $send->({
            type => 'http.response.body',
            body => JSON::MaybeXS::encode_json({ id => 1, name => $data->{name} }),
            more => 0,
        });
    };

    my $client = PAGI::Test::Client->new(app => $json_app);
    my $res = $client->post('/users', json => { name => 'John' });

    is $res->status, 201, 'status 201';
    is $res->json->{id}, 1, 'got id';
    is $res->json->{name}, 'John', 'got name back';
};

subtest 'POST with form data' => sub {
    my $form_app = async sub {
        my ($scope, $receive, $send) = @_;

        my $event = await $receive->();
        my $body = $event->{body};

        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [['content-type', 'text/plain']],
        });

        await $send->({
            type => 'http.response.body',
            body => "Form: $body",
            more => 0,
        });
    };

    my $client = PAGI::Test::Client->new(app => $form_app);
    my $res = $client->post('/login', form => { user => 'admin', pass => 'secret' });

    like $res->text, qr/user=admin/, 'form has user';
    like $res->text, qr/pass=secret/, 'form has pass';
};

subtest 'PUT and PATCH methods' => sub {
    my $method_app = async sub {
        my ($scope, $receive, $send) = @_;

        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [['content-type', 'text/plain']],
        });

        await $send->({
            type => 'http.response.body',
            body => "Method: $scope->{method}",
            more => 0,
        });
    };

    my $client = PAGI::Test::Client->new(app => $method_app);

    is $client->put('/resource')->text, 'Method: PUT', 'PUT works';
    is $client->patch('/resource')->text, 'Method: PATCH', 'PATCH works';
    is $client->options('/resource')->text, 'Method: OPTIONS', 'OPTIONS works';
};

subtest 'query parameter encoding' => sub {
    my $query_app = async sub {
        my ($scope, $receive, $send) = @_;

        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [['content-type', 'text/plain']],
        });

        await $send->({
            type => 'http.response.body',
            body => "Query: $scope->{query_string}",
            more => 0,
        });
    };

    my $client = PAGI::Test::Client->new(app => $query_app);

    # Test special characters are encoded
    my $res = $client->get('/test', query => { 'key with spaces' => 'value&with=special' });
    like $res->text, qr/key%20with%20spaces/, 'key is URL encoded';
    like $res->text, qr/value%26with%3Dspecial/, 'value is URL encoded';

    # Test query params merge with path query
    $res = $client->get('/test?existing=param', query => { foo => 'bar' });
    like $res->text, qr/existing=param/, 'path query preserved';
    like $res->text, qr/foo=bar/, 'option query added';
};

subtest 'cookies persist across requests' => sub {
    my $cookie_app = async sub {
        my ($scope, $receive, $send) = @_;

        # Check for cookie header
        my $has_cookie = '';
        for my $h (@{$scope->{headers}}) {
            if (lc($h->[0]) eq 'cookie') {
                $has_cookie = $h->[1];
            }
        }

        my @resp_headers = (['content-type', 'text/plain']);
        my $body;

        if ($scope->{path} eq '/login') {
            push @resp_headers, ['set-cookie', 'session=abc123'];
            $body = 'logged in';
        } else {
            $body = $has_cookie ? "Cookie: $has_cookie" : "No cookie";
        }

        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => \@resp_headers,
        });

        await $send->({
            type => 'http.response.body',
            body => $body,
            more => 0,
        });
    };

    my $client = PAGI::Test::Client->new(app => $cookie_app);

    # Before login - no cookie
    is $client->get('/dashboard')->text, 'No cookie', 'no cookie initially';

    # Login sets cookie
    is $client->get('/login')->text, 'logged in', 'login response';

    # After login - cookie sent
    like $client->get('/dashboard')->text, qr/session=abc123/, 'cookie persisted';

    # Cookie accessors
    is $client->cookie('session'), 'abc123', 'cookie() accessor';
    ok exists $client->cookies->{session}, 'cookies() hashref';

    # Clear cookies
    $client->clear_cookies;
    is $client->get('/dashboard')->text, 'No cookie', 'cookies cleared';
};

subtest 'set_cookie manually' => sub {
    my $echo_app = async sub {
        my ($scope, $receive, $send) = @_;

        my $cookie = '';
        for my $h (@{$scope->{headers}}) {
            $cookie = $h->[1] if lc($h->[0]) eq 'cookie';
        }

        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [['content-type', 'text/plain']],
        });

        await $send->({
            type => 'http.response.body',
            body => "Cookie: $cookie",
            more => 0,
        });
    };

    my $client = PAGI::Test::Client->new(app => $echo_app);
    $client->set_cookie('theme', 'dark');

    like $client->get('/')->text, qr/theme=dark/, 'manual cookie sent';
};

done_testing;
