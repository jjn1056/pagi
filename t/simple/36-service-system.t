#!/usr/bin/env perl
use strict;
use warnings;
use experimental 'signatures';
use Test2::V0;
use Future;
use Future::AsyncAwait;
use File::Temp qw(tempdir);
use File::Path qw(make_path);

# =============================================================================
# PAGI::Simple Service System Tests
# =============================================================================

# Create temp service directory
my $tmpdir = tempdir(CLEANUP => 1);
my $service_dir = "$tmpdir/lib/TestApp/Service";
make_path($service_dir);

# Create test service class (Factory scope - new instance each call)
my $todo_service = q{
package TestApp::Service::Todo;
use strict;
use warnings;
use experimental 'signatures';
use parent 'PAGI::Simple::Service::Factory';

# In-memory storage
my @todos = (
    { id => 1, title => 'First task', done => 0 },
    { id => 2, title => 'Second task', done => 1 },
);
my $next_id = 3;

sub all ($self) {
    return @todos;
}

sub find ($self, $id) {
    my ($todo) = grep { $_->{id} == $id } @todos;
    return $todo;
}

sub create ($self, $title) {
    my $todo = { id => $next_id++, title => $title, done => 0 };
    push @todos, $todo;
    return $todo;
}

1;
};

# Create service with PerRequest scope (cached per request)
my $user_service = q{
package TestApp::Service::CurrentUser;
use strict;
use warnings;
use experimental 'signatures';
use parent 'PAGI::Simple::Service::PerRequest';

my $instance_count = 0;

# Track instance creation in new
sub new ($class, %args) {
    $instance_count++;
    my $self = $class->SUPER::new(%args);
    $self->{instance_num} = $instance_count;
    return $self;
}

sub instance_num ($self) { $self->{instance_num} }

package TestApp::Service::CurrentUser;
sub reset_instance_count { $instance_count = 0; }

1;
};

# Create service with PerApp scope (singleton)
my $db_service = q{
package TestApp::Service::DB;
use strict;
use warnings;
use experimental 'signatures';
use parent 'PAGI::Simple::Service::PerApp';

sub dsn ($self) { $self->{dsn} }
sub username ($self) { $self->{username} }

1;
};

# Write service files
{
    open my $fh, '>', "$service_dir/Todo.pm" or die "Cannot write Todo.pm: $!";
    print $fh $todo_service;
    close $fh;

    open $fh, '>', "$service_dir/CurrentUser.pm" or die "Cannot write CurrentUser.pm: $!";
    print $fh $user_service;
    close $fh;

    open $fh, '>', "$service_dir/DB.pm" or die "Cannot write DB.pm: $!";
    print $fh $db_service;
    close $fh;
}

# Add temp lib to @INC
unshift @INC, "$tmpdir/lib";

use PAGI::Simple;

# =============================================================================
# Helper to simulate a PAGI HTTP request (same pattern as other tests)
# =============================================================================
sub simulate_request ($app, %opts) {
    my $method = $opts{method} // 'GET';
    my $path   = $opts{path} // '/';
    my $query  = $opts{query_string} // '';
    my $headers = $opts{headers} // [];
    my $body   = $opts{body} // '';

    my @sent;
    my $scope = {
        type         => 'http',
        method       => $method,
        path         => $path,
        query_string => $query,
        headers      => $headers,
    };

    # Provide body if given
    my $body_bytes = $body;
    my $body_provided = 0;
    my $receive = sub {
        if (!$body_provided && length($body_bytes)) {
            $body_provided = 1;
            return Future->done({
                type => 'http.request',
                body => $body_bytes,
                more => 0,
            });
        }
        return Future->done({ type => 'http.request' });
    };

    my $send = sub ($event) {
        push @sent, $event;
        return Future->done;
    };

    my $pagi_app = $app->to_app;
    $pagi_app->($scope, $receive, $send)->get;

    return \@sent;
}

# Helper to initialize services (mimics lifespan.startup)
sub init_app_services ($app) {
    $app->_init_services();
}

