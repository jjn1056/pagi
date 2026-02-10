#!/usr/bin/env perl

# =============================================================================
# Test: Unrecognized event types throw exceptions (PAGI spec compliance)
#
# Per main.mkdn: "Servers must raise exceptions if... The type field is unrecognized"
#
# This test verifies:
# 1. The _unrecognized_event_type helper function exists and works correctly
# 2. All four send handlers (HTTP/1.1, HTTP/2, SSE, WebSocket) call this function
# =============================================================================

use strict;
use warnings;
use Test2::V0;

# =============================================================================
# Test: Verify send handlers have unrecognized type handling
# This inspects the source code to ensure the else clauses exist
# =============================================================================

subtest 'send handlers have unrecognized type handling' => sub {
    # Read the Connection.pm source
    my $source = do {
        open my $fh, '<', 'lib/PAGI/Server/Connection.pm' or die "Cannot read: $!";
        local $/;
        <$fh>;
    };

    # Check helper function exists
    like(
        $source,
        qr/sub _unrecognized_event_type \{/,
        'helper function _unrecognized_event_type exists'
    );

    # Check it dies with correct message format
    like(
        $source,
        qr/die "Unrecognized event type/,
        'helper function dies with correct message'
    );

    # Check for the three else clauses we added
    like(
        $source,
        qr/_unrecognized_event_type\(\$type, 'http'\)/,
        'HTTP send handler has unrecognized event type check'
    );

    like(
        $source,
        qr/_unrecognized_event_type\(\$type, 'sse'\)/,
        'SSE send handler has unrecognized event type check'
    );

    like(
        $source,
        qr/_unrecognized_event_type\(\$type, 'websocket'\)/,
        'WebSocket send handler has unrecognized event type check'
    );

    # Count occurrences - should be exactly 4 calls (HTTP/1.1, HTTP/2, SSE, WebSocket)
    my @calls = $source =~ /_unrecognized_event_type\(\$type,/g;
    is(scalar @calls, 4, 'exactly 4 protocol handlers call _unrecognized_event_type');
};

subtest 'helper function logic' => sub {
    # Extract and eval just the helper function to test it directly
    my $source = do {
        open my $fh, '<', 'lib/PAGI/Server/Connection.pm' or die "Cannot read: $!";
        local $/;
        <$fh>;
    };

    # Extract the function
    if ($source =~ /(sub _unrecognized_event_type \{[^}]+\})/) {
        my $func = $1;

        # Eval it in a test package
        eval "package TestHelper; $func; 1;" or die "Failed to compile: $@";

        # Test it
        like(
            dies { TestHelper::_unrecognized_event_type('foo.bar', 'http') },
            qr/Unrecognized event type 'foo\.bar' for http protocol/,
            'throws correct message for http'
        );

        like(
            dies { TestHelper::_unrecognized_event_type('unknown', 'websocket') },
            qr/Unrecognized event type 'unknown' for websocket protocol/,
            'throws correct message for websocket'
        );

        like(
            dies { TestHelper::_unrecognized_event_type('bad.type', 'sse') },
            qr/Unrecognized event type 'bad\.type' for sse protocol/,
            'throws correct message for sse'
        );
    }
    else {
        fail('Could not extract _unrecognized_event_type function');
    }
};

done_testing;
