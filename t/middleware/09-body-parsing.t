#!/usr/bin/env perl
use strict;
use warnings;
use experimental 'signatures';
use Test2::V0;
use Future::AsyncAwait;
use IO::Async::Loop;
use JSON::PP;

use PAGI::Middleware::JSONBody;
use PAGI::Middleware::FormBody;
use PAGI::Middleware::ContentNegotiation;

my $loop = IO::Async::Loop->new;

# Helper to create HTTP scope
sub make_scope {
    my (%opts) = @_;
    return {
        type    => 'http',
        method  => $opts{method} // 'POST',
        path    => '/',
        headers => $opts{headers} // [],
    };
}

# Helper to run async tests
sub run_async :prototype(&) {
    my ($code) = @_;
    $loop->await($code->());
}

# ===================
# JSONBody Middleware Tests
# ===================

subtest 'JSONBody - parses valid JSON' => sub {
    my $json_mw = PAGI::Middleware::JSONBody->new();

    my $captured_scope;
    my $app = async sub ($scope, $receive, $send) {
        $captured_scope = $scope;
        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [['Content-Type', 'text/plain']],
        });
        await $send->({
            type => 'http.response.body',
            body => 'OK',
            more => 0,
        });
    };

    my $wrapped = $json_mw->wrap($app);
    my $scope = make_scope(headers => [['Content-Type', 'application/json']]);

    my $json_body = '{"name":"John","age":30}';
    my $body_sent = 0;
    my $receive = async sub {
        return { type => 'http.disconnect' } if $body_sent;
        $body_sent = 1;
        return { type => 'http.request', body => $json_body, more => 0 };
    };

    my @events;
    my $send = async sub ($event) { push @events, $event };

    run_async { $wrapped->($scope, $receive, $send) };

    ok exists $captured_scope->{'pagi.parsed_body'}, 'has parsed body';
    is $captured_scope->{'pagi.parsed_body'}{name}, 'John', 'name parsed correctly';
    is $captured_scope->{'pagi.parsed_body'}{age}, 30, 'age parsed correctly';
    is $captured_scope->{'pagi.raw_body'}, $json_body, 'raw body preserved';
};

subtest 'JSONBody - returns 400 for invalid JSON' => sub {
    my $json_mw = PAGI::Middleware::JSONBody->new();

    my $app = async sub ($scope, $receive, $send) {
        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [],
        });
        await $send->({
            type => 'http.response.body',
            body => 'OK',
            more => 0,
        });
    };

    my $wrapped = $json_mw->wrap($app);
    my $scope = make_scope(headers => [['Content-Type', 'application/json']]);

    my $body_sent = 0;
    my $receive = async sub {
        return { type => 'http.disconnect' } if $body_sent;
        $body_sent = 1;
        return { type => 'http.request', body => 'not valid json', more => 0 };
    };

    my @events;
    my $send = async sub ($event) { push @events, $event };

    run_async { $wrapped->($scope, $receive, $send) };

    is $events[0]{status}, 400, 'returns 400 for invalid JSON';
};

subtest 'JSONBody - returns 413 for large body' => sub {
    my $json_mw = PAGI::Middleware::JSONBody->new(max_size => 100);

    my $app = async sub ($scope, $receive, $send) {
        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [],
        });
        await $send->({
            type => 'http.response.body',
            body => 'OK',
            more => 0,
        });
    };

    my $wrapped = $json_mw->wrap($app);
    my $scope = make_scope(headers => [['Content-Type', 'application/json']]);

    my $body_sent = 0;
    my $receive = async sub {
        return { type => 'http.disconnect' } if $body_sent;
        $body_sent = 1;
        return { type => 'http.request', body => '{"data":"' . ('x' x 200) . '"}', more => 0 };
    };

    my @events;
    my $send = async sub ($event) { push @events, $event };

    run_async { $wrapped->($scope, $receive, $send) };

    is $events[0]{status}, 413, 'returns 413 for large body';
};

subtest 'JSONBody - skips non-JSON content types' => sub {
    my $json_mw = PAGI::Middleware::JSONBody->new();

    my $captured_scope;
    my $app = async sub ($scope, $receive, $send) {
        $captured_scope = $scope;
        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [],
        });
        await $send->({
            type => 'http.response.body',
            body => 'OK',
            more => 0,
        });
    };

    my $wrapped = $json_mw->wrap($app);
    my $scope = make_scope(headers => [['Content-Type', 'text/plain']]);

    my $receive = async sub { { type => 'http.request', body => 'plain text', more => 0 } };
    my $send = async sub { };

    run_async { $wrapped->($scope, $receive, $send) };

    ok !exists $captured_scope->{'pagi.parsed_body'}, 'no parsed body for non-JSON';
};

