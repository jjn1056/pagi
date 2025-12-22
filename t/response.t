use strict;
use warnings;
use v5.32;
use feature 'signatures';
no warnings 'experimental::signatures';
use Test2::V0;
use Future;
use Future::AsyncAwait;

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

subtest 'text method' => sub {
    my @sent;
    my $send = sub ($msg) { push @sent, $msg; Future->done };
    my $res = PAGI::Response->new($send);

    $res->text("Hello World")->get;

    my %headers = map { lc($_->[0]) => $_->[1] } @{$sent[0]->{headers}};
    is $headers{'content-type'}, 'text/plain; charset=utf-8', 'content-type set';
    is $sent[0]->{status}, 200, 'default status 200';
};

subtest 'html method' => sub {
    my @sent;
    my $send = sub ($msg) { push @sent, $msg; Future->done };
    my $res = PAGI::Response->new($send);

    $res->html("<h1>Hello</h1>")->get;

    my %headers = map { lc($_->[0]) => $_->[1] } @{$sent[0]->{headers}};
    is $headers{'content-type'}, 'text/html; charset=utf-8', 'content-type set';
};

subtest 'json method' => sub {
    my @sent;
    my $send = sub ($msg) { push @sent, $msg; Future->done };
    my $res = PAGI::Response->new($send);

    $res->json({ message => 'Hello', count => 42 })->get;

    my %headers = map { lc($_->[0]) => $_->[1] } @{$sent[0]->{headers}};
    is $headers{'content-type'}, 'application/json; charset=utf-8', 'content-type set';

    # Body should be valid JSON
    like $sent[1]->{body}, qr/"message"/, 'contains message key';
    like $sent[1]->{body}, qr/"count"/, 'contains count key';
};

subtest 'json with status' => sub {
    my @sent;
    my $send = sub ($msg) { push @sent, $msg; Future->done };
    my $res = PAGI::Response->new($send);

    $res->status(201)->json({ created => 1 })->get;

    is $sent[0]->{status}, 201, 'custom status preserved';
};

subtest 'json with unicode' => sub {
    my @sent;
    my $send = sub ($msg) { push @sent, $msg; Future->done };
    my $res = PAGI::Response->new($send);

    $res->json({ message => 'café', count => 42 })->get;

    # Verify JSON is decodable and unicode is preserved
    # Body is UTF-8 bytes, so decode with utf8 => 1
    my $decoded = JSON::MaybeXS->new(utf8 => 1)->decode($sent[1]->{body});
    is $decoded->{message}, 'café', 'unicode character preserved';
    is $decoded->{count}, 42, 'number preserved';
};

subtest 'redirect method default 302' => sub {
    my @sent;
    my $send = sub ($msg) { push @sent, $msg; Future->done };
    my $res = PAGI::Response->new($send);

    $res->redirect('/login')->get;

    is $sent[0]->{status}, 302, 'default status 302';
    my %headers = map { lc($_->[0]) => $_->[1] } @{$sent[0]->{headers}};
    is $headers{'location'}, '/login', 'location header set';
};

subtest 'redirect with custom status' => sub {
    my @sent;
    my $send = sub ($msg) { push @sent, $msg; Future->done };
    my $res = PAGI::Response->new($send);

    $res->redirect('/permanent', 301)->get;

    is $sent[0]->{status}, 301, 'custom status 301';
};

subtest 'redirect 303 See Other' => sub {
    my @sent;
    my $send = sub ($msg) { push @sent, $msg; Future->done };
    my $res = PAGI::Response->new($send);

    $res->redirect('/result', 303)->get;

    is $sent[0]->{status}, 303, 'status 303';
};

subtest 'empty method' => sub {
    my @sent;
    my $send = sub ($msg) { push @sent, $msg; Future->done };
    my $res = PAGI::Response->new($send);

    $res->empty()->get;

    is $sent[0]->{status}, 204, 'default status 204';
    is $sent[1]->{body}, undef, 'no body';
};

subtest 'empty with custom status' => sub {
    my @sent;
    my $send = sub ($msg) { push @sent, $msg; Future->done };
    my $res = PAGI::Response->new($send);

    $res->status(201)->empty()->get;

    is $sent[0]->{status}, 201, 'custom status preserved';
};

subtest 'cookie method basic' => sub {
    my @sent;
    my $send = sub ($msg) { push @sent, $msg; Future->done };
    my $res = PAGI::Response->new($send);

    my $ret = $res->cookie('session' => 'abc123');
    is $ret, $res, 'cookie returns self for chaining';

    $res->text("ok")->get;

    my @cookies = grep { lc($_->[0]) eq 'set-cookie' } @{$sent[0]->{headers}};
    is scalar(@cookies), 1, 'one set-cookie header';
    like $cookies[0][1], qr/session=abc123/, 'cookie name=value';
};

