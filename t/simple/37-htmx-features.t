#!/usr/bin/env perl

use strict;
use warnings;
use Test2::V0;
use experimental 'signatures';

use lib 'lib';
use PAGI::Simple;
use PAGI::Simple::Request;
use PAGI::Simple::Context;

use File::Temp qw(tempdir);
use File::Path qw(make_path);

# Create temp directory for templates
my $tempdir = tempdir(CLEANUP => 1);
make_path("$tempdir/templates/layouts");

# Write test templates
{
    # Simple layout
    open my $fh, '>', "$tempdir/templates/layouts/default.html.ep" or die $!;
    print $fh <<'LAYOUT';
<!DOCTYPE html>
<html>
<head><title>Test</title></head>
<body>
<%= content %>
</body>
</html>
LAYOUT
    close $fh;

    # Content template that uses layout
    open $fh, '>', "$tempdir/templates/page.html.ep" or die $!;
    print $fh <<'TEMPLATE';
% extends 'layouts/default';
<h1><%= $v->{title} %></h1>
<p><%= $v->{message} %></p>
TEMPLATE
    close $fh;

    # Partial template (no layout)
    open $fh, '>', "$tempdir/templates/_item.html.ep" or die $!;
    print $fh <<'TEMPLATE';
<div class="item" id="item-<%= $v->{id} %>">
  <span><%= $v->{name} %></span>
</div>
TEMPLATE
    close $fh;
}

# Helper to create mock scope
sub mock_scope (%overrides) {
    return {
        type         => 'http',
        method       => 'GET',
        path         => '/',
        query_string => '',
        headers      => [],
        server       => ['localhost', 5000],
        client       => ['127.0.0.1', 12345],
        %overrides,
    };
}

