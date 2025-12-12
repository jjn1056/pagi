#!/usr/bin/env perl

use strict;
use warnings;
use experimental 'signatures';
use Test2::V0;
use Future;
use Future::AsyncAwait;

use lib 'lib';
use PAGI::Simple::Context;

# Helper to create a mock receive that returns body chunks
sub mock_receive (@chunks) {
    my @events = map { { type => 'http.request', body => $_, more => 1 } } @chunks;
    push @events, { type => 'http.request', body => '', more => 0 };

    return sub {
        my $event = shift @events // { type => 'http.disconnect' };
        return Future->done($event);
    };
}

# Helper to create a Context with body data
sub make_context (%args) {
    my $body = delete $args{body} // '';
    my $query_string = delete $args{query_string} // '';
    my $content_type = delete $args{content_type} // 'application/x-www-form-urlencoded';

    my $receive = mock_receive($body);
    my $scope = {
        type => 'http',
        method => 'POST',
        path => '/test',
        query_string => $query_string,
        headers => [['content-type', $content_type]],
    };

    return PAGI::Simple::Context->new(
        scope   => $scope,
        receive => $receive,
        send    => sub { Future->done },
    );
}

# ============================================================================
# STRUCTURED_BODY TESTS
# ============================================================================

subtest 'structured_body returns StructuredParams object' => sub {
    my $c = make_context(body => 'name=John');

    my $sp;
    (async sub {
        $sp = await $c->structured_body;
    })->()->get;

    isa_ok $sp, 'PAGI::Simple::StructuredParams';
};

subtest 'structured_body parses form data' => sub {
    my $c = make_context(body => 'name=John&email=john%40example.com');

    my $result;
    (async sub {
        $result = (await $c->structured_body)->to_hash;
    })->()->get;

    is $result, { name => 'John', email => 'john@example.com' }, 'body parsed';
};

subtest 'structured_body with namespace' => sub {
    my $c = make_context(body => 'order.name=Widget&order.qty=5&other=ignored');

    my $result;
    (async sub {
        $result = (await $c->structured_body)->namespace('order')->to_hash;
    })->()->get;

    is $result, { name => 'Widget', qty => 5 }, 'namespace filtering works';
};

subtest 'structured_body with permitted' => sub {
    my $c = make_context(body => 'name=John&email=john%40example.com&password=secret');

    my $result;
    (async sub {
        $result = (await $c->structured_body)->permitted('name', 'email')->to_hash;
    })->()->get;

    is $result, { name => 'John', email => 'john@example.com' }, 'permitted filtering works';
    ok !exists $result->{password}, 'unpermitted field excluded';
};

subtest 'structured_body full chain' => sub {
    my $body = join('&',
        'order.customer=John',
        'order.items%5B0%5D.product=Widget',
        'order.items%5B0%5D.qty=5',
        'order.items%5B0%5D._destroy=0',
        'order.items%5B1%5D.product=Gadget',
        'order.items%5B1%5D.qty=3',
        'order.items%5B1%5D._destroy=1',  # Should be removed
        'order.secret=hidden',
    );

    my $c = make_context(body => $body);

    my $result;
    (async sub {
        $result = (await $c->structured_body)
            ->namespace('order')
            ->permitted('customer', +{items => ['product', 'qty', '_destroy']})
            ->skip('_destroy')
            ->to_hash;
    })->()->get;

    is $result->{customer}, 'John', 'scalar field';
    is scalar(@{$result->{items}}), 1, 'one item kept (other destroyed)';
    is $result->{items}[0]{product}, 'Widget', 'kept item correct';
    ok !exists $result->{items}[0]{_destroy}, '_destroy field removed';
    ok !exists $result->{secret}, 'unpermitted field excluded';
};

# ============================================================================
# STRUCTURED_QUERY TESTS
# ============================================================================

subtest 'structured_query returns StructuredParams object' => sub {
    my $c = make_context(query_string => 'page=1');

    my $sp = $c->structured_query;
    isa_ok $sp, 'PAGI::Simple::StructuredParams';
};

subtest 'structured_query parses query string' => sub {
    my $c = make_context(query_string => 'page=2&per_page=20');

    my $result = $c->structured_query->to_hash;
    is $result, { page => 2, per_page => 20 }, 'query parsed';
};

subtest 'structured_query with permitted' => sub {
    my $c = make_context(query_string => 'page=2&per_page=20&admin=true');

    my $result = $c->structured_query->permitted('page', 'per_page')->to_hash;
    is $result, { page => 2, per_page => 20 }, 'permitted filtering works';
    ok !exists $result->{admin}, 'unpermitted field excluded';
};

subtest 'structured_query is synchronous' => sub {
    my $c = make_context(query_string => 'name=John');

    # No await needed - this is sync
    my $sp = $c->structured_query;
    my $result = $sp->to_hash;

    is $result, { name => 'John' }, 'sync access works';
};

# ============================================================================
# STRUCTURED_DATA TESTS
# ============================================================================

subtest 'structured_data returns StructuredParams object' => sub {
    my $c = make_context(
        body => 'from=body',
        query_string => 'from=query',
    );

    my $sp;
    (async sub {
        $sp = await $c->structured_data;
    })->()->get;

    isa_ok $sp, 'PAGI::Simple::StructuredParams';
};

subtest 'structured_data merges body and query (body wins)' => sub {
    my $c = make_context(
        body => 'shared=from_body&body_only=yes',
        query_string => 'shared=from_query&query_only=yes',
    );

    my $result;
    (async sub {
        $result = (await $c->structured_data)->to_hash;
    })->()->get;

    is $result->{shared}, 'from_body', 'body takes precedence';
    is $result->{query_only}, 'yes', 'query-only field present';
    is $result->{body_only}, 'yes', 'body-only field present';
};

subtest 'structured_data with full chain' => sub {
    my $c = make_context(
        query_string => 'q=widgets&page=1',
        body => 'filters.category=electronics&filters.price_min=10&secret=hidden',
    );

    my $result;
    (async sub {
        $result = (await $c->structured_data)
            ->permitted('q', 'page', 'filters', ['category', 'price_min'])
            ->to_hash;
    })->()->get;

    is $result->{q}, 'widgets', 'query param';
    is $result->{page}, 1, 'page param';
    is $result->{filters}{category}, 'electronics', 'nested body param';
    is $result->{filters}{price_min}, 10, 'nested body param 2';
    ok !exists $result->{secret}, 'unpermitted excluded';
};

# ============================================================================
# EDGE CASES
# ============================================================================

subtest 'structured_body with empty body' => sub {
    my $c = make_context(body => '');

    my $result;
    (async sub {
        $result = (await $c->structured_body)->to_hash;
    })->()->get;

    is $result, {}, 'empty body = empty hash';
};

subtest 'structured_query with empty query' => sub {
    my $c = make_context(query_string => '');

    my $result = $c->structured_query->to_hash;
    is $result, {}, 'empty query = empty hash';
};

done_testing;