subtest 'cookie with options' => sub {
    my @sent;
    my $send = sub ($msg) { push @sent, $msg; Future->done };
    my $res = PAGI::Response->new($send);

    $res->cookie('token' => 'xyz',
        max_age  => 3600,
        path     => '/',
        domain   => 'example.com',
        secure   => 1,
        httponly => 1,
        samesite => 'Strict',
    );
    $res->text("ok")->get;

    my @cookies = grep { lc($_->[0]) eq 'set-cookie' } @{$sent[0]->{headers}};
    my $cookie = $cookies[0][1];

    like $cookie, qr/token=xyz/, 'name=value';
    like $cookie, qr/Max-Age=3600/i, 'max-age';
    like $cookie, qr/Path=\//i, 'path';
    like $cookie, qr/Domain=example\.com/i, 'domain';
    like $cookie, qr/Secure/i, 'secure';
    like $cookie, qr/HttpOnly/i, 'httponly';
    like $cookie, qr/SameSite=Strict/i, 'samesite';
};

subtest 'delete_cookie' => sub {
    my @sent;
    my $send = sub ($msg) { push @sent, $msg; Future->done };
    my $res = PAGI::Response->new($send);

    my $ret = $res->delete_cookie('session');
    is $ret, $res, 'delete_cookie returns self';

    $res->text("ok")->get;

    my @cookies = grep { lc($_->[0]) eq 'set-cookie' } @{$sent[0]->{headers}};
    my $cookie = $cookies[0][1];

    like $cookie, qr/session=/, 'cookie name';
    like $cookie, qr/Max-Age=0/i, 'max-age is 0';
};

subtest 'multiple cookies' => sub {
    my @sent;
    my $send = sub ($msg) { push @sent, $msg; Future->done };
    my $res = PAGI::Response->new($send);

    $res->cookie('a' => '1')->cookie('b' => '2');
    $res->text("ok")->get;

    my @cookies = grep { lc($_->[0]) eq 'set-cookie' } @{$sent[0]->{headers}};
    is scalar(@cookies), 2, 'two set-cookie headers';
};

subtest 'stream method' => sub {
    my @sent;
    my $send = sub ($msg) { push @sent, $msg; Future->done };
    my $res = PAGI::Response->new($send);

    $res->content_type('text/plain');
    $res->stream(async sub ($writer) {
        await $writer->write("chunk1");
        await $writer->write("chunk2");
        await $writer->close();
    })->get;

    is scalar(@sent), 4, 'start + 2 chunks + close';
    is $sent[0]->{type}, 'http.response.start', 'first is start';
    is $sent[1]->{body}, 'chunk1', 'first chunk';
    is $sent[1]->{more}, 1, 'more=1 for chunk';
    is $sent[2]->{body}, 'chunk2', 'second chunk';
    is $sent[2]->{more}, 1, 'more=1 for chunk';
    is $sent[3]->{more}, 0, 'more=0 for close';
};

subtest 'stream writer bytes_written' => sub {
    my @sent;
    my $send = sub ($msg) { push @sent, $msg; Future->done };
    my $res = PAGI::Response->new($send);

    my $bytes;
    $res->stream(async sub ($writer) {
        await $writer->write("12345");
        await $writer->write("67890");
        $bytes = $writer->bytes_written;
        await $writer->close();
    })->get;

    is $bytes, 10, 'bytes_written tracks total';
};

subtest 'error method basic' => sub {
    my @sent;
    my $send = sub ($msg) { push @sent, $msg; Future->done };
    my $res = PAGI::Response->new($send);

    $res->error(400, "Bad Request")->get;

    is $sent[0]->{status}, 400, 'status from error';
    my %headers = map { lc($_->[0]) => $_->[1] } @{$sent[0]->{headers}};
    is $headers{'content-type'}, 'application/json; charset=utf-8', 'json content-type';

    my $body = JSON::MaybeXS->new(utf8 => 1)->decode($sent[1]->{body});
    is $body->{error}, 'Bad Request', 'error message in body';
    is $body->{status}, 400, 'status in body';
};

subtest 'error with extra data' => sub {
    my @sent;
    my $send = sub ($msg) { push @sent, $msg; Future->done };
    my $res = PAGI::Response->new($send);

    $res->error(422, "Validation Failed", {
        errors => [
            { field => 'email', message => 'Invalid email' },
        ]
    })->get;

    is $sent[0]->{status}, 422, 'status 422';

    my $body = JSON::MaybeXS->new(utf8 => 1)->decode($sent[1]->{body});
    is $body->{error}, 'Validation Failed', 'error message';
    is scalar(@{$body->{errors}}), 1, 'errors array included';
    is $body->{errors}[0]{field}, 'email', 'field in error';
};

done_testing;