# Helper to get response body
sub get_body ($sent) {
    my @bodies = map { $_->{body} // '' } grep { $_->{type} eq 'http.response.body' } @$sent;
    return join('', @bodies);
}

# Helper to get response status
sub get_status ($sent) {
    my ($start) = grep { $_->{type} eq 'http.response.start' } @$sent;
    return $start ? $start->{status} : undef;
}

# =============================================================================
# Test 1: Service auto-discovery and instantiation
# =============================================================================
subtest 'Service auto-discovery' => sub {
    my $app = PAGI::Simple->new(
        name => 'Service Test',
        namespace => 'TestApp',
        lib => "$tmpdir/lib",
    );

    # Init services (mimics lifespan.startup)
    init_app_services($app);

    $app->get('/todos' => sub ($c) {
        my $todos = $c->service('Todo');
        ok($todos, 'Service instantiated');
        isa_ok($todos, ['TestApp::Service::Todo'], 'Correct service class');

        my @all = $todos->all;
        is(scalar(@all), 2, 'Got todos from service');
        $c->json(\@all);
    });

    my $sent = simulate_request($app, path => '/todos');
    is(get_status($sent), 200, 'Status 200');
    like(get_body($sent), qr/First task/, 'Got todo data');
};

# =============================================================================
# Test 2: Service has access to context (Factory scope)
# =============================================================================
subtest 'Service has access to context' => sub {
    my $app = PAGI::Simple->new(
        name => 'Service Context Test',
        namespace => 'TestApp',
        lib => "$tmpdir/lib",
    );
    init_app_services($app);

    $app->get('/check-context' => sub ($c) {
        my $todos = $c->service('Todo');
        my $ctx = $todos->c;

        ok($ctx, 'Service has context');
        isa_ok($ctx, ['PAGI::Simple::Context'], 'Context is correct class');
        is($ctx->path, '/check-context', 'Context has correct path');

        $c->text('OK');
    });

    my $sent = simulate_request($app, path => '/check-context');
    is(get_status($sent), 200, 'Status 200');
    is(get_body($sent), 'OK', 'Response OK');
};

# =============================================================================
# Test 3: Factory pattern (new instance each call)
# =============================================================================
subtest 'Factory pattern creates new instances' => sub {
    my $app = PAGI::Simple->new(
        name => 'Factory Test',
        namespace => 'TestApp',
        lib => "$tmpdir/lib",
    );
    init_app_services($app);

    $app->get('/factory-test' => sub ($c) {
        my $s1 = $c->service('Todo');
        my $s2 = $c->service('Todo');

        # They should be different instances
        my $same = ($s1 eq $s2) ? 'same' : 'different';
        $c->text($same);
    });

    my $sent = simulate_request($app, path => '/factory-test');
    is(get_status($sent), 200, 'Status 200');
    is(get_body($sent), 'different', 'Factory creates new instances each call');
};

# =============================================================================
# Test 4: PerRequest caches instance within request
# =============================================================================
subtest 'PerRequest caches within request' => sub {
    require TestApp::Service::CurrentUser;
    TestApp::Service::CurrentUser->reset_instance_count;

    my $app = PAGI::Simple->new(
        name => 'PerRequest Test',
        namespace => 'TestApp',
        lib => "$tmpdir/lib",
    );
    init_app_services($app);

    $app->get('/per-request-test' => sub ($c) {
        my $u1 = $c->service('CurrentUser');
        my $u2 = $c->service('CurrentUser');
        my $u3 = $c->service('CurrentUser');

        # All should be same instance
        my $same = ($u1 eq $u2 && $u2 eq $u3) ? 'same' : 'different';
        my $num = $u1->instance_num;
        $c->text("$same:$num");
    });

    my $sent = simulate_request($app, path => '/per-request-test');
    is(get_status($sent), 200, 'Status 200');
    is(get_body($sent), 'same:1', 'PerRequest caches instance (same instance, created once)');
};

# =============================================================================
# Test 5: PerApp singleton across requests
# =============================================================================
subtest 'PerApp singleton' => sub {
    my $app = PAGI::Simple->new(
        name => 'PerApp Test',
        namespace => 'TestApp',
        lib => "$tmpdir/lib",
        service_config => {
            DB => { dsn => 'dbi:SQLite:test.db', username => 'admin' },
        },
    );
    init_app_services($app);

    $app->get('/db-config' => sub ($c) {
        my $db = $c->service('DB');
        my $dsn = $db->dsn;
        my $user = $db->username;
        $c->text("$dsn:$user");
    });

    my $sent = simulate_request($app, path => '/db-config');
    is(get_status($sent), 200, 'Status 200');
    is(get_body($sent), 'dbi:SQLite:test.db:admin', 'PerApp config passed and singleton works');
};

# =============================================================================
# Test 6: Error on unknown service
# =============================================================================
subtest 'Error on unknown service' => sub {
    my $app = PAGI::Simple->new(
        name => 'Error Test',
        namespace => 'TestApp',
        lib => "$tmpdir/lib",
    );
    init_app_services($app);

    $app->get('/unknown' => sub ($c) {
        eval { $c->service('NonExistent') };
        if ($@) {
            $c->text('error');
        } else {
            $c->text('no-error');
        }
    });

    my $sent = simulate_request($app, path => '/unknown');
    is(get_status($sent), 200, 'Status 200');
    is(get_body($sent), 'error', 'Error thrown for unknown service');
};

# =============================================================================
# Test 7: Manual service registration with add_service
# =============================================================================
subtest 'Manual service registration' => sub {
    my $app = PAGI::Simple->new(
        name => 'Manual Test',
        namespace => 'TestApp',
        lib => "$tmpdir/lib",
    );

    # Manually register a service with a factory
    $app->add_service('CustomCache', sub ($app) {
        # Return a simple object
        return bless { data => {} }, 'CustomCache';
    });

    init_app_services($app);

    $app->get('/custom' => sub ($c) {
        my $cache = $c->service('CustomCache');
        $c->text(ref($cache));
    });

    my $sent = simulate_request($app, path => '/custom');
    is(get_status($sent), 200, 'Status 200');
    is(get_body($sent), 'CustomCache', 'Manual service registration works');
};

# =============================================================================
# Test 8: Service methods work correctly
# =============================================================================
subtest 'Service methods work correctly' => sub {
    my $app = PAGI::Simple->new(
        name => 'Methods Test',
        namespace => 'TestApp',
        lib => "$tmpdir/lib",
    );
    init_app_services($app);

    $app->get('/todos/:id' => sub ($c) {
        my $id = $c->path_params->{id};
        my $todos = $c->service('Todo');
        my $todo = $todos->find($id);

        if ($todo) {
            $c->json($todo);
        } else {
            $c->status(404)->text('Not found');
        }
    });

    # Find existing
    my $sent1 = simulate_request($app, path => '/todos/1');
    is(get_status($sent1), 200, 'Find status 200');
    like(get_body($sent1), qr/First task/, 'Found first task');

    # Find non-existing
    my $sent2 = simulate_request($app, path => '/todos/999');
    is(get_status($sent2), 404, 'Not found status 404');
};

done_testing;