# Helper to create mock receive function
sub mock_receive {
    my @events = @_;
    my $idx = 0;
    return sub {
        return Future->done($events[$idx++] // { type => 'http.disconnect' });
    };
}

# Helper to create mock send function that captures response
sub mock_send {
    my @responses;
    my $send = sub ($event) {
        push @responses, $event;
        return Future->done;
    };
    return ($send, \@responses);
}

# ============================================================================
# Test 1: is_htmx() request detection
# ============================================================================
subtest 'is_htmx() request detection' => sub {
    # Without HX-Request header
    my $scope1 = mock_scope(headers => []);
    my $req1 = PAGI::Simple::Request->new($scope1);
    ok !$req1->is_htmx, 'is_htmx returns false without HX-Request header';

    # With HX-Request: true header
    my $scope2 = mock_scope(headers => [['HX-Request', 'true']]);
    my $req2 = PAGI::Simple::Request->new($scope2);
    ok $req2->is_htmx, 'is_htmx returns true with HX-Request: true header';

    # With HX-Request: false header (should be false)
    my $scope3 = mock_scope(headers => [['HX-Request', 'false']]);
    my $req3 = PAGI::Simple::Request->new($scope3);
    ok !$req3->is_htmx, 'is_htmx returns false with HX-Request: false header';
};

# ============================================================================
# Test 2: htmx_target() accessor
# ============================================================================
subtest 'htmx_target() accessor' => sub {
    my $scope1 = mock_scope(headers => []);
    my $req1 = PAGI::Simple::Request->new($scope1);
    is $req1->htmx_target, undef, 'htmx_target returns undef when not set';

    my $scope2 = mock_scope(headers => [['HX-Target', '#todo-list']]);
    my $req2 = PAGI::Simple::Request->new($scope2);
    is $req2->htmx_target, '#todo-list', 'htmx_target returns correct value';
};

# ============================================================================
# Test 3: htmx_current_url() accessor
# ============================================================================
subtest 'htmx_current_url() accessor' => sub {
    my $scope1 = mock_scope(headers => []);
    my $req1 = PAGI::Simple::Request->new($scope1);
    is $req1->htmx_current_url, undef, 'htmx_current_url returns undef when not set';

    my $scope2 = mock_scope(headers => [['HX-Current-URL', 'http://example.com/page']]);
    my $req2 = PAGI::Simple::Request->new($scope2);
    is $req2->htmx_current_url, 'http://example.com/page', 'htmx_current_url returns correct value';
};

# ============================================================================
# Test 4: htmx_trigger() and htmx_trigger_name() accessors
# ============================================================================
subtest 'htmx_trigger() and htmx_trigger_name() accessors' => sub {
    my $scope = mock_scope(headers => [
        ['HX-Trigger', 'btn-submit'],
        ['HX-Trigger-Name', 'submit_button'],
    ]);
    my $req = PAGI::Simple::Request->new($scope);
    is $req->htmx_trigger, 'btn-submit', 'htmx_trigger returns correct id';
    is $req->htmx_trigger_name, 'submit_button', 'htmx_trigger_name returns correct name';
};

# ============================================================================
# Test 5: htmx_prompt() accessor
# ============================================================================
subtest 'htmx_prompt() accessor' => sub {
    my $scope = mock_scope(headers => [['HX-Prompt', 'user input text']]);
    my $req = PAGI::Simple::Request->new($scope);
    is $req->htmx_prompt, 'user input text', 'htmx_prompt returns user input';
};

# ============================================================================
# Test 6: htmx_boosted() and is_boosted() boolean detection
# ============================================================================
subtest 'htmx_boosted() and is_boosted() boolean detection' => sub {
    # Without HX-Boosted header
    my $scope1 = mock_scope(headers => []);
    my $req1 = PAGI::Simple::Request->new($scope1);
    ok !$req1->htmx_boosted, 'htmx_boosted returns false without HX-Boosted header';
    ok !$req1->is_boosted, 'is_boosted returns false without HX-Boosted header';

    # With HX-Boosted: true header
    my $scope2 = mock_scope(headers => [['HX-Boosted', 'true']]);
    my $req2 = PAGI::Simple::Request->new($scope2);
    ok $req2->htmx_boosted, 'htmx_boosted returns true with HX-Boosted: true header';
    ok $req2->is_boosted, 'is_boosted returns true with HX-Boosted: true header';

    # With HX-Boosted: false header (should be false)
    my $scope3 = mock_scope(headers => [['HX-Boosted', 'false']]);
    my $req3 = PAGI::Simple::Request->new($scope3);
    ok !$req3->htmx_boosted, 'htmx_boosted returns false with HX-Boosted: false header';
    ok !$req3->is_boosted, 'is_boosted returns false with HX-Boosted: false header';
};

# ============================================================================
# Test 7: hx_trigger() response header - simple event
# ============================================================================
subtest 'hx_trigger() response header - simple event' => sub {
    my $app = PAGI::Simple->new(name => 'TestApp');

    my ($send, $responses) = mock_send();
    my $scope = mock_scope();
    my $receive = mock_receive();

    my $c = PAGI::Simple::Context->new(
        app     => $app,
        scope   => $scope,
        receive => $receive,
        send    => $send,
    );

    # Set trigger
    $c->hx_trigger('todoAdded');

    # Check header was added
    my @headers = @{$c->response_headers};
    my ($trigger_header) = grep { $_->[0] eq 'HX-Trigger' } @headers;
    ok $trigger_header, 'HX-Trigger header was added';
    is $trigger_header->[1], 'todoAdded', 'Simple event name is correct';
};

# ============================================================================
# Test 8: hx_trigger() response header - event with data
# ============================================================================
subtest 'hx_trigger() response header - event with data' => sub {
    my $app = PAGI::Simple->new(name => 'TestApp');

    my ($send, $responses) = mock_send();
    my $scope = mock_scope();
    my $receive = mock_receive();

    my $c = PAGI::Simple::Context->new(
        app     => $app,
        scope   => $scope,
        receive => $receive,
        send    => $send,
    );

    # Set trigger with data
    $c->hx_trigger('showToast', message => 'Item saved!', type => 'success');

    # Check header was added
    my @headers = @{$c->response_headers};
    my ($trigger_header) = grep { $_->[0] eq 'HX-Trigger' } @headers;
    ok $trigger_header, 'HX-Trigger header was added with data';
    like $trigger_header->[1], qr/"showToast"/, 'Event name in JSON';
    like $trigger_header->[1], qr/"message"/, 'Data key present';
    like $trigger_header->[1], qr/Item saved!/, 'Data value present';
};

# ============================================================================
# Test 9: hx_redirect() response header
# ============================================================================
subtest 'hx_redirect() response header' => sub {
    my $app = PAGI::Simple->new(name => 'TestApp');

    my ($send, $responses) = mock_send();
    my $scope = mock_scope();
    my $receive = mock_receive();

    my $c = PAGI::Simple::Context->new(
        app     => $app,
        scope   => $scope,
        receive => $receive,
        send    => $send,
    );

    # Set redirect
    $c->hx_redirect('/new-location');

    # Check header was added
    my @headers = @{$c->response_headers};
    my ($redirect_header) = grep { $_->[0] eq 'HX-Redirect' } @headers;
    ok $redirect_header, 'HX-Redirect header was added';
    is $redirect_header->[1], '/new-location', 'Redirect URL is correct';
};

# ============================================================================
# Test 10: hx_refresh() response header
# ============================================================================
subtest 'hx_refresh() response header' => sub {
    my $app = PAGI::Simple->new(name => 'TestApp');

    my ($send, $responses) = mock_send();
    my $scope = mock_scope();
    my $receive = mock_receive();

    my $c = PAGI::Simple::Context->new(
        app     => $app,
        scope   => $scope,
        receive => $receive,
        send    => $send,
    );

    # Set refresh
    $c->hx_refresh;

    # Check header was added
    my @headers = @{$c->response_headers};
    my ($refresh_header) = grep { $_->[0] eq 'HX-Refresh' } @headers;
    ok $refresh_header, 'HX-Refresh header was added';
    is $refresh_header->[1], 'true', 'Refresh value is true';
};

# ============================================================================
# Test 11: render_or_redirect() - browser request gets redirect
# ============================================================================
subtest 'render_or_redirect() - browser request gets redirect' => sub {
    my $app = PAGI::Simple->new(name => 'TestApp');
    $app->views("$tempdir/templates", { cache => 0 });

    my ($send, $responses) = mock_send();
    my $scope = mock_scope(headers => []);  # No HX-Request header
    my $receive = mock_receive();

    my $c = PAGI::Simple::Context->new(
        app     => $app,
        scope   => $scope,
        receive => $receive,
        send    => $send,
    );

    # Call render_or_redirect
    $c->render_or_redirect('/todos', '_item', id => 1, name => 'Test')->get;

    # Should be a redirect
    ok @$responses >= 1, 'Response was sent';
    is $responses->[0]{status}, 302, 'Browser gets 302 redirect';

    my %headers = map { $_->[0] => $_->[1] } @{$responses->[0]{headers}};
    is $headers{location}, '/todos', 'Redirect location is correct';
};

# ============================================================================
# Test 12: render_or_redirect() - htmx request gets rendered template
# ============================================================================
subtest 'render_or_redirect() - htmx request gets rendered template' => sub {
    my $app = PAGI::Simple->new(name => 'TestApp');
    $app->views("$tempdir/templates", { cache => 0 });

    my ($send, $responses) = mock_send();
    my $scope = mock_scope(headers => [['HX-Request', 'true']]);  # htmx request
    my $receive = mock_receive();

    my $c = PAGI::Simple::Context->new(
        app     => $app,
        scope   => $scope,
        receive => $receive,
        send    => $send,
    );

    # Call render_or_redirect
    $c->render_or_redirect('/todos', '_item', id => 42, name => 'Test Item')->get;

    # Should be rendered content
    ok @$responses >= 2, 'Response with body was sent';
    is $responses->[0]{status}, 200, 'htmx gets 200 OK';

    my $body = $responses->[1]{body};
    like $body, qr/item-42/, 'Body contains item id';
    like $body, qr/Test Item/, 'Body contains item name';
};

# ============================================================================
# Test 13: empty_or_redirect() - browser request gets redirect
# ============================================================================
subtest 'empty_or_redirect() - browser request gets redirect' => sub {
    my $app = PAGI::Simple->new(name => 'TestApp');

    my ($send, $responses) = mock_send();
    my $scope = mock_scope(headers => []);  # No HX-Request header
    my $receive = mock_receive();

    my $c = PAGI::Simple::Context->new(
        app     => $app,
        scope   => $scope,
        receive => $receive,
        send    => $send,
    );

    # Call empty_or_redirect
    $c->empty_or_redirect('/todos')->get;

    # Should be a redirect
    ok @$responses >= 1, 'Response was sent';
    is $responses->[0]{status}, 302, 'Browser gets 302 redirect';

    my %headers = map { $_->[0] => $_->[1] } @{$responses->[0]{headers}};
    is $headers{location}, '/todos', 'Redirect location is correct';
};

# ============================================================================
# Test 14: empty_or_redirect() - htmx request gets empty response
# ============================================================================
subtest 'empty_or_redirect() - htmx request gets empty response' => sub {
    my $app = PAGI::Simple->new(name => 'TestApp');

    my ($send, $responses) = mock_send();
    my $scope = mock_scope(headers => [['HX-Request', 'true']]);
    my $receive = mock_receive();

    my $c = PAGI::Simple::Context->new(
        app     => $app,
        scope   => $scope,
        receive => $receive,
        send    => $send,
    );

    # Call empty_or_redirect
    $c->empty_or_redirect('/todos')->get;

    # Should be empty 200
    ok @$responses >= 2, 'Response with body was sent';
    is $responses->[0]{status}, 200, 'htmx gets 200 OK';
    is $responses->[1]{body}, '', 'Body is empty (for element removal)';
};

# ============================================================================
# Test 15: Auto-fragment detection - browser gets full layout
# ============================================================================
subtest 'Auto-fragment detection - browser gets full layout' => sub {
    my $app = PAGI::Simple->new(name => 'TestApp');
    $app->views("$tempdir/templates", { cache => 0 });

    my ($send, $responses) = mock_send();
    my $scope = mock_scope(headers => []);  # Browser request
    my $receive = mock_receive();

    my $c = PAGI::Simple::Context->new(
        app     => $app,
        scope   => $scope,
        receive => $receive,
        send    => $send,
    );

    # Render page (has layout)
    $c->render('page', title => 'Hello', message => 'World')->get;

    # Should include layout elements
    my $body = $responses->[1]{body};
    like $body, qr/<!DOCTYPE html>/, 'Browser gets DOCTYPE from layout';
    like $body, qr/<html>/, 'Browser gets html tag from layout';
    like $body, qr/<body>/, 'Browser gets body tag from layout';
    like $body, qr/<h1>Hello<\/h1>/, 'Browser gets content';
};

# ============================================================================
# Test 16: Auto-fragment detection - htmx gets content only (no layout)
# ============================================================================
subtest 'Auto-fragment detection - htmx gets content only' => sub {
    my $app = PAGI::Simple->new(name => 'TestApp');
    $app->views("$tempdir/templates", { cache => 0 });

    my ($send, $responses) = mock_send();
    my $scope = mock_scope(headers => [['HX-Request', 'true']]);  # htmx request
    my $receive = mock_receive();

    my $c = PAGI::Simple::Context->new(
        app     => $app,
        scope   => $scope,
        receive => $receive,
        send    => $send,
    );

    # Render page (has layout, but htmx should skip it)
    $c->render('page', title => 'Hello', message => 'World')->get;

    # Should NOT include layout, just content
    my $body = $responses->[1]{body};
    unlike $body, qr/<!DOCTYPE html>/, 'htmx does NOT get DOCTYPE';
    unlike $body, qr/<html>/, 'htmx does NOT get html tag';
    like $body, qr/<h1>Hello<\/h1>/, 'htmx gets content';
    like $body, qr/<p>World<\/p>/, 'htmx gets content paragraph';
};

# ============================================================================
# Test 17: hx_trigger() returns $c for chaining
# ============================================================================
subtest 'hx_trigger() returns $c for chaining' => sub {
    my $app = PAGI::Simple->new(name => 'TestApp');

    my ($send, $responses) = mock_send();
    my $scope = mock_scope();
    my $receive = mock_receive();

    my $c = PAGI::Simple::Context->new(
        app     => $app,
        scope   => $scope,
        receive => $receive,
        send    => $send,
    );

    # Chain calls
    my $result = $c->hx_trigger('event1')->hx_redirect('/url')->hx_refresh;

    is $result, $c, 'Methods return $c for chaining';

    my @headers = @{$c->response_headers};
    my @trigger = grep { $_->[0] eq 'HX-Trigger' } @headers;
    my @redirect = grep { $_->[0] eq 'HX-Redirect' } @headers;
    my @refresh = grep { $_->[0] eq 'HX-Refresh' } @headers;

    ok @trigger, 'HX-Trigger was set';
    ok @redirect, 'HX-Redirect was set';
    ok @refresh, 'HX-Refresh was set';
};

# ============================================================================
# Test 18: Force layout on for htmx request
# ============================================================================
subtest 'Force layout on for htmx request' => sub {
    my $app = PAGI::Simple->new(name => 'TestApp');
    $app->views("$tempdir/templates", { cache => 0 });

    my ($send, $responses) = mock_send();
    my $scope = mock_scope(headers => [['HX-Request', 'true']]);  # htmx request
    my $receive = mock_receive();

    my $c = PAGI::Simple::Context->new(
        app     => $app,
        scope   => $scope,
        receive => $receive,
        send    => $send,
    );

    # Force layout ON even for htmx (e.g., hx-boost that needs full page)
    $c->render('page', layout => 1, title => 'Forced', message => 'Layout')->get;

    # Should include layout even though htmx
    my $body = $responses->[1]{body};
    like $body, qr/<!DOCTYPE html>/, 'Forced layout includes DOCTYPE';
    like $body, qr/<html>/, 'Forced layout includes html tag';
};

# ============================================================================
# Test 19: Force layout off for browser request
# ============================================================================
subtest 'Force layout off for browser request' => sub {
    my $app = PAGI::Simple->new(name => 'TestApp');
    $app->views("$tempdir/templates", { cache => 0 });

    my ($send, $responses) = mock_send();
    my $scope = mock_scope(headers => []);  # Browser request
    my $receive = mock_receive();

    my $c = PAGI::Simple::Context->new(
        app     => $app,
        scope   => $scope,
        receive => $receive,
        send    => $send,
    );

    # Force layout OFF (e.g., printable view or API-like response)
    $c->render('page', layout => 0, title => 'NoLayout', message => 'Test')->get;

    # Should NOT include layout
    my $body = $responses->[1]{body};
    unlike $body, qr/<!DOCTYPE html>/, 'No layout when forced off';
    unlike $body, qr/<html>/, 'No html tag when layout forced off';
    like $body, qr/<h1>NoLayout<\/h1>/, 'Still has content';
};

# ============================================================================
# Test 20: Boosted htmx request gets full layout (hx-boost navigation)
# ============================================================================
subtest 'Boosted htmx request gets full layout' => sub {
    my $app = PAGI::Simple->new(name => 'TestApp');
    $app->views("$tempdir/templates", { cache => 0 });

    my ($send, $responses) = mock_send();
    # Boosted request has both HX-Request and HX-Boosted headers
    my $scope = mock_scope(headers => [
        ['HX-Request', 'true'],
        ['HX-Boosted', 'true'],
    ]);
    my $receive = mock_receive();

    my $c = PAGI::Simple::Context->new(
        app     => $app,
        scope   => $scope,
        receive => $receive,
        send    => $send,
    );

    # Render page - boosted request should get full layout
    $c->render('page', title => 'Boosted', message => 'Navigation')->get;

    # Should include layout (boosted requests expect full page for body swap)
    my $body = $responses->[1]{body};
    like $body, qr/<!DOCTYPE html>/, 'Boosted htmx gets DOCTYPE';
    like $body, qr/<html>/, 'Boosted htmx gets html tag';
    like $body, qr/<body>/, 'Boosted htmx gets body tag';
    like $body, qr/<h1>Boosted<\/h1>/, 'Boosted htmx gets content';
};

# ============================================================================
# Test 21: Regular htmx request still skips layout
# ============================================================================
subtest 'Regular htmx request still skips layout' => sub {
    my $app = PAGI::Simple->new(name => 'TestApp');
    $app->views("$tempdir/templates", { cache => 0 });

    my ($send, $responses) = mock_send();
    # Regular htmx request (no HX-Boosted header)
    my $scope = mock_scope(headers => [['HX-Request', 'true']]);
    my $receive = mock_receive();

    my $c = PAGI::Simple::Context->new(
        app     => $app,
        scope   => $scope,
        receive => $receive,
        send    => $send,
    );

    # Render page - regular htmx should skip layout
    $c->render('page', title => 'Fragment', message => 'Only')->get;

    # Should NOT include layout
    my $body = $responses->[1]{body};
    unlike $body, qr/<!DOCTYPE html>/, 'Regular htmx does NOT get DOCTYPE';
    unlike $body, qr/<html>/, 'Regular htmx does NOT get html tag';
    like $body, qr/<h1>Fragment<\/h1>/, 'Regular htmx gets content only';
};

done_testing;
