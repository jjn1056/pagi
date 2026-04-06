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

done_testing;
