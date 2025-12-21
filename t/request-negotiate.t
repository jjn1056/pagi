use strict;
use warnings;
use Test2::V0;

use PAGI::Request::Negotiate;

# Test: parse_accept with quality values
subtest 'parse_accept with quality values' => sub {
    my @types = PAGI::Request::Negotiate->parse_accept(
        'text/html, application/json;q=0.9, text/plain;q=0.5'
    );

    is(scalar(@types), 3, 'Parsed 3 types');

    is($types[0][0], 'text/html', 'First type is text/html');
    is($types[0][1], 1, 'First quality is 1');

    is($types[1][0], 'application/json', 'Second type is application/json');
    is($types[1][1], 0.9, 'Second quality is 0.9');

    is($types[2][0], 'text/plain', 'Third type is text/plain');
    is($types[2][1], 0.5, 'Third quality is 0.5');
};

# Test: parse_accept with no header (defaults to */*)
subtest 'parse_accept with no header defaults to */*' => sub {
    my @types = PAGI::Request::Negotiate->parse_accept(undef);

    is(scalar(@types), 1, 'Returns single entry');
    is($types[0][0], '*/*', 'Type is */*');
    is($types[0][1], 1, 'Quality is 1');
};

# Test: parse_accept with empty header
subtest 'parse_accept with empty header defaults to */*' => sub {
    my @types = PAGI::Request::Negotiate->parse_accept('');

    is(scalar(@types), 1, 'Returns single entry');
    is($types[0][0], '*/*', 'Type is */*');
    is($types[0][1], 1, 'Quality is 1');
};

# Test: parse_accept sorts by quality
subtest 'parse_accept sorts by quality' => sub {
    my @types = PAGI::Request::Negotiate->parse_accept(
        'text/plain;q=0.5, application/json;q=0.9, text/html'
    );

    is($types[0][0], 'text/html', 'Highest quality first');
    is($types[1][0], 'application/json', 'Second highest');
    is($types[2][0], 'text/plain', 'Lowest quality last');
};

# Test: parse_accept sorts by specificity when quality equal
subtest 'parse_accept sorts by specificity when quality equal' => sub {
    my @types = PAGI::Request::Negotiate->parse_accept(
        '*/*, text/*, text/html'
    );

    is($types[0][0], 'text/html', 'Most specific first');
    is($types[1][0], 'text/*', 'Partial wildcard second');
    is($types[2][0], '*/*', 'Full wildcard last');
};

# Test: parse_accept handles complex Accept header
subtest 'parse_accept handles complex Accept header' => sub {
    my @types = PAGI::Request::Negotiate->parse_accept(
        'text/html, application/xhtml+xml, application/xml;q=0.9, image/webp, */*;q=0.8'
    );

    is(scalar(@types), 5, 'Parsed 5 types');
    is($types[0][1], 1, 'First group has quality 1');
    is($types[-1][0], '*/*', 'Last is */*');
    is($types[-1][1], 0.8, 'Last has quality 0.8');
};

# Test: parse_accept normalizes type to lowercase
subtest 'parse_accept normalizes type to lowercase' => sub {
    my @types = PAGI::Request::Negotiate->parse_accept('TEXT/HTML, Application/JSON;q=0.9');

    is($types[0][0], 'text/html', 'Type normalized to lowercase');
    is($types[1][0], 'application/json', 'Type normalized to lowercase');
};

# Test: best_match finds highest quality match
subtest 'best_match finds highest quality match' => sub {
    my $best = PAGI::Request::Negotiate->best_match(
        ['application/json', 'text/html'],
        'text/html, application/json;q=0.9'
    );

    is($best, 'text/html', 'Returns highest quality match');
};

# Test: best_match with shortcuts
subtest 'best_match with shortcuts' => sub {
    my $best = PAGI::Request::Negotiate->best_match(
        ['json', 'html'],
        'text/html, application/json;q=0.9'
    );

    is($best, 'html', 'Returns shortcut form');
};

# Test: best_match with wildcards
subtest 'best_match with wildcards' => sub {
    my $best = PAGI::Request::Negotiate->best_match(
        ['application/json'],
        'text/html, */*;q=0.1'
    );

    is($best, 'application/json', 'Matches via wildcard');
};

