use strict;
use warnings;
use v5.32;
use feature 'signatures';
no warnings 'experimental::signatures';
use Test2::V0;
use Future;

use PAGI::Response;

subtest 'constructor' => sub {
    my $send = sub { Future->done };
    my $res = PAGI::Response->new($send);
    isa_ok $res, 'PAGI::Response';
};

subtest 'constructor requires send' => sub {
    like dies { PAGI::Response->new() }, qr/send.*required/i, 'dies without send';
};

subtest 'constructor requires coderef' => sub {
    like dies { PAGI::Response->new("not a coderef") },
         qr/coderef/i, 'dies with non-coderef';
};

subtest 'status method' => sub {
    my $send = sub { Future->done };
    my $res = PAGI::Response->new($send);

    my $ret = $res->status(404);
    is $ret, $res, 'status returns self for chaining';
};

subtest 'header method' => sub {
    my $send = sub { Future->done };
    my $res = PAGI::Response->new($send);

    my $ret = $res->header('X-Custom' => 'value');
    is $ret, $res, 'header returns self for chaining';
};

subtest 'content_type method' => sub {
    my $send = sub { Future->done };
    my $res = PAGI::Response->new($send);

    my $ret = $res->content_type('application/xml');
    is $ret, $res, 'content_type returns self for chaining';
};

subtest 'chaining multiple methods' => sub {
    my $send = sub { Future->done };
    my $res = PAGI::Response->new($send);

    my $ret = $res->status(201)->header('X-Foo' => 'bar')->content_type('text/plain');
    is $ret, $res, 'chaining works';
};

subtest 'status sets internal state' => sub {
    my $send = sub { Future->done };
    my $res = PAGI::Response->new($send);
    $res->status(404);
    is $res->{_status}, 404, 'status code set correctly';
};

subtest 'header adds to headers array' => sub {
    my $send = sub { Future->done };
    my $res = PAGI::Response->new($send);
    $res->header('X-Custom' => 'value1');
    $res->header('X-Other' => 'value2');
    is scalar(@{$res->{_headers}}), 2, 'two headers added';
};

subtest 'content_type replaces existing' => sub {
    my $send = sub { Future->done };
    my $res = PAGI::Response->new($send);
    $res->header('Content-Type' => 'text/html');
    $res->content_type('text/plain');
    my @ct = grep { lc($_->[0]) eq 'content-type' } @{$res->{_headers}};
    is scalar(@ct), 1, 'only one content-type header';
    is $ct[0][1], 'text/plain', 'content-type replaced';
};

subtest 'status rejects invalid codes' => sub {
    my $send = sub { Future->done };
    my $res = PAGI::Response->new($send);
    like dies { $res->status("not a number") }, qr/number/i, 'rejects non-number';
    like dies { $res->status(99) }, qr/100-599/i, 'rejects < 100';
    like dies { $res->status(600) }, qr/100-599/i, 'rejects > 599';
};

subtest 'send method' => sub {
    my @sent;
    my $send = sub ($msg) { push @sent, $msg; Future->done };
    my $res = PAGI::Response->new($send);

    $res->status(200)->header('x-test' => 'value');
    $res->send("Hello")->get;

    is scalar(@sent), 2, 'two messages sent';
    is $sent[0]->{type}, 'http.response.start', 'first is start';
    is $sent[0]->{status}, 200, 'status correct';
    is $sent[1]->{type}, 'http.response.body', 'second is body';
    is $sent[1]->{body}, 'Hello', 'body correct';
    is $sent[1]->{more}, 0, 'more is false';
};

subtest 'send_utf8 method' => sub {
    my @sent;
    my $send = sub ($msg) { push @sent, $msg; Future->done };
    my $res = PAGI::Response->new($send);

    $res->send_utf8("café")->get;

    # Should be UTF-8 encoded bytes
    is $sent[1]->{body}, "caf\xc3\xa9", 'UTF-8 encoded';

    # Should have charset in content-type
    my %headers = map { lc($_->[0]) => $_->[1] } @{$sent[0]->{headers}};
    like $headers{'content-type'}, qr/charset=utf-8/i, 'charset added';
};

subtest 'cannot send twice' => sub {
    my $send = sub { Future->done };
    my $res = PAGI::Response->new($send);

    $res->send("first")->get;
    like dies { $res->send("second")->get }, qr/already sent/i, 'dies on second send';
};

done_testing;
