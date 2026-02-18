use strict;
use warnings;
use Test2::V0;
use PAGI::Middleware::RequestId;
use Future::AsyncAwait;

# Test that _generate_id produces valid, unique IDs using secure random

subtest 'generated IDs have correct format' => sub {
    # Access the default generator
    my $mid = PAGI::Middleware::RequestId->new();
    my $generator = $mid->{generator};

    my $id = $generator->(undef);
    like($id, qr/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/,
        'ID matches expected UUID-like hex format');
};

subtest 'generated IDs are unique' => sub {
    my $mid = PAGI::Middleware::RequestId->new();
    my $generator = $mid->{generator};

    my %seen;
    for my $i (1..100) {
        my $id = $generator->(undef);
        ok(!$seen{$id}, "ID $i is unique")
            or diag("Duplicate ID: $id");
        $seen{$id} = 1;
    }
};

subtest 'middleware adds request ID to scope and response' => sub {
    my $mid = PAGI::Middleware::RequestId->new(
        header => 'X-Request-ID',
    );

    my $captured_scope;
    my @response_headers;

    my $inner_app = async sub {
        my ($scope, $receive, $send) = @_;
        $captured_scope = $scope;
        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [['content-type', 'text/plain']],
        });
        await $send->({
            type => 'http.response.body',
            body => 'ok',
            more => 0,
        });
    };

    my $wrapped = $mid->wrap($inner_app);

    my $send = async sub {
        my ($event) = @_;
        if ($event->{type} eq 'http.response.start') {
            @response_headers = @{$event->{headers}};
        }
    };
    my $receive = async sub { return { type => 'http.disconnect' } };
    my $scope = { type => 'http', headers => [] };

    $wrapped->($scope, $receive, $send)->get;

    ok(defined $captured_scope->{request_id}, 'request_id added to scope');
    like($captured_scope->{request_id},
        qr/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/,
        'request_id has correct format');

    my @id_headers = grep { $_->[0] eq 'X-Request-ID' } @response_headers;
    is(scalar @id_headers, 1, 'X-Request-ID header added to response');
    is($id_headers[0][1], $captured_scope->{request_id},
        'response header matches scope request_id');
};

done_testing;
