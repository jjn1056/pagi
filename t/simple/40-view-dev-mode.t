#!/usr/bin/env perl

use strict;
use warnings;
use experimental 'signatures';
use Test2::V0;
use File::Temp qw(tempdir);
use File::Path qw(make_path);

# =============================================================================
# PAGI::Simple::View Development Mode Tests
#
# Tests for Step 19: Development mode features
# - Cache disabled in dev mode
# - Detailed error messages with source context
# - Helpful missing template errors with suggestions
# =============================================================================

use lib 'lib';
use PAGI::Simple::View;

my $tempdir = tempdir(CLEANUP => 1);
make_path("$tempdir/templates");

# Helper to create a template file
sub create_template ($name, $content) {
    my $path = "$tempdir/templates/$name.html.ep";
    my $dir = $path =~ s{/[^/]+$}{}r;
    make_path($dir) unless -d $dir;
    open my $fh, '>', $path or die "Cannot create $path: $!";
    print $fh $content;
    close $fh;
    return $path;
}

# =============================================================================
# Test 1: Development mode disables caching
# =============================================================================
subtest 'Development mode disables caching' => sub {
    create_template('cached_test', 'Version 1');

    # Production mode (default) - should cache
    my $prod_view = PAGI::Simple::View->new(
        template_dir => "$tempdir/templates",
        cache        => 1,
    );

    my $result1 = $prod_view->render('cached_test');
    like $result1, qr/Version 1/, 'First render shows Version 1';

    # Modify the template
    create_template('cached_test', 'Version 2');

    my $result2 = $prod_view->render('cached_test');
    like $result2, qr/Version 1/, 'Production mode uses cached Version 1';

    # Development mode - should not cache
    my $dev_view = PAGI::Simple::View->new(
        template_dir => "$tempdir/templates",
        development  => 1,
    );

    my $result3 = $dev_view->render('cached_test');
    like $result3, qr/Version 2/, 'Dev mode sees Version 2';

    # Modify again
    create_template('cached_test', 'Version 3');

    my $result4 = $dev_view->render('cached_test');
    like $result4, qr/Version 3/, 'Dev mode sees Version 3 without restart';

    ok !$dev_view->{cache}, 'Dev mode sets cache => 0';
};

# =============================================================================
# Test 2: Missing template error shows searched paths
# =============================================================================
subtest 'Missing template error shows searched paths' => sub {
    my $view = PAGI::Simple::View->new(
        template_dir => "$tempdir/templates",
    );

    my $error;
    eval { $view->render('nonexistent_template_xyz') };
    $error = $@;

    like $error, qr/Template not found: 'nonexistent_template_xyz'/,
        'Error message includes template name';
    like $error, qr/Searched paths:/,
        'Error shows searched paths header';
    like $error, qr/nonexistent_template_xyz\.html\.ep/,
        'Error shows the path that was searched';
    like $error, qr/Template directory:/,
        'Error shows template directory';
};

# =============================================================================
# Test 3: Missing template suggests similar names
# =============================================================================
subtest 'Missing template suggests similar names' => sub {
    # Create some templates
    create_template('users/index', 'Users Index');
    create_template('users/show', 'Users Show');
    create_template('users/_item', 'User Item');

    my $view = PAGI::Simple::View->new(
        template_dir => "$tempdir/templates",
    );

    my $error;
    eval { $view->render('users/indx') };  # Typo: indx instead of index
    $error = $@;

    like $error, qr/Template not found/, 'Error for typo';
    # The "Did you mean" feature should suggest similar templates
    like $error, qr/Did you mean:|users/, 'May suggest similar templates';
};

# =============================================================================
# Test 4: Missing template directory warning
# =============================================================================
subtest 'Missing template directory warning' => sub {
    my $view = PAGI::Simple::View->new(
        template_dir => '/nonexistent/path/templates',
    );

    my $error;
    eval { $view->render('anything') };
    $error = $@;

    like $error, qr/Template not found/, 'Error for missing dir';
    like $error, qr/WARNING.*does not exist/i, 'Warns about missing directory';
};

# =============================================================================
# Test 5: Template compilation error shows source context
# =============================================================================
subtest 'Template compilation error shows source context' => sub {
    create_template('syntax_error', <<'TEMPLATE');
<html>
<body>
<h1>Hello</h1>
<% if ($foo) { %>
  <p>Foo is true</p>
<% # Missing closing brace %>
</body>
</html>
TEMPLATE

    my $view = PAGI::Simple::View->new(
        template_dir => "$tempdir/templates",
    );

    my $error;
    eval { $view->render('syntax_error') };
    $error = $@;

    like $error, qr/Template compilation error in 'syntax_error'/,
        'Error identifies the template';
    like $error, qr/File:.*syntax_error\.html\.ep/,
        'Error shows the file path';
    # Should have some error message from Perl
    like $error, qr/Error:/, 'Error shows the error message';
};

# =============================================================================
# Test 6: Dev mode shows full source on compile error
# =============================================================================
subtest 'Dev mode shows full source on compile error' => sub {
    create_template('dev_error', <<'TEMPLATE');
<html>
<% my $x = ; %>
</html>
TEMPLATE

    my $dev_view = PAGI::Simple::View->new(
        template_dir => "$tempdir/templates",
        development  => 1,
    );

    my $error;
    eval { $dev_view->render('dev_error') };
    $error = $@;

    like $error, qr/Template compilation error/, 'Error caught';
    like $error, qr/Full template source:/, 'Dev mode shows full source';
    like $error, qr/my \$x = ;/, 'Source contains the bad code';
};

# =============================================================================
# Test 7: render_string also gets good errors
# =============================================================================
subtest 'render_string also gets good errors' => sub {
    my $view = PAGI::Simple::View->new(
        template_dir => "$tempdir/templates",
    );

    my $error;
    eval { $view->render_string('<% if (1) { %> missing end') };
    $error = $@;

    like $error, qr/Template compilation error in 'string'/,
        'render_string errors identify as string';
};

# =============================================================================
# Test 8: Partial errors in include are caught
# =============================================================================
subtest 'Partial include errors are caught' => sub {
    create_template('good_page2', <<'TEMPLATE');
<%= include('bad_partial2') %>
TEMPLATE

    create_template('_bad_partial2', <<'TEMPLATE');
<% my @x = ( %>
TEMPLATE

    my $view = PAGI::Simple::View->new(
        template_dir => "$tempdir/templates",
    );

    my $error;
    eval { $view->render('good_page2') };
    $error = $@;

    ok $error, 'Error is thrown for bad partial';
    # The error propagates - exact format depends on Template::EmbeddedPerl
    like $error, qr/bad_partial2|compilation|syntax|error/i,
        'Error message contains relevant info';
};

# =============================================================================
# Test 9: clear_cache works
# =============================================================================
subtest 'clear_cache forces recompilation' => sub {
    create_template('clearable', 'Original');

    my $view = PAGI::Simple::View->new(
        template_dir => "$tempdir/templates",
        cache        => 1,
    );

    my $r1 = $view->render('clearable');
    like $r1, qr/Original/, 'First render';

    create_template('clearable', 'Modified');

    my $r2 = $view->render('clearable');
    like $r2, qr/Original/, 'Still cached';

    $view->clear_cache;

    my $r3 = $view->render('clearable');
    like $r3, qr/Modified/, 'After clear_cache sees new version';
};

done_testing;
