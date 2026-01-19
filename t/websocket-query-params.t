use strict;
use warnings;
use Test2::V0;

use PAGI::WebSocket;

# Mock receive/send for WebSocket constructor
my $receive = sub { Future->done({ type => 'websocket.receive', text => '{}' }) };
my $send = sub { Future->done };

# Helper to create WebSocket with query string
sub make_ws {
    my ($query_string, %extra) = @_;
    my $scope = {
        type         => 'websocket',
        path         => '/ws/chat',
        query_string => $query_string // '',
        headers      => [],
        %extra,
    };
    return PAGI::WebSocket->new($scope, $receive, $send);
}

subtest 'query_params basic parsing' => sub {
    my $ws = make_ws('user=alice&room=general');

    my $params = $ws->query_params;
    isa_ok($params, ['Hash::MultiValue'], 'query_params returns Hash::MultiValue');
    is($params->get('user'), 'alice', 'parses user param');
    is($params->get('room'), 'general', 'parses room param');
};

subtest 'query shortcut' => sub {
    my $ws = make_ws('user=bob&count=42');

    is($ws->query('user'), 'bob', 'query returns single param');
    is($ws->query('count'), '42', 'query returns numeric string');
    is($ws->query('missing'), undef, 'query returns undef for missing param');
};

subtest 'URL decoding' => sub {
    my $ws = make_ws('name=John%20Doe&msg=hello+world&special=%26%3D%3F');

    is($ws->query('name'), 'John Doe', 'decodes %20 as space');
    is($ws->query('msg'), 'hello world', 'decodes + as space');
    is($ws->query('special'), '&=?', 'decodes special characters');
};

subtest 'UTF-8 decoding' => sub {
    # UTF-8 encoded "cafe" with accent: caf%C3%A9
    my $ws = make_ws('word=caf%C3%A9&emoji=%F0%9F%8E%89');

    is($ws->query('word'), "caf\x{e9}", 'decodes UTF-8 characters');
    is($ws->query('emoji'), "\x{1F389}", 'decodes emoji');
};

subtest 'raw mode skips UTF-8 decoding' => sub {
    my $ws = make_ws('word=caf%C3%A9');

    my $raw = $ws->query('word', raw => 1);
    is($raw, "caf\xC3\xA9", 'raw mode returns bytes');

    my $raw_params = $ws->raw_query_params;
    is($raw_params->get('word'), "caf\xC3\xA9", 'raw_query_params returns bytes');

    is($ws->raw_query('word'), "caf\xC3\xA9", 'raw_query returns bytes');
};

subtest 'multiple values for same key' => sub {
    my $ws = make_ws('tag=perl&tag=async&tag=websocket');

    my $params = $ws->query_params;
    # Hash::MultiValue->get returns the LAST value
    is($params->get('tag'), 'websocket', 'get returns last value');

    my @all = $params->get_all('tag');
    is(\@all, ['perl', 'async', 'websocket'], 'get_all returns all values in order');
};

subtest 'empty and missing values' => sub {
    my $ws = make_ws('empty=&flag&normal=value');

    is($ws->query('empty'), '', 'empty value returns empty string');
    is($ws->query('flag'), '', 'key without = returns empty string');
    is($ws->query('normal'), 'value', 'normal key=value works');
};

subtest 'empty query string' => sub {
    my $ws = make_ws('');

    my $params = $ws->query_params;
    isa_ok($params, ['Hash::MultiValue'], 'returns Hash::MultiValue for empty query');
    is($ws->query('anything'), undef, 'query returns undef for empty query string');
};

subtest 'semicolon delimiter' => sub {
    # Some systems use ; instead of & as delimiter
    my $ws = make_ws('a=1;b=2&c=3');

    is($ws->query('a'), '1', 'parses with semicolon');
    is($ws->query('b'), '2', 'parses after semicolon');
    is($ws->query('c'), '3', 'parses with ampersand');
};

subtest 'caching in scope' => sub {
    my $scope = {
        type         => 'websocket',
        path         => '/ws',
        query_string => 'x=1',
        headers      => [],
    };
    my $ws = PAGI::WebSocket->new($scope, $receive, $send);

    $ws->query_params;
    ok(exists $scope->{'pagi.websocket.query'}, 'query_params cached in scope');

    $ws->query_params(raw => 1);
    ok(exists $scope->{'pagi.websocket.query.raw'}, 'raw query_params cached separately');
};

subtest 'strict mode dies on invalid UTF-8' => sub {
    # Invalid UTF-8 sequence: %FF is not valid
    my $ws = make_ws('bad=%FF%FE');

    # Non-strict mode replaces with replacement character
    my $result = $ws->query('bad');
    ok(defined $result, 'non-strict mode handles invalid UTF-8');

    # Create fresh scope for strict test (caching)
    my $ws2 = make_ws('bad=%FF%FE');
    like(
        dies { $ws2->query('bad', strict => 1) },
        qr/./,  # Any error is fine
        'strict mode dies on invalid UTF-8'
    );
};

subtest 'unknown options rejected' => sub {
    my $ws = make_ws('x=1');

    like(
        dies { $ws->query_params(invalid_option => 1) },
        qr/Unknown options.*invalid_option/,
        'query_params rejects unknown options'
    );
};

done_testing;