# Test: best_match with type/* wildcard
subtest 'best_match with type/* wildcard' => sub {
    my $best = PAGI::Request::Negotiate->best_match(
        ['image/png', 'text/html'],
        'image/*, text/html;q=0.5'
    );

    is($best, 'image/png', 'Matches image/* with higher quality');
};

# Test: best_match returns undef when no match
subtest 'best_match returns undef when no match' => sub {
    my $best = PAGI::Request::Negotiate->best_match(
        ['application/json'],
        'text/html, text/plain'
    );

    is($best, undef, 'Returns undef when no acceptable type');
};

# Test: best_match with empty supported list
subtest 'best_match with empty supported list' => sub {
    my $best = PAGI::Request::Negotiate->best_match(
        [],
        'text/html'
    );

    is($best, undef, 'Returns undef for empty list');
};

# Test: best_match with quality=0 (explicitly rejected)
subtest 'best_match with quality=0 (explicitly rejected)' => sub {
    my $best = PAGI::Request::Negotiate->best_match(
        ['application/json', 'text/html'],
        'application/json;q=0, text/html'
    );

    is($best, 'text/html', 'Skips q=0 types');
};

# Test: type_matches exact match
subtest 'type_matches exact match' => sub {
    my $matches = PAGI::Request::Negotiate->type_matches('text/html', 'text/html');
    ok($matches, 'Exact match returns true');
};

# Test: type_matches with */*
subtest 'type_matches with */*' => sub {
    my $matches = PAGI::Request::Negotiate->type_matches('text/html', '*/*');
    ok($matches, 'Wildcard */* matches anything');
};

# Test: type_matches with type/*
subtest 'type_matches with type/*' => sub {
    my $matches = PAGI::Request::Negotiate->type_matches('text/html', 'text/*');
    ok($matches, 'text/* matches text/html');

    my $no_match = PAGI::Request::Negotiate->type_matches('application/json', 'text/*');
    ok(!$no_match, 'text/* does not match application/json');
};

# Test: type_matches case insensitive
subtest 'type_matches case insensitive' => sub {
    my $matches = PAGI::Request::Negotiate->type_matches('TEXT/HTML', 'text/html');
    ok($matches, 'Case insensitive match');
};

# Test: type_matches no match
subtest 'type_matches no match' => sub {
    my $matches = PAGI::Request::Negotiate->type_matches('text/html', 'application/json');
    ok(!$matches, 'Different types do not match');
};

# Test: normalize_type with shortcuts
subtest 'normalize_type with shortcuts' => sub {
    is(PAGI::Request::Negotiate->normalize_type('html'), 'text/html', 'html shortcut');
    is(PAGI::Request::Negotiate->normalize_type('json'), 'application/json', 'json shortcut');
    is(PAGI::Request::Negotiate->normalize_type('xml'), 'application/xml', 'xml shortcut');
    is(PAGI::Request::Negotiate->normalize_type('atom'), 'application/atom+xml', 'atom shortcut');
    is(PAGI::Request::Negotiate->normalize_type('rss'), 'application/rss+xml', 'rss shortcut');
    is(PAGI::Request::Negotiate->normalize_type('text'), 'text/plain', 'text shortcut');
    is(PAGI::Request::Negotiate->normalize_type('txt'), 'text/plain', 'txt shortcut');
    is(PAGI::Request::Negotiate->normalize_type('css'), 'text/css', 'css shortcut');
    is(PAGI::Request::Negotiate->normalize_type('js'), 'application/javascript', 'js shortcut');
    is(PAGI::Request::Negotiate->normalize_type('png'), 'image/png', 'png shortcut');
    is(PAGI::Request::Negotiate->normalize_type('jpg'), 'image/jpeg', 'jpg shortcut');
    is(PAGI::Request::Negotiate->normalize_type('jpeg'), 'image/jpeg', 'jpeg shortcut');
    is(PAGI::Request::Negotiate->normalize_type('gif'), 'image/gif', 'gif shortcut');
    is(PAGI::Request::Negotiate->normalize_type('svg'), 'image/svg+xml', 'svg shortcut');
    is(PAGI::Request::Negotiate->normalize_type('pdf'), 'application/pdf', 'pdf shortcut');
    is(PAGI::Request::Negotiate->normalize_type('zip'), 'application/zip', 'zip shortcut');
    is(PAGI::Request::Negotiate->normalize_type('form'), 'application/x-www-form-urlencoded', 'form shortcut');
};

