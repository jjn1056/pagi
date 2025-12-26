#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use Future;

use lib 'lib';
use PAGI::Test::Client;

# Simple echo app that returns request info as JSON
my $echo_app = async sub {
    my ($scope, $receive, $send) = @_;

    if ($scope->{type} eq 'http') {
        require JSON::MaybeXS;

        # Read body
        my $body = '';
        while (1) {
            my $msg = await $receive->();
            last unless $msg && $msg->{type};
            last if $msg->{type} eq 'http.disconnect';
            $body .= $msg->{body} // '';
            last unless $msg->{more};
        }

        my $response = JSON::MaybeXS::encode_json({
            method       => $scope->{method},
            path         => $scope->{path},
            query_string => $scope->{query_string},
            headers      => $scope->{headers},
            body         => $body,
        });

        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [['content-type', 'application/json']],
        });
        await $send->({
            type => 'http.response.body',
            body => $response,
        });
    }
    elsif ($scope->{type} eq 'websocket') {
        my $event = await $receive->();
        return unless $event->{type} eq 'websocket.connect';

        await $send->({ type => 'websocket.accept' });

        # Echo back the headers as JSON
        require JSON::MaybeXS;
        await $send->({
            type => 'websocket.send',
            text => JSON::MaybeXS::encode_json({ headers => $scope->{headers} }),
        });

        # Wait for disconnect
        while (1) {
            my $msg = await $receive->();
            last if $msg->{type} eq 'websocket.disconnect';
        }
    }
    elsif ($scope->{type} eq 'sse') {
        await $send->({
            type    => 'sse.start',
            status  => 200,
            headers => [],
        });

        # Send headers as event
        require JSON::MaybeXS;
        await $send->({
            type  => 'sse.send',
            event => 'headers',
            data  => JSON::MaybeXS::encode_json({ headers => $scope->{headers} }),
        });

        # Wait for disconnect
        while (1) {
            my $msg = await $receive->();
            last if $msg->{type} eq 'sse.disconnect';
        }
    }
};

# Helper to find headers in scope headers array
sub find_headers {
    my ($headers, $name) = @_;
    my @values;
    for my $h (@$headers) {
        push @values, $h->[1] if lc($h->[0]) eq lc($name);
    }
    return @values;
}

subtest 'headers - hash with single values (baseline)' => sub {
    my $client = PAGI::Test::Client->new(app => $echo_app);
    my $res = $client->get('/', headers => { 'X-Custom' => 'value1' });

    my $data = $res->json;
    my @custom = find_headers($data->{headers}, 'x-custom');
    is(\@custom, ['value1'], 'single header value works');
};

subtest 'headers - hash with arrayref values' => sub {
    my $client = PAGI::Test::Client->new(app => $echo_app);
    my $res = $client->get('/', headers => {
        'X-Custom' => ['value1', 'value2', 'value3'],
    });

    my $data = $res->json;
    my @custom = find_headers($data->{headers}, 'x-custom');
    is(\@custom, ['value1', 'value2', 'value3'], 'multiple header values from arrayref');
};

subtest 'headers - arrayref of pairs' => sub {
    my $client = PAGI::Test::Client->new(app => $echo_app);
    my $res = $client->get('/', headers => [
        ['X-Custom', 'first'],
        ['X-Custom', 'second'],
        ['X-Other', 'other-value'],
    ]);

    my $data = $res->json;
    my @custom = find_headers($data->{headers}, 'x-custom');
    my @other = find_headers($data->{headers}, 'x-other');

    is(\@custom, ['first', 'second'], 'multiple values from pairs');
    is(\@other, ['other-value'], 'other header preserved');
};

subtest 'headers - client defaults with multi-value' => sub {
    my $client = PAGI::Test::Client->new(
        app     => $echo_app,
        headers => { Accept => ['application/json', 'text/html'] },
    );
    my $res = $client->get('/');

    my $data = $res->json;
    my @accept = find_headers($data->{headers}, 'accept');
    is(\@accept, ['application/json', 'text/html'], 'client default multi-value headers');
};

