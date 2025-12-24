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

subtest 'send_raw method' => sub {
    my @sent;
    my $send = sub ($msg) { push @sent, $msg; Future->done };
    my $res = PAGI::Response->new($send);

    $res->status(200)->header('x-test' => 'value');
    $res->send_raw("Hello")->get;

    is scalar(@sent), 2, 'two messages sent';
    is $sent[0]->{type}, 'http.response.start', 'first is start';
    is $sent[0]->{status}, 200, 'status correct';
    is $sent[1]->{type}, 'http.response.body', 'second is body';
    is $sent[1]->{body}, 'Hello', 'body correct';
    is $sent[1]->{more}, 0, 'more is false';
};

subtest 'send method encodes UTF-8' => sub {
    my @sent;
    my $send = sub ($msg) { push @sent, $msg; Future->done };
    my $res = PAGI::Response->new($send);

    $res->send("café")->get;

    # Should be UTF-8 encoded bytes
    is $sent[1]->{body}, "caf\xc3\xa9", 'UTF-8 encoded';

    # Should have charset in content-type
    my %headers = map { lc($_->[0]) => $_->[1] } @{$sent[0]->{headers}};
    like $headers{'content-type'}, qr/charset=utf-8/i, 'charset added';
};

subtest 'cannot send twice' => sub {
    my $send = sub { Future->done };
    my $res = PAGI::Response->new($send);

    $res->send_raw("first")->get;
    like dies { $res->send_raw("second")->get }, qr/already sent/i, 'dies on second send';
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

subtest 'json error response pattern' => sub {
    my @sent;
    my $send = sub ($msg) { push @sent, $msg; Future->done };
    my $res = PAGI::Response->new($send);

    $res->status(400)->json({ error => "Bad Request" })->get;

    is $sent[0]->{status}, 400, 'status from error';
    my %headers = map { lc($_->[0]) => $_->[1] } @{$sent[0]->{headers}};
    is $headers{'content-type'}, 'application/json; charset=utf-8', 'json content-type';

    my $body = JSON::MaybeXS->new(utf8 => 1)->decode($sent[1]->{body});
    is $body->{error}, 'Bad Request', 'error message in body';
};

use File::Temp qw(tempfile);

subtest 'send_file basic' => sub {
    # Create temp file
    my ($fh, $filename) = tempfile(UNLINK => 1);
    print $fh "Hello File Content";
    close $fh;

    my @sent;
    my $send = sub ($msg) { push @sent, $msg; Future->done };
    my $res = PAGI::Response->new($send);

    $res->send_file($filename)->get;

    is $sent[0]->{status}, 200, 'status 200';
    is $sent[1]->{file}, $filename, 'file path sent via PAGI protocol';
    ok !exists $sent[1]->{offset}, 'no offset for full file';
    ok !exists $sent[1]->{length}, 'no length for full file';

    my %headers = map { lc($_->[0]) => $_->[1] } @{$sent[0]->{headers}};
    ok exists $headers{'content-type'}, 'has content-type';
    is $headers{'content-length'}, 18, 'content-length set';
};

subtest 'send_file with filename option' => sub {
    my ($fh, $filename) = tempfile(UNLINK => 1);
    print $fh "data";
    close $fh;

    my @sent;
    my $send = sub ($msg) { push @sent, $msg; Future->done };
    my $res = PAGI::Response->new($send);

    $res->send_file($filename, filename => 'download.txt')->get;

    my %headers = map { lc($_->[0]) => $_->[1] } @{$sent[0]->{headers}};
    like $headers{'content-disposition'}, qr/attachment/, 'attachment disposition';
    like $headers{'content-disposition'}, qr/download\.txt/, 'filename in disposition';
};

subtest 'send_file inline' => sub {
    my ($fh, $filename) = tempfile(UNLINK => 1, SUFFIX => '.txt');
    print $fh "inline data";
    close $fh;

    my @sent;
    my $send = sub ($msg) { push @sent, $msg; Future->done };
    my $res = PAGI::Response->new($send);

    $res->send_file($filename, inline => 1)->get;

    my %headers = map { lc($_->[0]) => $_->[1] } @{$sent[0]->{headers}};
    like $headers{'content-disposition'}, qr/inline/, 'inline disposition';
};

subtest 'send_file not found' => sub {
    my $send = sub { Future->done };
    my $res = PAGI::Response->new($send);

    like dies { $res->send_file('/nonexistent/file.txt')->get },
        qr/not found|no such file/i, 'dies for missing file';
};

subtest 'send_file with offset' => sub {
    my ($fh, $filename) = tempfile(UNLINK => 1);
    print $fh "0123456789ABCDEF";  # 16 bytes
    close $fh;

    my @sent;
    my $send = sub ($msg) { push @sent, $msg; Future->done };
    my $res = PAGI::Response->new($send);

    $res->send_file($filename, offset => 5)->get;

    is $sent[1]->{file}, $filename, 'file path sent';
    is $sent[1]->{offset}, 5, 'offset included';
    ok !exists $sent[1]->{length}, 'length omitted (reads to end)';

    my %headers = map { lc($_->[0]) => $_->[1] } @{$sent[0]->{headers}};
    is $headers{'content-length'}, 11, 'content-length is file_size - offset';
};

subtest 'send_file with offset and length' => sub {
    my ($fh, $filename) = tempfile(UNLINK => 1);
    print $fh "0123456789ABCDEF";  # 16 bytes
    close $fh;

    my @sent;
    my $send = sub ($msg) { push @sent, $msg; Future->done };
    my $res = PAGI::Response->new($send);

    $res->send_file($filename, offset => 5, length => 5)->get;

    is $sent[1]->{file}, $filename, 'file path sent';
    is $sent[1]->{offset}, 5, 'offset included';
    is $sent[1]->{length}, 5, 'length included';

    my %headers = map { lc($_->[0]) => $_->[1] } @{$sent[0]->{headers}};
    is $headers{'content-length'}, 5, 'content-length matches length option';
};

subtest 'send_file offset validation' => sub {
    my ($fh, $filename) = tempfile(UNLINK => 1);
    print $fh "small";  # 5 bytes
    close $fh;

    my $send = sub { Future->done };

    # Negative offset
    my $res1 = PAGI::Response->new($send);
    like dies { $res1->send_file($filename, offset => -1)->get },
        qr/non-negative/, 'negative offset rejected';

    # Offset beyond file
    my $res2 = PAGI::Response->new($send);
    like dies { $res2->send_file($filename, offset => 100)->get },
        qr/exceeds file size/, 'offset beyond file rejected';

    # Negative length
    my $res3 = PAGI::Response->new($send);
    like dies { $res3->send_file($filename, length => -1)->get },
        qr/non-negative/, 'negative length rejected';
};

subtest 'send_file length clamped to remaining' => sub {
    my ($fh, $filename) = tempfile(UNLINK => 1);
    print $fh "0123456789";  # 10 bytes
    close $fh;

    my @sent;
    my $send = sub ($msg) { push @sent, $msg; Future->done };
    my $res = PAGI::Response->new($send);

    # Request more bytes than available
    $res->send_file($filename, offset => 5, length => 100)->get;

    my %headers = map { lc($_->[0]) => $_->[1] } @{$sent[0]->{headers}};
    is $headers{'content-length'}, 5, 'length clamped to available bytes';
    ok !exists $sent[1]->{length}, 'no length in protocol when clamped to remaining';
};

subtest 'cors basic' => sub {
    my @sent;
    my $send = sub ($msg) { push @sent, $msg; Future->done };
    my $res = PAGI::Response->new($send);

    my $ret = $res->cors;
    is $ret, $res, 'cors returns self';

    $res->json({ data => 'test' })->get;

    my %headers = map { lc($_->[0]) => $_->[1] } @{$sent[0]->{headers}};
    is $headers{'access-control-allow-origin'}, '*', 'default origin is *';
    is $headers{'vary'}, 'Origin', 'Vary header set';
    ok !exists $headers{'access-control-allow-credentials'}, 'no credentials by default';
};

subtest 'cors with specific origin' => sub {
    my @sent;
    my $send = sub ($msg) { push @sent, $msg; Future->done };
    my $res = PAGI::Response->new($send);

    $res->cors(origin => 'https://example.com')->json({})->get;

    my %headers = map { lc($_->[0]) => $_->[1] } @{$sent[0]->{headers}};
    is $headers{'access-control-allow-origin'}, 'https://example.com', 'specific origin';
};

subtest 'cors with credentials' => sub {
    my @sent;
    my $send = sub ($msg) { push @sent, $msg; Future->done };
    my $res = PAGI::Response->new($send);

    $res->cors(
        origin      => 'https://example.com',
        credentials => 1,
    )->json({})->get;

    my %headers = map { lc($_->[0]) => $_->[1] } @{$sent[0]->{headers}};
    is $headers{'access-control-allow-origin'}, 'https://example.com', 'origin set';
    is $headers{'access-control-allow-credentials'}, 'true', 'credentials header';
};

subtest 'cors with expose headers' => sub {
    my @sent;
    my $send = sub ($msg) { push @sent, $msg; Future->done };
    my $res = PAGI::Response->new($send);

    $res->cors(
        expose => [qw(X-Request-Id X-RateLimit)],
    )->json({})->get;

    my %headers = map { lc($_->[0]) => $_->[1] } @{$sent[0]->{headers}};
    like $headers{'access-control-expose-headers'}, qr/X-Request-Id/, 'expose header 1';
    like $headers{'access-control-expose-headers'}, qr/X-RateLimit/, 'expose header 2';
};

subtest 'cors preflight' => sub {
    my @sent;
    my $send = sub ($msg) { push @sent, $msg; Future->done };
    my $res = PAGI::Response->new($send);

    $res->cors(
        origin    => 'https://example.com',
        methods   => [qw(GET POST PUT)],
        headers   => [qw(Content-Type X-Custom)],
        max_age   => 3600,
        preflight => 1,
    )->status(204)->empty->get;

    my %headers = map { lc($_->[0]) => $_->[1] } @{$sent[0]->{headers}};
    is $headers{'access-control-allow-origin'}, 'https://example.com', 'origin';
    like $headers{'access-control-allow-methods'}, qr/GET/, 'methods includes GET';
    like $headers{'access-control-allow-methods'}, qr/POST/, 'methods includes POST';
    like $headers{'access-control-allow-methods'}, qr/PUT/, 'methods includes PUT';
    like $headers{'access-control-allow-headers'}, qr/Content-Type/, 'headers includes Content-Type';
    like $headers{'access-control-allow-headers'}, qr/X-Custom/, 'headers includes X-Custom';
    is $headers{'access-control-max-age'}, '3600', 'max-age';
};

subtest 'cors credentials with wildcard uses request_origin' => sub {
    my @sent;
    my $send = sub ($msg) { push @sent, $msg; Future->done };
    my $res = PAGI::Response->new($send);

    # When credentials is true and origin is *, we must provide request_origin
    $res->cors(
        origin         => '*',
        credentials    => 1,
        request_origin => 'https://client.example.com',
    )->json({})->get;

    my %headers = map { lc($_->[0]) => $_->[1] } @{$sent[0]->{headers}};
    is $headers{'access-control-allow-origin'}, 'https://client.example.com', 'echoes request origin';
    is $headers{'access-control-allow-credentials'}, 'true', 'credentials set';
};

done_testing;
