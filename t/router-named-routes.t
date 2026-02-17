use strict;
use warnings;
use Test2::V0;

use PAGI::App::Router;

subtest 'basic named routes' => sub {
    my $router = PAGI::App::Router->new;

    my $handler = sub { };

    $router->get('/users' => $handler)->name('users.list');
    $router->get('/users/:id' => $handler)->name('users.get');
    $router->post('/users' => $handler)->name('users.create');

    # Check named routes exist
    my $routes = $router->named_routes;
    ok exists $routes->{'users.list'}, 'users.list exists';
    ok exists $routes->{'users.get'}, 'users.get exists';
    ok exists $routes->{'users.create'}, 'users.create exists';

    # Basic uri_for
    is $router->uri_for('users.list'), '/users', 'uri_for users.list';
    is $router->uri_for('users.get', { id => 42 }), '/users/42', 'uri_for users.get with id';
    is $router->uri_for('users.create'), '/users', 'uri_for users.create';
};

subtest 'uri_for with query params' => sub {
    my $router = PAGI::App::Router->new;

    $router->get('/users' => sub {})->name('users.list');
    $router->get('/users/:id' => sub {})->name('users.get');

    # Query params only
    is $router->uri_for('users.list', {}, { page => 2, limit => 10 }),
        '/users?limit=10&page=2',
        'query params sorted alphabetically';

    # Path and query params
    is $router->uri_for('users.get', { id => 5 }, { format => 'json' }),
        '/users/5?format=json',
        'path and query params';
};

subtest 'uri_for with special characters' => sub {
    my $router = PAGI::App::Router->new;

    $router->get('/search' => sub {})->name('search');

    is $router->uri_for('search', {}, { q => 'hello world' }),
        '/search?q=hello%20world',
        'space encoded';

    is $router->uri_for('search', {}, { q => 'foo&bar' }),
        '/search?q=foo%26bar',
        'ampersand encoded';
};

subtest 'uri_for errors' => sub {
    my $router = PAGI::App::Router->new;

    $router->get('/users/:id' => sub {})->name('users.get');

    # Unknown route
    like dies { $router->uri_for('unknown.route') },
        qr/Unknown route name/,
        'croak on unknown route';

    # Missing required param
    like dies { $router->uri_for('users.get', {}) },
        qr/Missing required path parameter 'id'/,
        'croak on missing path param';
};

subtest 'name() errors' => sub {
    my $router = PAGI::App::Router->new;

    # name() without route
    like dies { $router->name('foo') },
        qr/name\(\) called without a preceding route/,
        'croak when no route to name';

    # Empty name
    $router->get('/test' => sub {});
    like dies { $router->name('') },
        qr/Route name required/,
        'croak on empty name';
};

subtest 'websocket and sse named routes' => sub {
    my $router = PAGI::App::Router->new;

    $router->websocket('/ws/:room' => sub {})->name('ws.room');
    $router->sse('/events/:channel' => sub {})->name('sse.channel');

    is $router->uri_for('ws.room', { room => 'general' }),
        '/ws/general',
        'websocket route uri_for';

    is $router->uri_for('sse.channel', { channel => 'news' }),
        '/events/news',
        'sse route uri_for';
};

subtest 'mounted routers with namespace' => sub {
    my $api = PAGI::App::Router->new;
    $api->get('/users' => sub {})->name('users.list');
    $api->get('/users/:id' => sub {})->name('users.get');

    my $main = PAGI::App::Router->new;
    $main->get('/' => sub {})->name('home');
    $main->mount('/api/v1' => $api)->as('api');

    # Main routes
    is $main->uri_for('home'), '/', 'main route works';

    # Namespaced routes include mount prefix
    is $main->uri_for('api.users.list'), '/api/v1/users', 'mounted route with prefix';
    is $main->uri_for('api.users.get', { id => 42 }), '/api/v1/users/42', 'mounted route with param';
};

subtest 'nested mounts' => sub {
    my $users = PAGI::App::Router->new;
    $users->get('/' => sub {})->name('list');
    $users->get('/:id' => sub {})->name('get');

    my $api = PAGI::App::Router->new;
    $api->mount('/users' => $users)->as('users');

    my $main = PAGI::App::Router->new;
    $main->mount('/api' => $api)->as('api');

    is $main->uri_for('api.users.list'), '/api/users/', 'nested mount list';
    is $main->uri_for('api.users.get', { id => 1 }), '/api/users/1', 'nested mount with param';
};

subtest 'as() errors' => sub {
    my $router = PAGI::App::Router->new;

    # as() without mount
    like dies { $router->as('foo') },
        qr/as\(\) called without a preceding mount/,
        'croak when no mount';

    # as() with app coderef (not router)
    $router->mount('/api' => sub {});
    like dies { $router->as('api') },
        qr/as\(\) requires mounting a router object/,
        'croak when mounting coderef';
};

subtest 'wildcard routes' => sub {
    my $router = PAGI::App::Router->new;

    $router->get('/files/*path' => sub {})->name('files');

    is $router->uri_for('files', { path => 'docs/readme.txt' }),
        '/files/docs/readme.txt',
        'wildcard param substituted';
};

subtest 'any() route with name' => sub {
    my $router = PAGI::App::Router->new;

    $router->any('/health' => sub {})->name('health');
    $router->any('/items/{id:\d+}' => sub {}, method => ['GET', 'PUT'])->name('items.detail');

    is $router->uri_for('health'), '/health', 'any() route uri_for works';
    is $router->uri_for('items.detail', { id => 5 }), '/items/5', 'any() with constraint uri_for works';
};

subtest 'uri_for with brace syntax' => sub {
    my $router = PAGI::App::Router->new;

    $router->get('/users/{id}' => sub {})->name('users.get');
    $router->get('/posts/{slug:[a-z0-9-]+}' => sub {})->name('posts.get');

    is $router->uri_for('users.get', { id => 42 }), '/users/42', 'uri_for with {name} syntax';
    is $router->uri_for('posts.get', { slug => 'hello-world' }), '/posts/hello-world', 'uri_for with {name:pattern} syntax';
};

done_testing;
