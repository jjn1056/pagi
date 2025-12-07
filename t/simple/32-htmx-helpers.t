#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use File::Temp qw(tempdir);
use File::Path qw(make_path);

use lib 'lib';
use PAGI::Simple::View;

# Create temp directory for templates
my $tmpdir = tempdir(CLEANUP => 1);
make_path("$tmpdir/templates");

# =============================================================================
# Test 1: htmx() script tag helper
# =============================================================================
subtest 'htmx() generates script tag' => sub {
    my $view = PAGI::Simple::View->new(
        template_dir => "$tmpdir/templates",
        cache        => 0,
    );

    my $html = $view->render_string('<%= htmx() %>');

    like($html, qr/<script\s+src="[^"]*htmx\.min\.js"/, 'htmx() generates script tag with htmx.min.js');
    like($html, qr/<\/script>/, 'script tag is properly closed');
};

# =============================================================================
# Test 2: htmx_ws() WebSocket extension script tag
# =============================================================================
subtest 'htmx_ws() generates WebSocket extension script tag' => sub {
    my $view = PAGI::Simple::View->new(
        template_dir => "$tmpdir/templates",
        cache        => 0,
    );

    my $html = $view->render_string('<%= htmx_ws() %>');

    like($html, qr/<script\s+src="[^"]*ws\.js"/, 'htmx_ws() generates script tag with ws.js');
    like($html, qr/ext\/ws\.js/, 'points to ext/ directory');
};

# =============================================================================
# Test 3: htmx_sse() SSE extension script tag
# =============================================================================
subtest 'htmx_sse() generates SSE extension script tag' => sub {
    my $view = PAGI::Simple::View->new(
        template_dir => "$tmpdir/templates",
        cache        => 0,
    );

    my $html = $view->render_string('<%= htmx_sse() %>');

    like($html, qr/<script\s+src="[^"]*sse\.js"/, 'htmx_sse() generates script tag with sse.js');
    like($html, qr/ext\/sse\.js/, 'points to ext/ directory');
};

# =============================================================================
# Test 4: hx_get() basic attributes
# =============================================================================
subtest 'hx_get() generates correct attributes' => sub {
    my $view = PAGI::Simple::View->new(
        template_dir => "$tmpdir/templates",
        cache        => 0,
    );

    # Basic URL only
    my $html = $view->render_string(q{<button <%= hx_get('/api/data') %>></button>});
    like($html, qr/hx-get="\/api\/data"/, 'hx-get attribute with URL');

    # With target and swap
    $html = $view->render_string(q{<button <%= hx_get('/api/data', target => '#result', swap => 'innerHTML') %>></button>});
    like($html, qr/hx-get="\/api\/data"/, 'hx-get attribute present');
    like($html, qr/hx-target="#result"/, 'hx-target attribute present');
    like($html, qr/hx-swap="innerHTML"/, 'hx-swap attribute present');
};

# =============================================================================
# Test 5: hx_post() with all options
# =============================================================================
subtest 'hx_post() generates correct attributes with all options' => sub {
    my $view = PAGI::Simple::View->new(
        template_dir => "$tmpdir/templates",
        cache        => 0,
    );

    my $html = $view->render_string(q{<form <%= hx_post('/submit', target => 'this', trigger => 'click', confirm => 'Are you sure?') %>></form>});

    like($html, qr/hx-post="\/submit"/, 'hx-post attribute');
    like($html, qr/hx-target="this"/, 'hx-target attribute');
    like($html, qr/hx-trigger="click"/, 'hx-trigger attribute');
    like($html, qr/hx-confirm="Are you sure\?"/, 'hx-confirm attribute');
};

# =============================================================================
# Test 6: hx_delete() with confirm dialog
# =============================================================================
subtest 'hx_delete() with confirm dialog' => sub {
    my $view = PAGI::Simple::View->new(
        template_dir => "$tmpdir/templates",
        cache        => 0,
    );

    my $html = $view->render_string(q{<button <%= hx_delete('/items/123', confirm => 'Delete item?') %>></button>});

    like($html, qr/hx-delete="\/items\/123"/, 'hx-delete attribute');
    like($html, qr/hx-confirm="Delete item\?"/, 'hx-confirm attribute');
};

