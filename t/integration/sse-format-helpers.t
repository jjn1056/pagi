use strict;
use warnings;
use Test2::V0;
use FindBin;
use lib "$FindBin::Bin/../../lib";

# Test the formatting helpers directly
use PAGI::Server::Connection;

subtest 'format_sse_event - data only' => sub {
    my $result = PAGI::Server::Connection::_format_sse_event({ data => 'hello' });
    is($result, "data: hello\n\n", 'simple data event');
};

subtest 'format_sse_event - with event name' => sub {
    my $result = PAGI::Server::Connection::_format_sse_event({
        event => 'update', data => 'hi',
    });
    is($result, "event: update\ndata: hi\n\n", 'named event');
};

subtest 'format_sse_event - multi-line data' => sub {
    my $result = PAGI::Server::Connection::_format_sse_event({ data => "line1\nline2" });
    is($result, "data: line1\ndata: line2\n\n", 'multi-line splits on data:');
};

subtest 'format_sse_event - with id and retry' => sub {
    my $result = PAGI::Server::Connection::_format_sse_event({
        data => 'x', id => '5', retry => 3000,
    });
    is($result, "data: x\nid: 5\nretry: 3000\n\n", 'id and retry fields');
};

subtest 'format_sse_event - all fields' => sub {
    my $result = PAGI::Server::Connection::_format_sse_event({
        event => 'msg', data => "a\nb", id => '10', retry => 1000,
    });
    is($result, "event: msg\ndata: a\ndata: b\nid: 10\nretry: 1000\n\n", 'all fields combined');
};

subtest 'format_sse_comment - simple' => sub {
    my $result = PAGI::Server::Connection::_format_sse_comment({ comment => 'keepalive' });
    like($result, qr/^:/, 'starts with colon');
    like($result, qr/keepalive/, 'contains comment text');
    like($result, qr/\n\n$/, 'ends with double newline');
};

subtest 'format_sse_comment - already has colon prefix' => sub {
    my $result = PAGI::Server::Connection::_format_sse_comment({ comment => ':already' });
    unlike($result, qr/^::/, 'no double colon');
};

done_testing;