subtest 'JSONBody - handles application/XXX+json' => sub {
    my $json_mw = PAGI::Middleware::JSONBody->new();

    my $captured_scope;
    my $app = async sub ($scope, $receive, $send) {
        $captured_scope = $scope;
        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [],
        });
        await $send->({
            type => 'http.response.body',
            body => 'OK',
            more => 0,
        });
    };

    my $wrapped = $json_mw->wrap($app);
    my $scope = make_scope(headers => [['Content-Type', 'application/vnd.api+json']]);

    my $body_sent = 0;
    my $receive = async sub {
        return { type => 'http.disconnect' } if $body_sent;
        $body_sent = 1;
        return { type => 'http.request', body => '{"api":"data"}', more => 0 };
    };
    my $send = async sub { };

    run_async { $wrapped->($scope, $receive, $send) };

    ok exists $captured_scope->{'pagi.parsed_body'}, 'parses +json media types';
    is $captured_scope->{'pagi.parsed_body'}{api}, 'data', 'data parsed correctly';
};

# ===================
# FormBody Middleware Tests
# ===================

subtest 'FormBody - parses URL-encoded form' => sub {
    my $form_mw = PAGI::Middleware::FormBody->new();

    my $captured_scope;
    my $app = async sub ($scope, $receive, $send) {
        $captured_scope = $scope;
        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [],
        });
        await $send->({
            type => 'http.response.body',
            body => 'OK',
            more => 0,
        });
    };

    my $wrapped = $form_mw->wrap($app);
    my $scope = make_scope(headers => [['Content-Type', 'application/x-www-form-urlencoded']]);

    my $body_sent = 0;
    my $receive = async sub {
        return { type => 'http.disconnect' } if $body_sent;
        $body_sent = 1;
        return { type => 'http.request', body => 'name=John&age=30&city=New+York', more => 0 };
    };

    my $send = async sub { };

    run_async { $wrapped->($scope, $receive, $send) };

    ok exists $captured_scope->{'pagi.parsed_body'}, 'has parsed body';
    is $captured_scope->{'pagi.parsed_body'}{name}, 'John', 'name parsed';
    is $captured_scope->{'pagi.parsed_body'}{age}, '30', 'age parsed';
    is $captured_scope->{'pagi.parsed_body'}{city}, 'New York', 'space decoded';
};

subtest 'FormBody - handles URL encoding' => sub {
    my $form_mw = PAGI::Middleware::FormBody->new();

    my $captured_scope;
    my $app = async sub ($scope, $receive, $send) {
        $captured_scope = $scope;
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
    };

    my $wrapped = $form_mw->wrap($app);
    my $scope = make_scope(headers => [['Content-Type', 'application/x-www-form-urlencoded']]);

    my $body_sent = 0;
    my $receive = async sub {
        return { type => 'http.disconnect' } if $body_sent;
        $body_sent = 1;
        return { type => 'http.request', body => 'email=test%40example.com&q=%3Cfoo%3E', more => 0 };
    };
    my $send = async sub { };

    run_async { $wrapped->($scope, $receive, $send) };

    is $captured_scope->{'pagi.parsed_body'}{email}, 'test@example.com', '@ decoded';
    is $captured_scope->{'pagi.parsed_body'}{q}, '<foo>', 'angle brackets decoded';
};

subtest 'FormBody - handles multiple values for same key' => sub {
    my $form_mw = PAGI::Middleware::FormBody->new();

    my $captured_scope;
    my $app = async sub ($scope, $receive, $send) {
        $captured_scope = $scope;
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
    };

    my $wrapped = $form_mw->wrap($app);
    my $scope = make_scope(headers => [['Content-Type', 'application/x-www-form-urlencoded']]);

    my $body_sent = 0;
    my $receive = async sub {
        return { type => 'http.disconnect' } if $body_sent;
        $body_sent = 1;
        return { type => 'http.request', body => 'color=red&color=green&color=blue', more => 0 };
    };
    my $send = async sub { };

    run_async { $wrapped->($scope, $receive, $send) };

    is ref($captured_scope->{'pagi.parsed_body'}{color}), 'ARRAY', 'multiple values as array';
    is $captured_scope->{'pagi.parsed_body'}{color}, ['red', 'green', 'blue'], 'all values present';
};

subtest 'FormBody - skips non-form content types' => sub {
    my $form_mw = PAGI::Middleware::FormBody->new();

    my $captured_scope;
    my $app = async sub ($scope, $receive, $send) {
        $captured_scope = $scope;
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
    };

    my $wrapped = $form_mw->wrap($app);
    my $scope = make_scope(headers => [['Content-Type', 'application/json']]);

    my $receive = async sub { { type => 'http.request', body => '{"data":1}', more => 0 } };
    my $send = async sub { };

    run_async { $wrapped->($scope, $receive, $send) };

    ok !exists $captured_scope->{'pagi.parsed_body'}, 'no parsed body for JSON content type';
};

