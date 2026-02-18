use strict;
use warnings;
use Test2::V0;
use PAGI::Middleware::Debug;
use Future::AsyncAwait;

# Test that scope values are HTML-escaped in the debug panel

my $debug = PAGI::Middleware::Debug->new(
    enabled     => 1,
    show_scope  => 1,
    show_headers => 0,
    show_timing  => 0,
);

# Build a scope with XSS payloads in every scope value
my $xss = '<script>alert("xss")</script>';
my $scope = {
    type         => 'http',
    method       => $xss,
    path         => $xss,
    query_string => $xss,
    scheme       => $xss,
    headers      => [],
};

# Capture the response body from the debug panel
my $captured_body;

my $inner_app = async sub {
    my ($scope, $receive, $send) = @_;
    await $send->({
        type    => 'http.response.start',
        status  => 200,
        headers => [['content-type', 'text/html']],
    });
    await $send->({
        type => 'http.response.body',
        body => '<html><body>Hello</body></html>',
        more => 0,
    });
};

my $wrapped = $debug->wrap($inner_app);

my $send = async sub {
    my ($event) = @_;
    if ($event->{type} eq 'http.response.body') {
        $captured_body = $event->{body};
    }
};

my $receive = async sub { return { type => 'http.disconnect' } };

# Run the middleware
$wrapped->($scope, $receive, $send)->get;

# The raw XSS string must NOT appear in the output
unlike($captured_body, qr/<script>alert/, 'no raw script tags in debug panel output');

# The escaped version MUST appear
like($captured_body, qr/&lt;script&gt;alert/, 'XSS payload is HTML-escaped in debug panel');

# Verify each field individually
like($captured_body, qr{<th>Method</th><td>&lt;script&gt;}, 'method field is escaped');
like($captured_body, qr{<th>Path</th><td>&lt;script&gt;}, 'path field is escaped');
like($captured_body, qr{<th>Query</th><td>&lt;script&gt;}, 'query field is escaped');
like($captured_body, qr{<th>Scheme</th><td>&lt;script&gt;}, 'scheme field is escaped');

done_testing;
