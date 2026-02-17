use strict;
use warnings;

use Test2::V0;
use Future::AsyncAwait;

use PAGI::App::Router;

# Helper to capture response
sub mock_send {
    my @sent;
    my $send = sub { my ($msg) = @_; push @sent, $msg; Future->done };
    return ($send, \@sent);
}

# Helper to create a simple app that records it was called
sub make_handler {
    my ($name, $capture) = @_;
    return async sub {
        my ($scope, $receive, $send) = @_;
        push @$capture, { name => $name, scope => $scope } if $capture;
        await $send->({
            type => 'http.response.start',
            status => 200,
            headers => [['content-type', 'text/plain']],
        });
        await $send->({
            type => 'http.response.body',
            body => $name,
            more => 0,
        });
    };
}

subtest 'basic routing' => sub {
    my @calls;
    my $router = PAGI::App::Router->new;
    $router->get('/users' => make_handler('list_users', \@calls));
    $router->get('/users/:id' => make_handler('get_user', \@calls));
    $router->post('/users' => make_handler('create_user', \@calls));

    my $app = $router->to_app;

    # GET /users
    my ($send, $sent) = mock_send();
    $app->({ method => 'GET', path => '/users' }, sub { Future->done }, $send)->get;
    is $sent->[0]{status}, 200, 'GET /users - status 200';
    is $sent->[1]{body}, 'list_users', 'GET /users - correct handler';

    # GET /users/42
    @calls = ();
    ($send, $sent) = mock_send();
    $app->({ method => 'GET', path => '/users/42' }, sub { Future->done }, $send)->get;
    is $sent->[0]{status}, 200, 'GET /users/42 - status 200';
    is $sent->[1]{body}, 'get_user', 'GET /users/42 - correct handler';
    is $calls[0]{scope}{path_params}{id}, '42', 'captured :id param';

    # POST /users
    ($send, $sent) = mock_send();
    $app->({ method => 'POST', path => '/users' }, sub { Future->done }, $send)->get;
    is $sent->[0]{status}, 200, 'POST /users - status 200';
    is $sent->[1]{body}, 'create_user', 'POST /users - correct handler';
};

subtest '404 not found' => sub {
    my $router = PAGI::App::Router->new;
    $router->get('/home' => make_handler('home'));
    my $app = $router->to_app;

    my ($send, $sent) = mock_send();
    $app->({ method => 'GET', path => '/nonexistent' }, sub { Future->done }, $send)->get;
    is $sent->[0]{status}, 404, 'unmatched path returns 404';
};

subtest '405 method not allowed' => sub {
    my $router = PAGI::App::Router->new;
    $router->get('/resource' => make_handler('get_resource'));
    $router->post('/resource' => make_handler('create_resource'));
    my $app = $router->to_app;

    my ($send, $sent) = mock_send();
    $app->({ method => 'DELETE', path => '/resource' }, sub { Future->done }, $send)->get;
    is $sent->[0]{status}, 405, 'wrong method returns 405';

    my %headers = map { $_->[0] => $_->[1] } @{$sent->[0]{headers}};
    like $headers{allow}, qr/GET/, 'Allow header includes GET';
    like $headers{allow}, qr/POST/, 'Allow header includes POST';
};

subtest 'wildcard parameter' => sub {
    my @calls;
    my $router = PAGI::App::Router->new;
    $router->get('/files/*path' => make_handler('serve_file', \@calls));
    my $app = $router->to_app;

    my ($send, $sent) = mock_send();
    $app->({ method => 'GET', path => '/files/docs/readme.txt' }, sub { Future->done }, $send)->get;
    is $sent->[0]{status}, 200, 'wildcard matched';
    is $calls[0]{scope}{path_params}{path}, 'docs/readme.txt', 'wildcard captured rest of path';
};

