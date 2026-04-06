use strict;
use warnings;

use Test2::V0;
use Future::AsyncAwait;
use Future;

use PAGI::App::Router;

subtest 'empty router returns empty route table' => sub {
    my $router = PAGI::App::Router->new;
    my $table = $router->route_table;

    is ref($table), 'ARRAY', 'route_table returns arrayref';
    is scalar @$table, 0, 'empty router has no routes';
};

subtest 'HTTP routes appear with correct fields' => sub {
    my $router = PAGI::App::Router->new;
    $router->get('/users' => sub { Future->done });
    $router->post('/users' => sub { Future->done })->name('create_user');
    $router->get('/users/:id' => sub { Future->done })->name('get_user');

    my $table = $router->route_table;

    is scalar @$table, 3, 'three routes in table';

    # GET /users
    is $table->[0]{type}, 'http', 'type is http';
    is $table->[0]{method}, 'GET', 'method is GET';
    is $table->[0]{path}, '/users', 'path is /users';
    is $table->[0]{name}, undef, 'unnamed route has undef name';
    is $table->[0]{params}, [], 'no params';
    is $table->[0]{constraints}, {}, 'no constraints';
    is $table->[0]{middleware}, 0, 'no middleware';

    # POST /users (named)
    is $table->[1]{type}, 'http', 'type is http';
    is $table->[1]{method}, 'POST', 'method is POST';
    is $table->[1]{name}, 'create_user', 'name is create_user';

    # GET /users/:id (named, with param)
    is $table->[2]{type}, 'http', 'type is http';
    is $table->[2]{method}, 'GET', 'method is GET';
    is $table->[2]{path}, '/users/:id', 'path preserves :id syntax';
    is $table->[2]{name}, 'get_user', 'name is get_user';
    is $table->[2]{params}, ['id'], 'params contains id';
};

subtest 'constraints appear in route table entries' => sub {
    my $router = PAGI::App::Router->new;

    # Inline constraint
    $router->get('/items/{id:\\d+}' => sub { Future->done });

    # Chained constraint
    $router->get('/posts/:slug' => sub { Future->done })
        ->constraints(slug => qr/^[a-z0-9-]+$/);

    my $table = $router->route_table;

    is scalar @$table, 2, 'two routes';

    # Inline constraint: {id:\d+}
    ok exists $table->[0]{constraints}{id}, 'inline constraint for id exists';
    like '42', $table->[0]{constraints}{id}, 'inline constraint matches digits';

    # Chained constraint
    ok exists $table->[1]{constraints}{slug}, 'chained constraint for slug exists';
    like 'hello-world', $table->[1]{constraints}{slug}, 'chained constraint matches slug';
    unlike 'Hello World', $table->[1]{constraints}{slug}, 'chained constraint rejects bad slug';
};

subtest 'middleware count is accurate' => sub {
    my $router = PAGI::App::Router->new;

    my $mw1 = async sub { my ($scope, $receive, $send, $next) = @_; await $next->() };
    my $mw2 = async sub { my ($scope, $receive, $send, $next) = @_; await $next->() };

    $router->get('/no-mw' => sub { Future->done });
    $router->get('/one-mw' => [$mw1] => sub { Future->done });
    $router->get('/two-mw' => [$mw1, $mw2] => sub { Future->done });

    my $table = $router->route_table;

    is $table->[0]{middleware}, 0, 'no middleware';
    is $table->[1]{middleware}, 1, 'one middleware';
    is $table->[2]{middleware}, 2, 'two middleware';
};

subtest 'WebSocket and SSE routes appear in route table' => sub {
    my $router = PAGI::App::Router->new;
    $router->websocket('/ws/chat/:room' => sub { Future->done })->name('chat');
    $router->sse('/events' => sub { Future->done });

    my $table = $router->route_table;

    is scalar @$table, 2, 'two routes';

    is $table->[0]{type}, 'websocket', 'type is websocket';
    is $table->[0]{path}, '/ws/chat/:room', 'websocket path correct';
    is $table->[0]{name}, 'chat', 'websocket name correct';
    is $table->[0]{params}, ['room'], 'websocket params correct';
    ok !exists $table->[0]{method}, 'websocket has no method key';

    is $table->[1]{type}, 'sse', 'type is sse';
    is $table->[1]{path}, '/events', 'sse path correct';
    is $table->[1]{name}, undef, 'unnamed sse route';
    ok !exists $table->[1]{method}, 'sse has no method key';
};

subtest 'mounts appear in route table' => sub {
    my $router = PAGI::App::Router->new;
    my $sub_app = sub { Future->done };
    my $mw = async sub { my ($scope, $receive, $send, $next) = @_; await $next->() };

    $router->get('/top' => sub { Future->done });
    $router->mount('/api' => $sub_app);
    $router->mount('/admin' => [$mw] => $sub_app);

    my $table = $router->route_table;

    is scalar @$table, 3, 'three entries (1 route + 2 mounts)';

    # HTTP route first
    is $table->[0]{type}, 'http', 'first entry is http';

    # Mounts after
    is $table->[1]{type}, 'mount', 'second entry is mount';
    is $table->[1]{path}, '/api', 'mount path is /api';
    is $table->[1]{name}, undef, 'mount has no name';
    is $table->[1]{params}, [], 'mount has no params';
    is $table->[1]{constraints}, {}, 'mount has no constraints';
    is $table->[1]{middleware}, 0, 'first mount has no middleware';
    ok !exists $table->[1]{method}, 'mount has no method key';

    is $table->[2]{type}, 'mount', 'third entry is mount';
    is $table->[2]{path}, '/admin', 'mount path is /admin';
    is $table->[2]{middleware}, 1, 'second mount has one middleware';
};

subtest 'route table ordering: http, websocket, sse, mount' => sub {
    my $router = PAGI::App::Router->new;

    # Register in mixed order
    $router->mount('/mounted' => sub { Future->done });
    $router->sse('/events' => sub { Future->done });
    $router->get('/page' => sub { Future->done });
    $router->websocket('/ws' => sub { Future->done });
    $router->post('/data' => sub { Future->done });

    my $table = $router->route_table;

    is scalar @$table, 5, 'five entries';

    # HTTP first (registration order within type)
    is $table->[0]{type}, 'http', 'first is http (GET /page)';
    is $table->[0]{path}, '/page', 'GET /page';
    is $table->[1]{type}, 'http', 'second is http (POST /data)';
    is $table->[1]{path}, '/data', 'POST /data';

    # Then websocket
    is $table->[2]{type}, 'websocket', 'third is websocket';

    # Then SSE
    is $table->[3]{type}, 'sse', 'fourth is sse';

    # Then mounts
    is $table->[4]{type}, 'mount', 'fifth is mount';
};

done_testing;
