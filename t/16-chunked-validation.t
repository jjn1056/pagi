#!/usr/bin/env perl

# =============================================================================
# Test: Chunked Transfer-Encoding Validation
#
# This test exposes issue 2.1 from SERVER_ISSUES.md:
# Chunk size is parsed with hex() which silently accepts invalid input.
#
# Problem: hex("garbage") returns 0, hex("") returns 0
# This allows attackers to truncate request bodies by sending invalid chunk sizes.
#
# Expected behavior (after fix):
# - Invalid hex chunk sizes should return an error
# - Empty chunk size lines should be rejected
# - Only valid hex digits [0-9a-fA-F] should be accepted
#
# Current behavior (before fix):
# - hex() silently returns 0 for garbage, treating it as end-of-body
# =============================================================================

use strict;
use warnings;
use Test2::V0;

use FindBin;
use lib "$FindBin::Bin/../lib";

use PAGI::Server::Protocol::HTTP1;

my $proto = PAGI::Server::Protocol::HTTP1->new;

# =============================================================================
# Unit Tests: parse_chunked_body validation
# =============================================================================

subtest 'Valid chunked bodies should parse correctly' => sub {
    # Simple valid chunk: "5\r\nhello\r\n0\r\n\r\n"
    my $valid = "5\r\nhello\r\n0\r\n\r\n";
    my ($data, $consumed, $complete) = $proto->parse_chunked_body($valid);
    is($data, 'hello', 'Valid chunk data extracted');
    is($consumed, 15, 'All bytes consumed');
    is($complete, 1, 'Body marked complete');

    # Hex chunk size (uppercase)
    my $hex_upper = "A\r\n0123456789\r\n0\r\n\r\n";
    ($data, $consumed, $complete) = $proto->parse_chunked_body($hex_upper);
    is($data, '0123456789', 'Uppercase hex chunk size works');
    is($complete, 1, 'Body complete');

    # Hex chunk size (lowercase)
    my $hex_lower = "a\r\nabcdefghij\r\n0\r\n\r\n";
    ($data, $consumed, $complete) = $proto->parse_chunked_body($hex_lower);
    is($data, 'abcdefghij', 'Lowercase hex chunk size works');
    is($complete, 1, 'Body complete');

    # Chunk with extension (should be ignored per RFC 7230)
    my $with_ext = "5;ext=foo\r\nhello\r\n0\r\n\r\n";
    ($data, $consumed, $complete) = $proto->parse_chunked_body($with_ext);
    is($data, 'hello', 'Chunk extension correctly ignored');
    is($complete, 1, 'Body complete');
};

subtest 'Invalid chunk sizes should be rejected' => sub {
    # Test: "garbage\r\n\r\n" - should NOT be treated as valid end-of-body
    my $garbage = "garbage\r\n\r\n";
    my ($data, $consumed, $complete, $error);

    # Current vulnerable behavior: hex("garbage") = 0, treated as final chunk
    # Fixed behavior: should return error or (undef, 0, 0, error)
    eval {
        ($data, $consumed, $complete) = $proto->parse_chunked_body($garbage);
    };
    $error = $@;

    if ($error) {
        # Good - threw an exception
        like($error, qr/invalid|chunk|hex/i, 'Garbage chunk size rejected with error');
    } else {
        # Check if it returned an error structure or silently accepted
        if (ref($data) eq 'HASH' && $data->{error}) {
            pass('Garbage chunk size returned error structure');
        } elsif ($complete && $consumed > 0) {
            # VULNERABILITY: garbage was silently treated as chunk size 0
            fail('VULNERABLE: garbage chunk size silently accepted as end-of-body');
            diag("data='$data', consumed=$consumed, complete=$complete");
        } else {
            pass('Garbage chunk size not accepted');
        }
    }

    # Test: empty chunk size line "\r\n\r\n"
    my $empty = "\r\n\r\n";
    eval {
        ($data, $consumed, $complete) = $proto->parse_chunked_body($empty);
    };
    $error = $@;

    if ($error) {
        like($error, qr/invalid|chunk|hex|empty/i, 'Empty chunk size rejected with error');
    } else {
        if (ref($data) eq 'HASH' && $data->{error}) {
            pass('Empty chunk size returned error structure');
        } elsif ($complete && $consumed > 0) {
            fail('VULNERABLE: empty chunk size silently accepted as end-of-body');
            diag("data='$data', consumed=$consumed, complete=$complete");
        } else {
            pass('Empty chunk size not accepted');
        }
    }

    # Test: negative-looking size "-5\r\n\r\n"
    my $negative = "-5\r\n\r\n";
    eval {
        ($data, $consumed, $complete) = $proto->parse_chunked_body($negative);
    };
    $error = $@;

    if ($error) {
        like($error, qr/invalid|chunk|hex/i, 'Negative chunk size rejected with error');
    } else {
        if (ref($data) eq 'HASH' && $data->{error}) {
            pass('Negative chunk size returned error structure');
        } elsif ($complete && $consumed > 0) {
            fail('VULNERABLE: negative chunk size silently accepted');
            diag("data='$data', consumed=$consumed, complete=$complete");
        } else {
            pass('Negative chunk size not accepted');
        }
    }

    # Test: chunk size with leading garbage "xyz5\r\nhello\r\n0\r\n\r\n"
    my $leading_garbage = "xyz5\r\nhello\r\n0\r\n\r\n";
    eval {
        ($data, $consumed, $complete) = $proto->parse_chunked_body($leading_garbage);
    };
    $error = $@;

    if ($error) {
        like($error, qr/invalid|chunk|hex/i, 'Leading garbage in chunk size rejected');
    } else {
        if (ref($data) eq 'HASH' && $data->{error}) {
            pass('Leading garbage in chunk size returned error');
        } elsif ($data eq '' && $complete) {
            # hex("xyz5") = 0, treated as end
            fail('VULNERABLE: leading garbage caused body truncation');
            diag("data='$data', consumed=$consumed, complete=$complete");
        } else {
            pass('Leading garbage in chunk size handled');
        }
    }
};