subtest 'mount basic' => sub {
    my @calls;

    # API sub-router
    my $api = PAGI::App::Router->new;
    $api->get('/users' => make_handler('api_users', \@calls));
    $api->get('/users/:id' => make_handler('api_user', \@calls));

    # Main router
    my $main = PAGI::App::Router->new;
    $main->get('/' => make_handler('home', \@calls));
    $main->mount('/api' => $api->to_app);

    my $app = $main->to_app;

    # GET / - regular route
    my ($send, $sent) = mock_send();
    $app->({ method => 'GET', path => '/' }, sub { Future->done }, $send)->get;
    is $sent->[1]{body}, 'home', 'root path works';

    # GET /api/users - mounted route
    @calls = ();
    ($send, $sent) = mock_send();
    $app->({ method => 'GET', path => '/api/users' }, sub { Future->done }, $send)->get;
    is $sent->[1]{body}, 'api_users', 'mounted /api/users works';
    is $calls[0]{scope}{path}, '/users', 'mounted app sees stripped path';
    is $calls[0]{scope}{root_path}, '/api', 'mounted app has root_path set';

    # GET /api/users/42 - mounted route with params
    @calls = ();
    ($send, $sent) = mock_send();
    $app->({ method => 'GET', path => '/api/users/42' }, sub { Future->done }, $send)->get;
    is $sent->[1]{body}, 'api_user', 'mounted /api/users/:id works';
    is $calls[0]{scope}{path}, '/users/42', 'path stripped correctly';
    is $calls[0]{scope}{path_params}{id}, '42', 'params captured in mounted router';
};

subtest 'mount exact prefix match' => sub {
    my @calls;

    my $api = PAGI::App::Router->new;
    $api->get('/' => make_handler('api_root', \@calls));

    my $main = PAGI::App::Router->new;
    $main->mount('/api' => $api->to_app);

    my $app = $main->to_app;

    # GET /api (exact prefix, no trailing path)
    my ($send, $sent) = mock_send();
    $app->({ method => 'GET', path => '/api' }, sub { Future->done }, $send)->get;
    is $sent->[1]{body}, 'api_root', '/api matches mounted root';
    is $calls[0]{scope}{path}, '/', 'path becomes /';
};

subtest 'mount longer prefix priority' => sub {
    my @calls;

    my $api_v1 = PAGI::App::Router->new;
    $api_v1->get('/info' => make_handler('v1_info', \@calls));

    my $api_v2 = PAGI::App::Router->new;
    $api_v2->get('/info' => make_handler('v2_info', \@calls));

    my $main = PAGI::App::Router->new;
    $main->mount('/api' => $api_v1->to_app);
    $main->mount('/api/v2' => $api_v2->to_app);  # Longer prefix

    my $app = $main->to_app;

    # GET /api/v2/info should match /api/v2 mount, not /api
    my ($send, $sent) = mock_send();
    $app->({ method => 'GET', path => '/api/v2/info' }, sub { Future->done }, $send)->get;
    is $sent->[1]{body}, 'v2_info', 'longer prefix /api/v2 matches first';

    # GET /api/info should match /api mount
    @calls = ();
    ($send, $sent) = mock_send();
    $app->({ method => 'GET', path => '/api/info' }, sub { Future->done }, $send)->get;
    is $sent->[1]{body}, 'v1_info', '/api matches when /api/v2 does not';
};

subtest 'mount preserves existing root_path' => sub {
    my @calls;

    my $inner = PAGI::App::Router->new;
    $inner->get('/data' => make_handler('inner_data', \@calls));

    my $main = PAGI::App::Router->new;
    $main->mount('/nested' => $inner->to_app);

    my $app = $main->to_app;

    # Simulate already having a root_path (e.g., from outer mount)
    my ($send, $sent) = mock_send();
    $app->({ method => 'GET', path => '/nested/data', root_path => '/outer' }, sub { Future->done }, $send)->get;
    is $calls[0]{scope}{root_path}, '/outer/nested', 'root_path is appended, not replaced';
};

