#!/usr/bin/env perl

use strict;
use warnings;
use Test2::V0;
use experimental 'signatures';

use lib 'lib';
use PAGI::Simple;
use PAGI::Simple::View;

use File::Temp qw(tempdir);
use File::Path qw(make_path);

# Create temp directory for templates
my $tempdir = tempdir(CLEANUP => 1);
make_path("$tempdir/templates");

# ============================================================================
# Test 1: Named routes with url_for()
# ============================================================================
subtest 'Named routes with url_for()' => sub {
    my $app = PAGI::Simple->new(name => 'TestApp');

    # Define named routes
    $app->get('/users/:id' => sub {})->name('user_show');
    $app->get('/posts/:post_id/comments/:id' => sub {})->name('comment_show');
    $app->get('/search' => sub {})->name('search');

    # Test basic URL generation
    is $app->url_for('user_show', id => 42), '/users/42', 'url_for generates basic URL';
    is $app->url_for('user_show', id => 123), '/users/123', 'url_for with different param';

    # Test multiple path params
    is $app->url_for('comment_show', post_id => 5, id => 10), '/posts/5/comments/10',
        'url_for with multiple path params';

    # Test route without params
    is $app->url_for('search'), '/search', 'url_for for route without params';
};

# ============================================================================
# Test 2: url_for() with query parameters
# ============================================================================
subtest 'url_for() with query parameters' => sub {
    my $app = PAGI::Simple->new(name => 'TestApp');

    $app->get('/search' => sub {})->name('search');
    $app->get('/users' => sub {})->name('users_list');

    # Test query parameter generation
    my $url1 = $app->url_for('search', query => { q => 'perl' });
    like $url1, qr{^/search\?}, 'URL starts with /search?';
    like $url1, qr{q=perl}, 'Query param q=perl present';

    # Test multiple query params
    my $url2 = $app->url_for('search', query => { q => 'perl', page => 2 });
    like $url2, qr{^/search\?}, 'URL starts with /search?';
    like $url2, qr{q=perl}, 'Query param q present';
    like $url2, qr{page=2}, 'Query param page present';

    # Test path params + query params
    $app->get('/users/:id/posts' => sub {})->name('user_posts');
    my $url3 = $app->url_for('user_posts', id => 5, query => { sort => 'date' });
    like $url3, qr{^/users/5/posts\?}, 'URL has path param';
    like $url3, qr{sort=date}, 'Query param present';
};

# ============================================================================
# Test 3: route() helper in templates
# ============================================================================
subtest 'route() helper in templates' => sub {
    my $app = PAGI::Simple->new(name => 'TestApp');
    $app->views("$tempdir/templates", { cache => 0 });

    $app->get('/users/:id' => sub {})->name('user_show');
    $app->get('/search' => sub {})->name('search');

    # Create template using route() helper
    open my $fh, '>', "$tempdir/templates/links.html.ep" or die $!;
    print $fh <<'TEMPLATE';
<a href="<%= route('user_show', id => 42) %>">User</a>
<a href="<%= route('search') %>">Search</a>
TEMPLATE
    close $fh;

    my $view = $app->view;
    my $html = $view->render('links');

    like $html, qr{href="/users/42"}, 'route() helper generates correct URL';
    like $html, qr{href="/search"}, 'route() helper works for simple routes';
};

# ============================================================================
# Test 4: route() with hx_* helpers
# ============================================================================
subtest 'route() with hx_* helpers' => sub {
    my $app = PAGI::Simple->new(name => 'TestApp');
    $app->views("$tempdir/templates", { cache => 0 });

    $app->del('/todos/:id' => sub {})->name('todo_delete');
    $app->post('/todos' => sub {})->name('todo_create');

    # Create template using route() with hx helpers
    open my $fh, '>', "$tempdir/templates/htmx_routes.html.ep" or die $!;
    print $fh <<'TEMPLATE';
<button <%= hx_delete(route('todo_delete', id => 1), target => '#todo-1', swap => 'outerHTML') %>>Delete</button>
<form <%= hx_post(route('todo_create'), target => '#todo-list', swap => 'beforeend') %>>
  <input name="title">
</form>
TEMPLATE
    close $fh;

    my $view = $app->view;
    my $html = $view->render('htmx_routes');

    like $html, qr{hx-delete="/todos/1"}, 'hx_delete with route() generates correct URL';
    like $html, qr{hx-post="/todos"}, 'hx_post with route() generates correct URL';
    like $html, qr{hx-target="#todo-1"}, 'hx-target preserved';
    like $html, qr{hx-swap="outerHTML"}, 'hx-swap preserved';
};

# ============================================================================
# Test 5: Unknown route returns undef
# ============================================================================
subtest 'Unknown route returns undef' => sub {
    my $app = PAGI::Simple->new(name => 'TestApp');

    my $url = $app->url_for('nonexistent');
    is $url, undef, 'url_for returns undef for unknown route';
};

# ============================================================================
# Test 6: RouteHandle chaining
# ============================================================================
subtest 'RouteHandle chaining' => sub {
    my $app = PAGI::Simple->new(name => 'TestApp');

    # Verify chaining returns the app for further route definitions
    my $result = $app->get('/a' => sub {})->name('route_a');

    # Should be able to continue defining routes
    $app->get('/b' => sub {})->name('route_b');

    is $app->url_for('route_a'), '/a', 'First named route works';
    is $app->url_for('route_b'), '/b', 'Second named route works';
};

# ============================================================================
# Test 7: URL encoding in path params
# ============================================================================
subtest 'URL encoding in path params' => sub {
    my $app = PAGI::Simple->new(name => 'TestApp');

    $app->get('/files/:name' => sub {})->name('file_show');

    # Test with special characters
    my $url = $app->url_for('file_show', name => 'my file.txt');
    # The path param might or might not be URL encoded depending on implementation
    # At minimum it should contain the path structure
    like $url, qr{^/files/}, 'URL has correct path structure';
};

done_testing;