# =============================================================================
# Test 7: hx_put() and hx_patch()
# =============================================================================
subtest 'hx_put() and hx_patch() work correctly' => sub {
    my $view = PAGI::Simple::View->new(
        template_dir => "$tmpdir/templates",
        cache        => 0,
    );

    my $html = $view->render_string(q{<form <%= hx_put('/resource/1', target => '#form') %>></form>});
    like($html, qr/hx-put="\/resource\/1"/, 'hx-put attribute');
    like($html, qr/hx-target="#form"/, 'hx-target attribute');

    $html = $view->render_string(q{<form <%= hx_patch('/resource/1', swap => 'outerHTML') %>></form>});
    like($html, qr/hx-patch="\/resource\/1"/, 'hx-patch attribute');
    like($html, qr/hx-swap="outerHTML"/, 'hx-swap attribute');
};

# =============================================================================
# Test 8: hx_* with vals option (JSON serialization)
# =============================================================================
subtest 'hx_* with vals option serializes to JSON' => sub {
    my $view = PAGI::Simple::View->new(
        template_dir => "$tmpdir/templates",
        cache        => 0,
    );

    my $html = $view->render_string(q{<button <%= hx_post('/submit', vals => { key => 'value', num => 42 }) %>></button>});

    like($html, qr/hx-post="\/submit"/, 'hx-post attribute');
    like($html, qr/hx-vals='/, 'hx-vals attribute present (single quotes)');
    # JSON should contain key and value with proper double quotes
    like($html, qr/"key"/, 'key in JSON');
    like($html, qr/"value"/, 'value in JSON');
};

# =============================================================================
# Test 9: hx_* with headers option (JSON serialization)
# =============================================================================
subtest 'hx_* with headers option serializes to JSON' => sub {
    my $view = PAGI::Simple::View->new(
        template_dir => "$tmpdir/templates",
        cache        => 0,
    );

    my $html = $view->render_string(q{<button <%= hx_get('/api', headers => { 'X-Custom' => 'test' }) %>></button>});

    like($html, qr/hx-get="\/api"/, 'hx-get attribute');
    like($html, qr/hx-headers='/, 'hx-headers attribute present (single quotes)');
    like($html, qr/X-Custom/, 'header name in JSON');
};

# =============================================================================
# Test 10: hx_* with additional options (indicator, disabled_elt, select, push_url)
# =============================================================================
subtest 'hx_* with additional options' => sub {
    my $view = PAGI::Simple::View->new(
        template_dir => "$tmpdir/templates",
        cache        => 0,
    );

    # indicator option
    my $html = $view->render_string(q{<button <%= hx_get('/slow', indicator => '#spinner') %>></button>});
    like($html, qr/hx-indicator="#spinner"/, 'hx-indicator attribute');

    # disabled_elt option
    $html = $view->render_string(q{<button <%= hx_post('/submit', disabled_elt => 'this') %>></button>});
    like($html, qr/hx-disabled-elt="this"/, 'hx-disabled-elt attribute');

    # select option
    $html = $view->render_string(q{<div <%= hx_get('/page', select => '.content') %>></div>});
    like($html, qr/hx-select="\.content"/, 'hx-select attribute');

    # push_url option (boolean true)
    $html = $view->render_string(q{<a <%= hx_get('/page', push_url => 1) %>>Link</a>});
    like($html, qr/hx-push-url="true"/, 'hx-push-url attribute with boolean');

    # push_url option (custom URL)
    $html = $view->render_string(q{<a <%= hx_get('/api', push_url => '/page') %>>Link</a>});
    like($html, qr/hx-push-url="\/page"/, 'hx-push-url attribute with custom URL');
};

# =============================================================================
# Test 11: hx_sse() for Server-Sent Events
# =============================================================================
subtest 'hx_sse() generates SSE connection attributes' => sub {
    my $view = PAGI::Simple::View->new(
        template_dir => "$tmpdir/templates",
        cache        => 0,
    );

    my $html = $view->render_string(q{<div <%= hx_sse('/events', connect => 1, swap => 'beforeend') %>></div>});

    like($html, qr/hx-ext="sse"/, 'hx-ext="sse" attribute');
    like($html, qr/sse-connect="\/events"/, 'sse-connect attribute with URL');
    like($html, qr/sse-swap="beforeend"/, 'sse-swap attribute');
};

# =============================================================================
# Test 12: hx_ws() for WebSocket connections
# =============================================================================
subtest 'hx_ws() generates WebSocket connection attributes' => sub {
    my $view = PAGI::Simple::View->new(
        template_dir => "$tmpdir/templates",
        cache        => 0,
    );

    my $html = $view->render_string(q{<div <%= hx_ws('/ws', connect => 1) %>></div>});

    like($html, qr/hx-ext="ws"/, 'hx-ext="ws" attribute');
    like($html, qr/ws-connect="\/ws"/, 'ws-connect attribute with URL');

    # With send option
    $html = $view->render_string(q{<form <%= hx_ws('/ws', connect => 1, send => '#send-btn') %>></form>});
    like($html, qr/ws-send="#send-btn"/, 'ws-send attribute');
};

# =============================================================================
# Test 13: Helpers in template file (not just string)
# =============================================================================
subtest 'htmx helpers work in template files' => sub {
    # Create template file
    my $template_content = <<'TEMPLATE';
<!DOCTYPE html>
<html>
<head>
<%= htmx() %>
</head>
<body>
  <button <%= hx_post('/action', target => '#result') %>>Click</button>
  <div id="result"></div>
</body>
</html>
TEMPLATE

    open my $fh, '>', "$tmpdir/templates/htmx-test.html.ep" or die "Cannot create template: $!";
    print $fh $template_content;
    close $fh;

    my $view = PAGI::Simple::View->new(
        template_dir => "$tmpdir/templates",
        cache        => 0,
    );

    my $html = $view->render('htmx-test');

    like($html, qr/<script\s+src="[^"]*htmx\.min\.js"/, 'htmx script tag in file template');
    like($html, qr/hx-post="\/action"/, 'hx-post in file template');
    like($html, qr/hx-target="#result"/, 'hx-target in file template');
};

# =============================================================================
# Test 14: Combined helpers in realistic template
# =============================================================================
subtest 'realistic todo item template with htmx' => sub {
    my $template_content = <<'TEMPLATE';
<li id="todo-<%= $v->{id} %>" class="todo-item">
  <input type="checkbox"
         <%= hx_patch("/todos/$v->{id}/toggle",
                      target => "#todo-$v->{id}",
                      swap => 'outerHTML') %>>
  <span><%= $v->{title} %></span>
  <button <%= hx_delete("/todos/$v->{id}",
                        target => "#todo-$v->{id}",
                        swap => 'outerHTML',
                        confirm => 'Delete?') %>>X</button>
</li>
TEMPLATE

    open my $fh, '>:utf8', "$tmpdir/templates/todo-item.html.ep" or die "Cannot create template: $!";
    print $fh $template_content;
    close $fh;

    my $view = PAGI::Simple::View->new(
        template_dir => "$tmpdir/templates",
        cache        => 0,
    );

    my $html = $view->render('todo-item', id => 42, title => 'Test Todo');

    like($html, qr/id="todo-42"/, 'todo id interpolated');
    like($html, qr/hx-patch="\/todos\/42\/toggle"/, 'hx-patch with interpolated id');
    like($html, qr/hx-target="#todo-42"/, 'hx-target with interpolated id');
    like($html, qr/hx-delete="\/todos\/42"/, 'hx-delete with interpolated id');
    like($html, qr/hx-confirm="Delete\?"/, 'hx-confirm attribute');
    like($html, qr/Test Todo/, 'title displayed');
};

# =============================================================================
# Test 15: Escaping in confirm messages
# =============================================================================
subtest 'special characters in confirm are escaped' => sub {
    my $view = PAGI::Simple::View->new(
        template_dir => "$tmpdir/templates",
        cache        => 0,
    );

    my $html = $view->render_string(q{<button <%= hx_delete('/item', confirm => 'Delete "this" & that?') %>>Del</button>});

    like($html, qr/hx-confirm="Delete &quot;this&quot; &amp; that\?"/, 'quotes and ampersand escaped in confirm');
};

# =============================================================================
# Test 16: Bundled htmx files exist
# =============================================================================
subtest 'bundled htmx files exist in share/' => sub {
    ok(-f 'share/htmx/htmx.min.js', 'htmx.min.js exists');
    ok(-f 'share/htmx/ext/ws.js', 'ws.js extension exists');
    ok(-f 'share/htmx/ext/sse.js', 'sse.js extension exists');

    # Check htmx version is 2.x (file should contain version info)
    open my $fh, '<', 'share/htmx/htmx.min.js' or die "Cannot read htmx.min.js: $!";
    my $content = do { local $/; <$fh> };
    close $fh;

    like($content, qr/htmx/, 'htmx.min.js contains htmx code');
};

# =============================================================================
# Test 17: All script tag helpers return safe strings (not double-escaped)
# =============================================================================
subtest 'script tag helpers return safe strings' => sub {
    my $view = PAGI::Simple::View->new(
        template_dir => "$tmpdir/templates",
        cache        => 0,
    );

    my $html = $view->render_string('<%= htmx() %><%= htmx_sse() %>');

    # Should not have escaped < or >
    unlike($html, qr/&lt;script/, 'script tag not escaped');
    unlike($html, qr/&gt;/, 'closing bracket not escaped');
    like($html, qr/<script/, 'raw script tag present');
};

# =============================================================================
# Test 18: hx_* helpers return safe strings (not double-escaped)
# =============================================================================
subtest 'hx_* helpers return safe strings' => sub {
    my $view = PAGI::Simple::View->new(
        template_dir => "$tmpdir/templates",
        cache        => 0,
    );

    my $html = $view->render_string('<button <%= hx_get("/test") %>>Test</button>');

    # Attribute should not be escaped
    unlike($html, qr/&quot;\/test&quot;/, 'URL in attribute not escaped with &quot;');
    like($html, qr/hx-get="\/test"/, 'proper attribute format');
};

# =============================================================================
# Test 19: htmx() requires $app->share('htmx')
# =============================================================================
subtest 'htmx() requires $app->share(htmx) when app is present' => sub {
    use PAGI::Simple;

    # Create app without share('htmx')
    my $app = PAGI::Simple->new(
        name  => 'Test App',
        views => "$tmpdir/templates",
    );

    # Get the view from the app
    my $view = $app->view;
    ok($view, 'got view from app');

    # htmx() should die without share('htmx')
    my $error;
    eval { $view->render_string('<%= htmx() %>') };
    $error = $@;

    ok($error, 'htmx() dies without share(htmx)');
    like($error, qr/htmx\(\) requires.*share\('htmx'\)/i, 'error message mentions share(htmx)');
};

# =============================================================================
# Test 20: htmx() works after $app->share('htmx')
# =============================================================================
subtest 'htmx() works after $app->share(htmx)' => sub {
    use PAGI::Simple;

    # Create app with share('htmx')
    my $app = PAGI::Simple->new(
        name  => 'Test App',
        views => "$tmpdir/templates",
    );
    $app->share('htmx');

    # Get the view from the app
    my $view = $app->view;

    # htmx() should work now
    my $html = $view->render_string('<%= htmx() %>');

    like($html, qr/<script\s+src="[^"]*htmx\.min\.js"/, 'htmx() works after share(htmx)');
};

# =============================================================================
# Test 21: htmx_sse() requires $app->share('htmx')
# =============================================================================
subtest 'htmx_sse() requires $app->share(htmx) when app is present' => sub {
    use PAGI::Simple;

    # Create app without share('htmx')
    my $app = PAGI::Simple->new(
        name  => 'Test App',
        views => "$tmpdir/templates",
    );

    my $view = $app->view;

    # htmx_sse() should die without share('htmx')
    my $error;
    eval { $view->render_string('<%= htmx_sse() %>') };
    $error = $@;

    ok($error, 'htmx_sse() dies without share(htmx)');
    like($error, qr/htmx_sse\(\) requires.*share\('htmx'\)/i, 'error message mentions share(htmx)');
};

# =============================================================================
# Test 22: htmx_ws() requires $app->share('htmx')
# =============================================================================
subtest 'htmx_ws() requires $app->share(htmx) when app is present' => sub {
    use PAGI::Simple;

    # Create app without share('htmx')
    my $app = PAGI::Simple->new(
        name  => 'Test App',
        views => "$tmpdir/templates",
    );

    my $view = $app->view;

    # htmx_ws() should die without share('htmx')
    my $error;
    eval { $view->render_string('<%= htmx_ws() %>') };
    $error = $@;

    ok($error, 'htmx_ws() dies without share(htmx)');
    like($error, qr/htmx_ws\(\) requires.*share\('htmx'\)/i, 'error message mentions share(htmx)');
};

done_testing();
