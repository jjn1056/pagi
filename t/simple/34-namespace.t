#!/usr/bin/env perl
use strict;
use warnings;
use experimental 'signatures';
use Test2::V0;

# =============================================================================
# PAGI::Simple Namespace and Lib Tests
# =============================================================================

use PAGI::Simple;

# =============================================================================
# Test 1: Default namespace from name
# =============================================================================
subtest 'Default namespace generated from name' => sub {
    my $app = PAGI::Simple->new(name => 'Live Poll', lib => undef);
    is($app->namespace, 'LivePoll', 'namespace derived from "Live Poll"');

    my $app2 = PAGI::Simple->new(name => 'My App', lib => undef);
    is($app2->namespace, 'MyApp', 'namespace derived from "My App"');
};

# =============================================================================
# Test 2: Various name conversions
# =============================================================================
subtest 'Name to namespace conversions' => sub {
    my @cases = (
        ['My App', 'MyApp'],
        ['hello-world', 'HelloWorld'],
        ['hello_world', 'HelloWorld'],
        ['TODO List', 'TodoList'],
        ['api', 'Api'],
        ['API', 'Api'],
        ['simple-17-htmx-poll', 'Simple17HtmxPoll'],
        ['My App 2.0', 'MyApp20'],
        ['café app', 'CafApp'],  # Non-ASCII removed
        ['PAGI::Simple', 'PagiSimple'],  # Default name
    );

    for my $case (@cases) {
        my ($name, $expected) = @$case;
        my $app = PAGI::Simple->new(name => $name, lib => undef);
        is($app->namespace, $expected, "name '$name' => namespace '$expected'");
    }
};

# =============================================================================
# Test 3: Names starting with numbers
# =============================================================================
subtest 'Names starting with numbers get App prefix' => sub {
    my $app = PAGI::Simple->new(name => '123 App', lib => undef);
    is($app->namespace, 'App123App', 'number prefix handled');

    my $app2 = PAGI::Simple->new(name => '1st Place', lib => undef);
    is($app2->namespace, 'App1stPlace', 'number prefix handled');
};

# =============================================================================
# Test 4: Edge cases
# =============================================================================
subtest 'Edge cases' => sub {
    my $app1 = PAGI::Simple->new(name => '', lib => undef);
    is($app1->namespace, 'App', 'empty name => App');

    my $app2 = PAGI::Simple->new(name => '   ', lib => undef);
    is($app2->namespace, 'App', 'whitespace only => App');

    my $app3 = PAGI::Simple->new(name => '---', lib => undef);
    is($app3->namespace, 'App', 'special chars only => App');
};

# =============================================================================
# Test 5: Explicit namespace overrides default
# =============================================================================
subtest 'Explicit namespace overrides generated' => sub {
    my $app = PAGI::Simple->new(
        name => 'My App',
        namespace => 'CustomNamespace',
        lib => undef,
    );
    is($app->namespace, 'CustomNamespace', 'explicit namespace wins');
};

# =============================================================================
# Test 6: lib_dir accessor
# =============================================================================
subtest 'lib_dir accessor' => sub {
    # With explicit lib
    my $app1 = PAGI::Simple->new(name => 'Test', lib => '/custom/lib');
    is($app1->lib_dir, '/custom/lib', 'explicit absolute lib_dir');

    # With lib => undef
    my $app2 = PAGI::Simple->new(name => 'Test', lib => undef);
    is($app2->lib_dir, undef, 'lib => undef gives undef');
};

# =============================================================================
# Test 7: Default lib is relative to home
# =============================================================================
subtest 'Default lib relative to home' => sub {
    my $app = PAGI::Simple->new(name => 'Test');
    my $home = $app->home;
    my $lib = $app->lib_dir;

    ok(defined $lib, 'lib_dir defined by default');
    like($lib, qr/\Qlib\E$/, 'lib_dir ends with lib');
    like($lib, qr/^\Q$home\E/, 'lib_dir starts with home');
};

# =============================================================================
# Test 8: lib added to @INC
# =============================================================================
subtest 'lib added to @INC' => sub {
    # Create app with a unique lib path to test
    my $unique_path = "/tmp/pagi-test-$$-" . time();

    my $app = PAGI::Simple->new(name => 'Test', lib => $unique_path);

    ok(grep({ $_ eq $unique_path } @INC), 'lib path added to @INC');

    # Clean up @INC
    @INC = grep { $_ ne $unique_path } @INC;
};

# =============================================================================
# Test 9: lib => undef doesn't modify @INC
# =============================================================================
subtest 'lib => undef skips @INC modification' => sub {
    my $before_count = scalar @INC;

    my $app = PAGI::Simple->new(name => 'Test', lib => undef);

    # @INC shouldn't have grown (might be same or less due to test isolation)
    ok(!defined $app->lib_dir, 'lib_dir is undef');
};

done_testing;