subtest 'Whitespace handling in chunk sizes' => sub {
    # Leading/trailing whitespace in chunk size - RFC 7230 says chunk-size is
    # strictly hex digits, but some servers are lenient. Our fix should at
    # least not crash on whitespace.

    # Leading space (some servers accept this)
    my $leading_space = " 5\r\nhello\r\n0\r\n\r\n";
    my ($data, $consumed, $complete, $error);

    eval {
        ($data, $consumed, $complete) = $proto->parse_chunked_body($leading_space);
    };
    $error = $@;

    # Either reject it or handle it gracefully
    if ($error || (ref($data) eq 'HASH' && $data->{error})) {
        pass('Leading space in chunk size rejected (strict)');
    } elsif ($data eq 'hello' && $complete) {
        pass('Leading space in chunk size accepted (lenient)');
    } else {
        # Some other behavior
        ok(1, "Leading space handled: data='$data', complete=$complete");
    }

    # Trailing space before extension
    my $trailing_space = "5 \r\nhello\r\n0\r\n\r\n";
    eval {
        ($data, $consumed, $complete) = $proto->parse_chunked_body($trailing_space);
    };
    $error = $@;

    if ($error || (ref($data) eq 'HASH' && $data->{error})) {
        pass('Trailing space in chunk size rejected (strict)');
    } elsif ($data eq 'hello' && $complete) {
        pass('Trailing space in chunk size accepted (lenient)');
    } else {
        ok(1, "Trailing space handled: data='$data', complete=$complete");
    }
};

subtest 'Extremely large chunk sizes are rejected' => sub {
    # "FFFFFFFFFFFFFFFF\r\n" would be 18 exabytes — must return error
    my $huge = "FFFFFFFFFFFFFFFF\r\ndata\r\n0\r\n\r\n";
    my ($data, $consumed, $complete) = $proto->parse_chunked_body($huge);
    ref_ok($data, 'HASH', 'Huge chunk size returns error structure');
    is($data->{error}, 413, 'Huge chunk size returns 413 Payload Too Large');

    # Just over default 10MB limit: A00001 hex = 10485761 bytes
    my $over_limit = "A00001\r\ndata\r\n0\r\n\r\n";
    ($data, $consumed, $complete) = $proto->parse_chunked_body($over_limit);
    ref_ok($data, 'HASH', 'Chunk slightly over limit returns error');
    is($data->{error}, 413, 'Over-limit chunk returns 413');

    # Right at the limit: A00000 hex = 10485760 bytes (exactly 10MB)
    # This should NOT be rejected (but will wait for more data since buffer is small)
    my $at_limit = "A00000\r\ndata\r\n0\r\n\r\n";
    ($data, $consumed, $complete) = $proto->parse_chunked_body($at_limit);
    if (ref($data) eq 'HASH') {
        fail('Chunk at limit should not be rejected');
    } else {
        # Waiting for more data is fine — the chunk size is valid
        pass('Chunk at exact limit is accepted (waiting for data)');
    }
};

subtest 'Custom max_chunk_size is respected' => sub {
    my $strict_proto = PAGI::Server::Protocol::HTTP1->new(max_chunk_size => 100);

    # 101 bytes: 65 hex = 101 decimal
    my $over = "65\r\n" . ("x" x 101) . "\r\n0\r\n\r\n";
    my ($data, $consumed, $complete) = $strict_proto->parse_chunked_body($over);
    ref_ok($data, 'HASH', 'Over custom limit returns error');
    is($data->{error}, 413, 'Custom limit triggers 413');

    # 100 bytes: 64 hex = 100 decimal — exactly at limit, should be fine
    my $at = "64\r\n" . ("x" x 100) . "\r\n0\r\n\r\n";
    ($data, $consumed, $complete) = $strict_proto->parse_chunked_body($at);
    is($data, "x" x 100, 'Chunk at custom limit parses correctly');
    is($complete, 1, 'Body complete');
};

done_testing;
