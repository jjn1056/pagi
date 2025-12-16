#!/usr/bin/env perl
use strict;
use warnings;
use experimental 'signatures';
use Test2::V0;

use lib 'lib';
use PAGI::Simple;

# Create test sub-app classes inline

{
    package TestApp::Todos;
    use parent 'PAGI::Simple';
    use experimental 'signatures';

    sub new ($class) {
        my $self = $class->SUPER::new(name => 'Todos', quiet => 1);
        $self->get('/' => sub ($c) { $c->text('todos index') });
        return $self;
    }

    $INC{'TestApp/Todos.pm'} = 1;  # Pretend it's loaded
}

{
    package TestApp::Users;
    use parent 'PAGI::Simple';
    use experimental 'signatures';

    sub new ($class) {
        my $self = $class->SUPER::new(name => 'Users', quiet => 1);
        $self->get('/' => sub ($c) { $c->text('users index') });
        return $self;
    }

    $INC{'TestApp/Users.pm'} = 1;
}

{
    package FullyQualified::API;
    use parent 'PAGI::Simple';
    use experimental 'signatures';

    sub new ($class) {
        my $self = $class->SUPER::new(name => 'API', quiet => 1);
        $self->get('/status' => sub ($c) { $c->json({ ok => 1 }) });
        return $self;
    }

    $INC{'FullyQualified/API.pm'} = 1;
}

# Test 1: Mount by full class name
subtest 'mount by full class name' => sub {
    my $app = PAGI::Simple->new(name => 'Main', quiet => 1);

    # Should not die
    ok(lives { $app->mount('/api' => 'FullyQualified::API') },
        'mount by full class name succeeds');

    # Check it's in the mounted apps list
    is(scalar @{$app->{_mounted_apps}}, 1, 'one app mounted');
    is($app->{_mounted_apps}[0]{prefix}, '/api', 'correct prefix');
};

# Define TestApp as a proper subclass
{
    package TestApp;
    use parent 'PAGI::Simple';
}

# Test 2: Mount by relative class name (::SubApp syntax)
subtest 'mount by relative class name' => sub {
    # Create app in TestApp namespace (so ref($self) = 'TestApp')
    my $app = TestApp->new(name => 'TestApp', quiet => 1);

    ok(lives { $app->mount('/todos' => '::Todos') },
        'mount by relative class name succeeds');

    ok(lives { $app->mount('/users' => '::Users') },
        'mount second relative class succeeds');

    is(scalar @{$app->{_mounted_apps}}, 2, 'two apps mounted');
    is($app->{_mounted_apps}[0]{prefix}, '/todos', 'first prefix correct');
    is($app->{_mounted_apps}[1]{prefix}, '/users', 'second prefix correct');
};

# Test 3: Mount with middleware (string class)
subtest 'mount string class with middleware' => sub {
    my $app = PAGI::Simple->new(name => 'Main', quiet => 1);

    ok(lives { $app->mount('/api' => 'FullyQualified::API', ['some_middleware']) },
        'mount with middleware succeeds');

    is($app->{_mounted_apps}[0]{middleware}, ['some_middleware'],
        'middleware stored correctly');
};

# Test 4: Error - class not found
subtest 'error on class not found' => sub {
    my $app = PAGI::Simple->new(name => 'Main', quiet => 1);

    like(
        dies { $app->mount('/bad' => 'NonExistent::Module') },
        qr/Can't load NonExistent::Module/,
        'dies with clear error when class not found'
    );
};

# Test 5: Error - class has no new()
subtest 'error on class without new()' => sub {
    {
        package NoNewMethod;
        # Intentionally no new() method
        $INC{'NoNewMethod.pm'} = 1;
    }

    my $app = PAGI::Simple->new(name => 'Main', quiet => 1);

    like(
        dies { $app->mount('/bad' => 'NoNewMethod') },
        qr/has no new\(\) method/,
        'dies with clear error when class has no new()'
    );
};

# Test 6: Existing behaviors still work (object, coderef)
subtest 'existing mount behaviors preserved' => sub {
    my $app = PAGI::Simple->new(name => 'Main', quiet => 1);

    # Mount an object
    my $sub_app = PAGI::Simple->new(name => 'Sub', quiet => 1);
    ok(lives { $app->mount('/sub' => $sub_app) },
        'mount object still works');

    # Mount a coderef
    my $coderef = sub { };
    ok(lives { $app->mount('/code' => $coderef) },
        'mount coderef still works');

    is(scalar @{$app->{_mounted_apps}}, 2, 'both mounted');
};

done_testing;
