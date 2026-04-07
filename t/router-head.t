use strict;
use warnings;

use Test2::V0;
use Future::AsyncAwait;

use PAGI::App::Router;

# Helper to capture response events
sub mock_send {
    my @sent;
    my $send = sub { my ($msg) = @_; push @sent, $msg; Future->done };
    return ($send, \@sent);
}

# Helper to create a GET handler that returns a body with Content-Length
sub make_get_handler {
    my ($body) = @_;
    return async sub {
        my ($scope, $receive, $send) = @_;
        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [
                ['content-type', 'text/plain'],
                ['content-length', length($body)],
            ],
        });
        await $send->({
            type => 'http.response.body',
            body => $body,
            more => 0,
        });
    };
}

subtest 'HEAD request to GET route returns empty body' => sub {
    my $router = PAGI::App::Router->new;
    $router->get('/hello' => make_get_handler('Hello World'));

    my $app = $router->to_app;

    my ($send, $sent) = mock_send();
    $app->({ method => 'HEAD', path => '/hello' }, sub { Future->done }, $send)->get;

    is $sent->[0]{status}, 200, 'status is 200';
    is $sent->[1]{body}, '', 'body is empty string';
    is $sent->[1]{more}, 0, 'more flag preserved';
};

subtest 'HEAD request preserves Content-Length from GET handler' => sub {
    my $router = PAGI::App::Router->new;
    my $body = 'Hello World';
    $router->get('/hello' => make_get_handler($body));

    my $app = $router->to_app;

    my ($send, $sent) = mock_send();
    $app->({ method => 'HEAD', path => '/hello' }, sub { Future->done }, $send)->get;

    # Find content-length in headers
    my %headers = map { $_->[0] => $_->[1] } @{$sent->[0]{headers}};
    is $headers{'content-length'}, length($body), 'Content-Length preserved from GET handler';
    is $sent->[0]{status}, 200, 'status preserved';
};

subtest 'explicit head() route handler controls its own response' => sub {
    my $router = PAGI::App::Router->new;

    # Register both GET and explicit HEAD for the same path
    $router->get('/resource' => make_get_handler('GET body'));
    $router->head('/resource' => async sub {
        my ($scope, $receive, $send) = @_;
        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [['x-custom', 'head-handler']],
        });
        await $send->({
            type => 'http.response.body',
            body => '',
            more => 0,
        });
    });

    my $app = $router->to_app;

    my ($send, $sent) = mock_send();
    $app->({ method => 'HEAD', path => '/resource' }, sub { Future->done }, $send)->get;

    # The explicit HEAD handler should have been called, not the GET handler
    my %headers = map { $_->[0] => $_->[1] } @{$sent->[0]{headers}};
    is $headers{'x-custom'}, 'head-handler', 'explicit HEAD handler was called';
};

subtest 'HEAD strips body from streaming response (multiple chunks)' => sub {
    my $router = PAGI::App::Router->new;
    $router->get('/stream' => async sub {
        my ($scope, $receive, $send) = @_;
        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [['content-type', 'text/plain']],
        });
        await $send->({ type => 'http.response.body', body => 'chunk1', more => 1 });
        await $send->({ type => 'http.response.body', body => 'chunk2', more => 1 });
        await $send->({ type => 'http.response.body', body => 'chunk3', more => 0 });
    });

    my $app = $router->to_app;

    my ($send, $sent) = mock_send();
    $app->({ method => 'HEAD', path => '/stream' }, sub { Future->done }, $send)->get;

    is $sent->[0]{status}, 200, 'status preserved';
    is $sent->[1]{body}, '', 'chunk 1 body stripped';
    is $sent->[1]{more}, 1, 'chunk 1 more flag preserved';
    is $sent->[2]{body}, '', 'chunk 2 body stripped';
    is $sent->[2]{more}, 1, 'chunk 2 more flag preserved';
    is $sent->[3]{body}, '', 'chunk 3 body stripped';
    is $sent->[3]{more}, 0, 'chunk 3 more flag preserved';
};

subtest 'HEAD to non-existent route returns 404' => sub {
    my $router = PAGI::App::Router->new;
    $router->get('/exists' => make_get_handler('yes'));

    my $app = $router->to_app;

    my ($send, $sent) = mock_send();
    $app->({ method => 'HEAD', path => '/nope' }, sub { Future->done }, $send)->get;

    is $sent->[0]{status}, 404, 'HEAD to unknown path is 404';
};

subtest 'HEAD returns 405 when path matches but only POST defined' => sub {
    my $router = PAGI::App::Router->new;
    $router->post('/submit' => async sub {
        my ($scope, $receive, $send) = @_;
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'ok', more => 0 });
    });

    my $app = $router->to_app;

    my ($send, $sent) = mock_send();
    $app->({ method => 'HEAD', path => '/submit' }, sub { Future->done }, $send)->get;

    is $sent->[0]{status}, 405, 'HEAD to POST-only path is 405';

    my %headers = map { $_->[0] => $_->[1] } @{$sent->[0]{headers}};
    like $headers{'allow'}, qr/POST/, 'Allow header includes POST';
};

done_testing;
