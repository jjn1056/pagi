#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use File::Temp qw(tempdir);
use File::Path qw(make_path);

use lib 'lib';

# Test that the View module loads
ok(eval { require PAGI::Simple::View; 1 }, 'PAGI::Simple::View loads') or diag $@;
ok(eval { require PAGI::Simple::View::Helpers; 1 }, 'PAGI::Simple::View::Helpers loads') or diag $@;

# Create temp directory for templates
my $tmpdir = tempdir(CLEANUP => 1);

# Create a simple template
# Note: Variables are accessed as $v->{name} where $v is the vars hashref
open my $fh, '>', "$tmpdir/hello.html.ep" or die $!;
print $fh '<h1>Hello, <%= $v->{name} %>!</h1>';
close $fh;

# Test basic rendering
subtest 'Basic template rendering' => sub {
    my $view = PAGI::Simple::View->new(
        template_dir => $tmpdir,
        cache        => 0,
    );

    my $output = $view->render('hello', name => 'World');
    like($output, qr/Hello, World!/, 'Variable interpolated correctly');
    like($output, qr/<h1>.*<\/h1>/, 'HTML structure preserved');
};

# Test auto-escaping
subtest 'Auto-escaping' => sub {
    open my $fh2, '>', "$tmpdir/escape.html.ep" or die $!;
    print $fh2 '<div><%= $v->{content} %></div>';
    close $fh2;

    my $view = PAGI::Simple::View->new(
        template_dir => $tmpdir,
        auto_escape  => 1,
        cache        => 0,
    );

    my $output = $view->render('escape', content => '<script>alert(1)</script>');
    like($output, qr/&lt;script&gt;/, 'Script tags escaped');
    unlike($output, qr/<script>/, 'Raw script tag NOT present');
};

# Test raw() helper
subtest 'raw() helper bypasses escaping' => sub {
    open my $fh3, '>', "$tmpdir/raw_test.html.ep" or die $!;
    print $fh3 '<div><%= raw($v->{html}) %></div>';
    close $fh3;

    my $view = PAGI::Simple::View->new(
        template_dir => $tmpdir,
        auto_escape  => 1,
        cache        => 0,
    );

    my $output = $view->render('raw_test', html => '<b>bold</b>');
    like($output, qr/<b>bold<\/b>/, 'Raw HTML preserved');
};

# Test include()
subtest 'include() partial rendering' => sub {
    # Create partial
    open my $fh4, '>', "$tmpdir/_greeting.html.ep" or die $!;
    print $fh4 '<span>Hi, <%= $v->{who} %>!</span>';
    close $fh4;

    # Create main template
    open my $fh5, '>', "$tmpdir/with_partial.html.ep" or die $!;
    print $fh5 '<div><%= include("_greeting", who => $v->{name}) %></div>';
    close $fh5;

    my $view = PAGI::Simple::View->new(
        template_dir => $tmpdir,
        cache        => 0,
    );

    my $output = $view->render('with_partial', name => 'Friend');
    like($output, qr/Hi, Friend!/, 'Partial rendered with passed variable');
    like($output, qr/<div>.*<span>.*<\/span>.*<\/div>/s, 'Partial embedded in parent');
};

# Test template caching
subtest 'Template caching' => sub {
    my $view = PAGI::Simple::View->new(
        template_dir => $tmpdir,
        cache        => 1,
    );

    # First render
    my $output1 = $view->render('hello', name => 'Test1');
    like($output1, qr/Hello, Test1!/, 'First render works');

    # Second render should use cache
    my $output2 = $view->render('hello', name => 'Test2');
    like($output2, qr/Hello, Test2!/, 'Second render works');

    # Clear cache
    $view->clear_cache;

    # Third render after clear
    my $output3 = $view->render('hello', name => 'Test3');
    like($output3, qr/Hello, Test3!/, 'Render after cache clear works');
};

# Test render_string
subtest 'render_string' => sub {
    my $view = PAGI::Simple::View->new(
        template_dir => $tmpdir,
        cache        => 0,
    );

    my $output = $view->render_string('<p><%= $v->{msg} %></p>', msg => 'Dynamic!');
    like($output, qr/<p>Dynamic!<\/p>/, 'render_string works');
};

# Test missing template error
subtest 'Missing template error' => sub {
    my $view = PAGI::Simple::View->new(
        template_dir => $tmpdir,
        cache        => 0,
    );

    like(
        dies { $view->render('nonexistent') },
        qr/Template not found: 'nonexistent'/,
        'Clear error for missing template'
    );
};

done_testing;