# ===================
# ContentNegotiation Middleware Tests
# ===================

subtest 'ContentNegotiation - selects preferred type' => sub {
    my $content_neg = PAGI::Middleware::ContentNegotiation->new(
        supported_types => ['application/json', 'text/html', 'text/plain'],
    );

    my $captured_scope;
    my $app = async sub ($scope, $receive, $send) {
        $captured_scope = $scope;
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
    };

    my $wrapped = $content_neg->wrap($app);
    my $scope = make_scope(
        method  => 'GET',
        headers => [['Accept', 'text/html, application/json;q=0.9']]
    );

    my $receive = async sub { {} };
    my $send = async sub { };

    run_async { $wrapped->($scope, $receive, $send) };

    is $captured_scope->{'pagi.preferred_content_type'}, 'text/html', 'selects highest q value';
};

subtest 'ContentNegotiation - handles wildcard' => sub {
    my $content_neg = PAGI::Middleware::ContentNegotiation->new(
        supported_types => ['application/json', 'text/html'],
    );

    my $captured_scope;
    my $app = async sub ($scope, $receive, $send) {
        $captured_scope = $scope;
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
    };

    my $wrapped = $content_neg->wrap($app);
    my $scope = make_scope(
        method  => 'GET',
        headers => [['Accept', '*/*']]
    );

    my $receive = async sub { {} };
    my $send = async sub { };

    run_async { $wrapped->($scope, $receive, $send) };

    is $captured_scope->{'pagi.preferred_content_type'}, 'application/json', 'wildcard matches first supported';
};

subtest 'ContentNegotiation - handles type wildcard' => sub {
    my $content_neg = PAGI::Middleware::ContentNegotiation->new(
        supported_types => ['application/json', 'text/html'],
    );

    my $captured_scope;
    my $app = async sub ($scope, $receive, $send) {
        $captured_scope = $scope;
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
    };

    my $wrapped = $content_neg->wrap($app);
    my $scope = make_scope(
        method  => 'GET',
        headers => [['Accept', 'text/*']]
    );

    my $receive = async sub { {} };
    my $send = async sub { };

    run_async { $wrapped->($scope, $receive, $send) };

    is $captured_scope->{'pagi.preferred_content_type'}, 'text/html', 'text/* matches text/html';
};

subtest 'ContentNegotiation - uses default when no match' => sub {
    my $content_neg = PAGI::Middleware::ContentNegotiation->new(
        supported_types => ['application/json', 'text/html'],
        default_type    => 'text/plain',
    );

    my $captured_scope;
    my $app = async sub ($scope, $receive, $send) {
        $captured_scope = $scope;
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
    };

    my $wrapped = $content_neg->wrap($app);
    my $scope = make_scope(
        method  => 'GET',
        headers => [['Accept', 'application/xml']]  # Not supported
    );

    my $receive = async sub { {} };
    my $send = async sub { };

    run_async { $wrapped->($scope, $receive, $send) };

    is $captured_scope->{'pagi.preferred_content_type'}, 'text/plain', 'uses default type';
};

subtest 'ContentNegotiation - strict mode returns 406' => sub {
    my $content_neg = PAGI::Middleware::ContentNegotiation->new(
        supported_types => ['application/json', 'text/html'],
        strict          => 1,
    );

    my $app = async sub ($scope, $receive, $send) {
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
    };

    my $wrapped = $content_neg->wrap($app);
    my $scope = make_scope(
        method  => 'GET',
        headers => [['Accept', 'application/xml']]  # Not supported
    );

    my @events;
    my $receive = async sub { {} };
    my $send = async sub ($event) { push @events, $event };

    run_async { $wrapped->($scope, $receive, $send) };

    is $events[0]{status}, 406, 'returns 406 Not Acceptable in strict mode';
};

subtest 'ContentNegotiation - handles no Accept header' => sub {
    my $content_neg = PAGI::Middleware::ContentNegotiation->new(
        supported_types => ['application/json', 'text/html'],
    );

    my $captured_scope;
    my $app = async sub ($scope, $receive, $send) {
        $captured_scope = $scope;
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
    };

    my $wrapped = $content_neg->wrap($app);
    my $scope = make_scope(method => 'GET', headers => []);

    my $receive = async sub { {} };
    my $send = async sub { };

    run_async { $wrapped->($scope, $receive, $send) };

    is $captured_scope->{'pagi.preferred_content_type'}, 'application/json', 'uses first supported when no Accept';
};

done_testing;
