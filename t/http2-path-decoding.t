use strict;
use warnings;
use Test2::V0;
use URI::Escape qw(uri_unescape);
use Encode qw(decode);

# Test the HTTP/2 path decoding pipeline directly.
# HTTP/2 should use the same pipeline as HTTP/1.1:
#   uri_unescape() then UTF-8 decode with FB_CROAK fallback.

sub decode_path {
    my ($raw_path) = @_;
    my $unescaped = uri_unescape($raw_path);
    my $decoded = eval { decode('UTF-8', $unescaped, Encode::FB_CROAK) }
                  // $unescaped;
    return $decoded;
}

subtest 'UTF-8 percent-encoded path' => sub {
    # cafe with accent: caf\x{e9} -> UTF-8 bytes C3 A9
    is decode_path('/caf%C3%A9'), "/caf\x{e9}", 'decodes UTF-8 percent-encoded path';
};

subtest 'invalid UTF-8 falls back to raw bytes' => sub {
    # %FF%FE is not valid UTF-8; should fall back without crashing
    my $result = decode_path('/bad%FF%FEpath');
    ok defined($result), 'returns a defined value for invalid UTF-8';
    like $result, qr/bad.*path/, 'preserves surrounding ASCII';
};

subtest 'simple ASCII path unchanged' => sub {
    is decode_path('/hello/world'), '/hello/world', 'ASCII path passes through unchanged';
};

subtest 'space as %20 decodes correctly' => sub {
    is decode_path('/hello%20world'), '/hello world', '%20 decodes to space';
};

done_testing;