# Test: normalize_type with full MIME type
subtest 'normalize_type with full MIME type' => sub {
    is(PAGI::Request::Negotiate->normalize_type('text/html'), 'text/html', 'Full type unchanged');
    is(PAGI::Request::Negotiate->normalize_type('application/json'), 'application/json', 'Full type unchanged');
};

# Test: normalize_type with unknown shortcut
subtest 'normalize_type with unknown shortcut' => sub {
    is(PAGI::Request::Negotiate->normalize_type('unknown'), 'application/unknown', 'Unknown becomes application/unknown');
};

# Test: accepts_type returns true
subtest 'accepts_type returns true' => sub {
    my $accepts = PAGI::Request::Negotiate->accepts_type(
        'text/html, application/json',
        'json'
    );
    ok($accepts, 'Accepts json');
};

# Test: accepts_type returns false
subtest 'accepts_type returns false' => sub {
    my $accepts = PAGI::Request::Negotiate->accepts_type(
        'text/html, text/plain',
        'json'
    );
    ok(!$accepts, 'Does not accept json');
};

# Test: accepts_type with wildcard
subtest 'accepts_type with wildcard' => sub {
    my $accepts = PAGI::Request::Negotiate->accepts_type(
        'text/html, */*;q=0.1',
        'application/json'
    );
    ok($accepts, 'Accepts via wildcard');
};

# Test: accepts_type with quality=0
subtest 'accepts_type with quality=0' => sub {
    my $accepts = PAGI::Request::Negotiate->accepts_type(
        'text/html, application/json;q=0',
        'json'
    );
    ok(!$accepts, 'Does not accept q=0');
};

# Test: quality_for_type gets quality value
subtest 'quality_for_type gets quality value' => sub {
    my $q = PAGI::Request::Negotiate->quality_for_type(
        'text/html, application/json;q=0.9',
        'json'
    );
    is($q, 0.9, 'Returns correct quality');
};

# Test: quality_for_type returns 0 for non-acceptable
subtest 'quality_for_type returns 0 for non-acceptable' => sub {
    my $q = PAGI::Request::Negotiate->quality_for_type(
        'text/html, text/plain',
        'json'
    );
    is($q, 0, 'Returns 0 for non-acceptable');
};

# Test: quality_for_type with wildcards
subtest 'quality_for_type with wildcards' => sub {
    my $q = PAGI::Request::Negotiate->quality_for_type(
        'text/html, */*;q=0.5',
        'application/json'
    );
    is($q, 0.5, 'Returns wildcard quality');
};

# Test: quality_for_type prefers more specific match
subtest 'quality_for_type prefers more specific match' => sub {
    my $q = PAGI::Request::Negotiate->quality_for_type(
        'text/*, text/html;q=0.9, */*;q=0.1',
        'text/html'
    );
    is($q, 0.9, 'Returns most specific match quality');
};

# Test: parse_accept handles whitespace
subtest 'parse_accept handles whitespace' => sub {
    my @types = PAGI::Request::Negotiate->parse_accept(
        '  text/html  ,  application/json ; q=0.9  '
    );

    is($types[0][0], 'text/html', 'Whitespace trimmed');
    is($types[1][0], 'application/json', 'Whitespace trimmed');
};

# Test: parse_accept handles q values out of range
subtest 'parse_accept handles q values out of range' => sub {
    my @types1 = PAGI::Request::Negotiate->parse_accept('text/html;q=1.5');
    is($types1[0][1], 1, 'q > 1 clamped to 1');

    my @types2 = PAGI::Request::Negotiate->parse_accept('text/html;q=-0.1');
    is($types2[0][1], 0, 'q < 0 clamped to 0');
};

done_testing;