subtest 'headers - request replaces client defaults by key' => sub {
    my $client = PAGI::Test::Client->new(
        app     => $echo_app,
        headers => { 'X-Default' => 'default-value', 'X-Keep' => 'kept' },
    );
    my $res = $client->get('/', headers => { 'X-Default' => 'overridden' });

    my $data = $res->json;
    my @default = find_headers($data->{headers}, 'x-default');
    my @keep = find_headers($data->{headers}, 'x-keep');

    is(\@default, ['overridden'], 'request header replaced default');
    is(\@keep, ['kept'], 'other default headers preserved');
};

subtest 'headers - multi-value request replaces multi-value default' => sub {
    my $client = PAGI::Test::Client->new(
        app     => $echo_app,
        headers => { Accept => ['text/plain', 'text/html'] },
    );
    my $res = $client->get('/', headers => {
        Accept => ['application/json', 'application/xml'],
    });

    my $data = $res->json;
    my @accept = find_headers($data->{headers}, 'accept');
    is(\@accept, ['application/json', 'application/xml'], 'request multi-value replaced default multi-value');
};

subtest 'query - hash with single values (baseline)' => sub {
    my $client = PAGI::Test::Client->new(app => $echo_app);
    my $res = $client->get('/search', query => { q => 'perl' });

    my $data = $res->json;
    is($data->{query_string}, 'q=perl', 'single query param works');
};

subtest 'query - hash with arrayref values' => sub {
    my $client = PAGI::Test::Client->new(app => $echo_app);
    my $res = $client->get('/search', query => {
        tag => ['perl', 'async', 'web'],
    });

    my $data = $res->json;
    is($data->{query_string}, 'tag=perl&tag=async&tag=web', 'multiple query values from arrayref');
};

subtest 'query - arrayref of pairs' => sub {
    my $client = PAGI::Test::Client->new(app => $echo_app);
    my $res = $client->get('/search', query => [
        ['tag', 'first'],
        ['tag', 'second'],
        ['limit', '10'],
    ]);

    my $data = $res->json;
    is($data->{query_string}, 'tag=first&tag=second&limit=10', 'query from arrayref of pairs');
};

subtest 'query - appends to path query string' => sub {
    my $client = PAGI::Test::Client->new(app => $echo_app);
    my $res = $client->get('/search?existing=param', query => {
        tag => ['a', 'b'],
    });

    my $data = $res->json;
    is($data->{query_string}, 'existing=param&tag=a&tag=b', 'query appended to path query string');
};

subtest 'form - hash with single values (baseline)' => sub {
    my $client = PAGI::Test::Client->new(app => $echo_app);
    my $res = $client->post('/submit', form => { name => 'John' });

    my $data = $res->json;
    is($data->{body}, 'name=John', 'single form value works');
};

subtest 'form - hash with arrayref values' => sub {
    my $client = PAGI::Test::Client->new(app => $echo_app);
    my $res = $client->post('/submit', form => {
        colors => ['red', 'blue', 'green'],
    });

    my $data = $res->json;
    is($data->{body}, 'colors=red&colors=blue&colors=green', 'multiple form values from arrayref');
};

subtest 'form - arrayref of pairs' => sub {
    my $client = PAGI::Test::Client->new(app => $echo_app);
    my $res = $client->post('/submit', form => [
        ['option', 'a'],
        ['option', 'b'],
        ['name', 'test'],
    ]);

    my $data = $res->json;
    is($data->{body}, 'option=a&option=b&name=test', 'form from arrayref of pairs');
};

subtest 'form - mixed single and multi-value' => sub {
    my $client = PAGI::Test::Client->new(app => $echo_app);
    my $res = $client->post('/submit', form => {
        name   => 'John',
        colors => ['red', 'blue'],
        email  => 'john@example.com',
    });

    my $data = $res->json;
    # Note: keys are sorted, so order is: colors, email, name
    like($data->{body}, qr/colors=red&colors=blue/, 'multi-value field encoded');
    like($data->{body}, qr/name=John/, 'single-value field encoded');
    like($data->{body}, qr/email=john%40example\.com/, 'another single-value field encoded');
};

