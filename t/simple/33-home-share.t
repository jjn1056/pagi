use strict;
use warnings;
use experimental 'signatures';
use Test2::V0;
use File::Basename qw(dirname);
use File::Spec;

# Test: $app->home, $app->share_dir, $app->share

use PAGI::Simple;

# Test 1: home() returns caller directory
subtest 'home returns caller directory' => sub {
    my $app = PAGI::Simple->new(name => 'Test App');

    my $home = $app->home;
    ok($home, 'home() returns a value');
    ok(-d $home, 'home() returns an existing directory');

    # Should be the directory containing this test file
    my $expected = dirname(File::Spec->rel2abs(__FILE__));
    is($home, $expected, 'home() returns correct directory');
};

# Test 2: home() is a string
subtest 'home is a string' => sub {
    my $app = PAGI::Simple->new(name => 'Test App');

    my $home = $app->home;
    ok(!ref($home), 'home() returns a plain string');
    like($home, qr{/}, 'home() looks like a path');
};

# Test 3: share_dir() finds htmx in development
subtest 'share_dir finds htmx' => sub {
    my $app = PAGI::Simple->new(name => 'Test App');

    my $htmx_dir = $app->share_dir('htmx');
    ok($htmx_dir, 'share_dir(htmx) returns a value');
    ok(-d $htmx_dir, 'share_dir(htmx) returns an existing directory');

    # Should contain htmx.min.js
    my $htmx_file = File::Spec->catfile($htmx_dir, 'htmx.min.js');
    ok(-f $htmx_file, 'htmx.min.js exists in share_dir');

    # Should contain extensions
    my $sse_file = File::Spec->catfile($htmx_dir, 'ext', 'sse.js');
    ok(-f $sse_file, 'ext/sse.js exists in share_dir');
};

# Test 4: share_dir() dies for nonexistent assets
subtest 'share_dir dies for nonexistent' => sub {
    my $app = PAGI::Simple->new(name => 'Test App');

    my $error;
    eval { $app->share_dir('nonexistent-asset') };
    $error = $@;

    ok($error, 'share_dir dies for nonexistent asset');
    like($error, qr/not found|Can't locate/i, 'error message is informative');
};

# Test 5: share() mounts static files
subtest 'share mounts static files' => sub {
    my $app = PAGI::Simple->new(name => 'Test App');

    # share() should return $app for chaining
    my $result = $app->share('htmx');
    is($result, $app, 'share() returns $app for chaining');

    # Verify static handler was added (internal check)
    ok(scalar @{$app->{_static_handlers}} > 0, 'static handler was added');

    # Verify has_shared() returns true
    ok($app->has_shared('htmx'), 'has_shared(htmx) returns true after share()');
};

# Test 6: share() chaining
subtest 'share chaining' => sub {
    my $app = PAGI::Simple->new(name => 'Test App');

    # share() should return $app for chaining
    my $result = $app->share('htmx');
    is($result, $app, 'share returns $app');

    # Can chain with other methods
    my $result2 = $app->share('htmx')->get('/' => sub { });
    isa_ok($result2, ['PAGI::Simple::RouteHandle'], 'chained get() returns RouteHandle');
};

# Test 6b: share() dies for unknown asset
subtest 'share dies for unknown asset' => sub {
    my $app = PAGI::Simple->new(name => 'Test App');

    my $error;
    eval { $app->share('nonexistent') };
    $error = $@;

    ok($error, 'share() dies for unknown asset');
    like($error, qr/Unknown shared asset 'nonexistent'/, 'error mentions asset name');
    like($error, qr/Available:.*htmx/, 'error lists available assets');
};

# Test 6c: has_shared() returns false before share()
subtest 'has_shared returns false before share' => sub {
    my $app = PAGI::Simple->new(name => 'Test App');

    ok(!$app->has_shared('htmx'), 'has_shared(htmx) returns false before share()');
    ok(!$app->has_shared('nonexistent'), 'has_shared() returns false for unknown asset');
};

# Test 7: share_dir returns absolute path
subtest 'share_dir returns absolute path' => sub {
    my $app = PAGI::Simple->new(name => 'Test App');

    my $htmx_dir = $app->share_dir('htmx');

    # Should be absolute (starts with /)
    like($htmx_dir, qr{^/}, 'share_dir returns absolute path');

    # Should not contain .. or .
    unlike($htmx_dir, qr{/\.\./}, 'share_dir has no .. components');
};

# Test 8: home() from different caller
subtest 'home from subpackage' => sub {
    # Create app in a nested context to test caller detection
    my $app;
    {
        package TestSubPackage;
        $app = PAGI::Simple->new(name => 'Nested App');
    }

    my $home = $app->home;
    ok($home, 'home() works from nested package');
    ok(-d $home, 'home() returns existing directory');
};

done_testing;
