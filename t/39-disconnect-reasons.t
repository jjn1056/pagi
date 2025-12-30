#!/usr/bin/env perl

# =============================================================================
# Test: Disconnect reasons implementation (PAGI spec compliance)
#
# Per www.mkdn: Servers must use standard disconnect reason strings
# =============================================================================

use strict;
use warnings;
use Test2::V0;

subtest 'server implements disconnect reason code paths' => sub {
    # Read the Connection.pm source
    my $source = do {
        open my $fh, '<', 'lib/PAGI/Server/Connection.pm' or die "Cannot read: $!";
        local $/;
        <$fh>;
    };

    # Verify protocol_error is set on parse failures
    like(
        $source,
        qr/_handle_disconnect\('protocol_error'\)/,
        'protocol_error reason used for parse failures'
    );

    # Verify server_shutdown auto-detection exists
    like(
        $source,
        qr/'server_shutdown'/,
        'server_shutdown reason is referenced'
    );

    like(
        $source,
        qr/\$self->\{server\}\s*&&\s*\$self->\{server\}\{shutting_down\}/,
        'server shutdown state is checked in _handle_disconnect'
    );

    # Verify other disconnect reasons are used
    like(
        $source,
        qr/'client_closed'/,
        'client_closed reason is used as default'
    );

    like(
        $source,
        qr/'idle_timeout'/,
        'idle_timeout reason is used'
    );

    like(
        $source,
        qr/'client_timeout'/,
        'client_timeout reason is used'
    );

    like(
        $source,
        qr/'body_too_large'/,
        'body_too_large reason is used'
    );
};

subtest '_handle_disconnect method structure' => sub {
    my $source = do {
        open my $fh, '<', 'lib/PAGI/Server/Connection.pm' or die "Cannot read: $!";
        local $/;
        <$fh>;
    };

    # Verify the auto-detect logic comes before the default
    if ($source =~ /(sub _handle_disconnect \{.*?^})/ms) {
        my $method = $1;

        # Check order: server_shutdown check should come before default assignment
        my $shutdown_pos = index($method, 'server_shutdown');
        my $default_pos = index($method, "//= 'client_closed'");

        ok($shutdown_pos > 0, 'server_shutdown check found');
        ok($default_pos > 0, 'default client_closed found');
        ok($shutdown_pos < $default_pos, 'server_shutdown check comes before default');
    }
    else {
        fail('Could not extract _handle_disconnect method');
    }
};

done_testing;