subtest 'mount 404 falls through' => sub {
    my $api = PAGI::App::Router->new;
    $api->get('/users' => make_handler('users'));

    my $main = PAGI::App::Router->new;
    $main->mount('/api' => $api->to_app);

    my $app = $main->to_app;

    # /other doesn't match /api mount, so falls to main router's 404
    my ($send, $sent) = mock_send();
    $app->({ method => 'GET', path => '/other' }, sub { Future->done }, $send)->get;
    is $sent->[0]{status}, 404, 'unmatched path outside mount returns 404';
};

subtest 'mount with any PAGI app' => sub {
    # Mount can take any PAGI app, not just routers
    my $static_app = async sub {
        my ($scope, $receive, $send) = @_;
        await $send->({
            type => 'http.response.start',
            status => 200,
            headers => [['content-type', 'text/plain']],
        });
        await $send->({
            type => 'http.response.body',
            body => "Static: $scope->{path}",
            more => 0,
        });
    };

    my $main = PAGI::App::Router->new;
    $main->mount('/static' => $static_app);

    my $app = $main->to_app;

    my ($send, $sent) = mock_send();
    $app->({ method => 'GET', path => '/static/css/style.css' }, sub { Future->done }, $send)->get;
    is $sent->[1]{body}, 'Static: /css/style.css', 'any PAGI app can be mounted';
};

subtest 'websocket route basic' => sub {
    my @calls;
    my $router = PAGI::App::Router->new;
    $router->websocket('/ws/echo' => make_handler('ws_echo', \@calls));
    my $app = $router->to_app;

    # WebSocket request to /ws/echo
    my ($send, $sent) = mock_send();
    $app->({ type => 'websocket', path => '/ws/echo' }, sub { Future->done }, $send)->get;
    is $sent->[0]{status}, 200, 'websocket route matched';
    is $sent->[1]{body}, 'ws_echo', 'websocket handler called';
};

subtest 'sse route basic' => sub {
    my @calls;
    my $router = PAGI::App::Router->new;
    $router->sse('/events' => make_handler('sse_events', \@calls));
    my $app = $router->to_app;

    # SSE request to /events
    my ($send, $sent) = mock_send();
    $app->({ type => 'sse', path => '/events' }, sub { Future->done }, $send)->get;
    is $sent->[0]{status}, 200, 'sse route matched';
    is $sent->[1]{body}, 'sse_events', 'sse handler called';
};

subtest 'websocket route with params' => sub {
    my @calls;
    my $router = PAGI::App::Router->new;
    $router->websocket('/ws/chat/:room' => make_handler('ws_chat', \@calls));
    my $app = $router->to_app;

    my ($send, $sent) = mock_send();
    $app->({ type => 'websocket', path => '/ws/chat/general' }, sub { Future->done }, $send)->get;
    is $sent->[0]{status}, 200, 'websocket with param matched';
    is $calls[0]{scope}{path_params}{room}, 'general', 'captured :room param';
};

subtest 'sse route with params' => sub {
    my @calls;
    my $router = PAGI::App::Router->new;
    $router->sse('/events/:channel' => make_handler('sse_channel', \@calls));
    my $app = $router->to_app;

    my ($send, $sent) = mock_send();
    $app->({ type => 'sse', path => '/events/notifications' }, sub { Future->done }, $send)->get;
    is $sent->[0]{status}, 200, 'sse with param matched';
    is $calls[0]{scope}{path_params}{channel}, 'notifications', 'captured :channel param';
};