subtest 'websocket - with custom headers' => sub {
    my $client = PAGI::Test::Client->new(app => $echo_app);

    $client->websocket('/ws', headers => { 'X-Auth' => 'token123' }, sub {
        my ($ws) = @_;
        my $text = $ws->receive_text;
        require JSON::MaybeXS;
        my $data = JSON::MaybeXS::decode_json($text);

        my @auth = find_headers($data->{headers}, 'x-auth');
        is(\@auth, ['token123'], 'websocket received custom header');
    });
};

subtest 'websocket - with multi-value headers' => sub {
    my $client = PAGI::Test::Client->new(app => $echo_app);

    $client->websocket('/ws', headers => { 'X-Custom' => ['a', 'b'] }, sub {
        my ($ws) = @_;
        my $text = $ws->receive_text;
        require JSON::MaybeXS;
        my $data = JSON::MaybeXS::decode_json($text);

        my @custom = find_headers($data->{headers}, 'x-custom');
        is(\@custom, ['a', 'b'], 'websocket received multi-value headers');
    });
};

subtest 'sse - with custom headers' => sub {
    my $client = PAGI::Test::Client->new(app => $echo_app);

    $client->sse('/events', headers => { 'Last-Event-ID' => '42' }, sub {
        my ($sse) = @_;
        my $event = $sse->receive_event;

        require JSON::MaybeXS;
        my $data = JSON::MaybeXS::decode_json($event->{data});

        my @last_id = find_headers($data->{headers}, 'last-event-id');
        is(\@last_id, ['42'], 'sse received custom header');
    });
};

subtest 'sse - with multi-value headers' => sub {
    my $client = PAGI::Test::Client->new(app => $echo_app);

    $client->sse('/events', headers => { 'X-Tags' => ['tag1', 'tag2'] }, sub {
        my ($sse) = @_;
        my $event = $sse->receive_event;

        require JSON::MaybeXS;
        my $data = JSON::MaybeXS::decode_json($event->{data});

        my @tags = find_headers($data->{headers}, 'x-tags');
        is(\@tags, ['tag1', 'tag2'], 'sse received multi-value headers');
    });
};

# Regression test: headers as arrayref with form should not crash
subtest 'form with headers as arrayref of pairs' => sub {
    my $client = PAGI::Test::Client->new(app => $echo_app);
    my $res = $client->post('/submit',
        headers => [['X-Custom', 'value1'], ['X-Other', 'value2']],
        form => { name => 'John' },
    );

    my $data = $res->json;
    is($data->{body}, 'name=John', 'form body encoded correctly');
    my @custom = find_headers($data->{headers}, 'x-custom');
    my @other = find_headers($data->{headers}, 'x-other');
    is(\@custom, ['value1'], 'custom header preserved');
    is(\@other, ['value2'], 'other header preserved');
    # Content-Type should be added
    my @ct = find_headers($data->{headers}, 'content-type');
    is(\@ct, ['application/x-www-form-urlencoded'], 'content-type header added');
};

# Regression test: headers as arrayref with json should not crash
subtest 'json with headers as arrayref of pairs' => sub {
    my $client = PAGI::Test::Client->new(app => $echo_app);
    my $res = $client->post('/api',
        headers => [['X-Auth', 'token123']],
        json => { key => 'value' },
    );

    my $data = $res->json;
    my @auth = find_headers($data->{headers}, 'x-auth');
    is(\@auth, ['token123'], 'auth header preserved');
    my @ct = find_headers($data->{headers}, 'content-type');
    is(\@ct, ['application/json'], 'content-type header added');
};

subtest 'invalid input - not hash or arrayref' => sub {
    my $client = PAGI::Test::Client->new(app => $echo_app);

    like(
        dies { $client->get('/', headers => 'invalid') },
        qr/Expected hashref or arrayref/,
        'dies with invalid headers type'
    );
};

subtest 'invalid input - malformed pairs' => sub {
    my $client = PAGI::Test::Client->new(app => $echo_app);

    like(
        dies { $client->get('/', headers => [['only-one-element']]) },
        qr/Expected arrayref of \[key, value\] pairs/,
        'dies with malformed pairs'
    );
};

done_testing;