subtest 'mixed protocol routing' => sub {
    my @calls;
    my $router = PAGI::App::Router->new;

    # HTTP routes
    $router->get('/api/messages' => make_handler('http_get', \@calls));
    $router->post('/api/messages' => make_handler('http_post', \@calls));

    # WebSocket route
    $router->websocket('/ws/echo' => make_handler('ws_echo', \@calls));

    # SSE route
    $router->sse('/events' => make_handler('sse_events', \@calls));

    my $app = $router->to_app;

    # Test HTTP GET
    my ($send, $sent) = mock_send();
    $app->({ type => 'http', method => 'GET', path => '/api/messages' }, sub { Future->done }, $send)->get;
    is $sent->[1]{body}, 'http_get', 'HTTP GET works';

    # Test HTTP POST
    ($send, $sent) = mock_send();
    $app->({ type => 'http', method => 'POST', path => '/api/messages' }, sub { Future->done }, $send)->get;
    is $sent->[1]{body}, 'http_post', 'HTTP POST works';

    # Test WebSocket
    ($send, $sent) = mock_send();
    $app->({ type => 'websocket', path => '/ws/echo' }, sub { Future->done }, $send)->get;
    is $sent->[1]{body}, 'ws_echo', 'WebSocket works';

    # Test SSE
    ($send, $sent) = mock_send();
    $app->({ type => 'sse', path => '/events' }, sub { Future->done }, $send)->get;
    is $sent->[1]{body}, 'sse_events', 'SSE works';

    # Test 404 for unmatched websocket path
    ($send, $sent) = mock_send();
    $app->({ type => 'websocket', path => '/ws/unknown' }, sub { Future->done }, $send)->get;
    is $sent->[0]{status}, 404, 'unmatched websocket returns 404';

    # Test lifespan is ignored
    ($send, $sent) = mock_send();
    $app->({ type => 'lifespan', path => '/' }, sub { Future->done }, $send)->get;
    is scalar(@$sent), 0, 'lifespan events are ignored';
};

subtest 'regex metacharacters in literal paths' => sub {
    my @calls;
    my $router = PAGI::App::Router->new;
    $router->get('/api/v1.0/users' => make_handler('v1_users', \@calls));
    $router->get('/files/report[2024]' => make_handler('report', \@calls));
    $router->get('/search' => make_handler('search', \@calls));

    my $app = $router->to_app;

    # Dot in path should match literally, not as regex "any char"
    my ($send, $sent) = mock_send();
    $app->({ method => 'GET', path => '/api/v1.0/users' }, sub { Future->done }, $send)->get;
    is $sent->[0]{status}, 200, 'literal dot in path matches';
    is $sent->[1]{body}, 'v1_users', 'correct handler for dotted path';

    # /api/v1X0/users should NOT match (dot is not "any char")
    ($send, $sent) = mock_send();
    $app->({ method => 'GET', path => '/api/v1X0/users' }, sub { Future->done }, $send)->get;
    is $sent->[0]{status}, 404, 'dot does not match arbitrary char';

    # Brackets in path should match literally
    ($send, $sent) = mock_send();
    $app->({ method => 'GET', path => '/files/report[2024]' }, sub { Future->done }, $send)->get;
    is $sent->[0]{status}, 200, 'literal brackets in path match';
    is $sent->[1]{body}, 'report', 'correct handler for bracketed path';
};

subtest 'path parameter syntax variants' => sub {
    my @calls;
    my $router = PAGI::App::Router->new;
    $router->get('/users/{id}' => make_handler('brace_user', \@calls));
    $router->get('/items/:item_id/reviews/:review_id' => make_handler('review', \@calls));

    my $app = $router->to_app;

    # {name} syntax (brace-style, unconstrained)
    my ($send, $sent) = mock_send();
    $app->({ method => 'GET', path => '/users/99' }, sub { Future->done }, $send)->get;
    is $sent->[0]{status}, 200, '{id} syntax matched';
    is $calls[0]{scope}{path_params}{id}, '99', '{id} captured param';

    # Multiple params with colon syntax
    @calls = ();
    ($send, $sent) = mock_send();
    $app->({ method => 'GET', path => '/items/5/reviews/10' }, sub { Future->done }, $send)->get;
    is $sent->[0]{status}, 200, 'multiple params matched';
    is $calls[0]{scope}{path_params}{item_id}, '5', 'first param captured';
    is $calls[0]{scope}{path_params}{review_id}, '10', 'second param captured';
};

done_testing;
