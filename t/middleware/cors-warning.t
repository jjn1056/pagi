#!/usr/bin/env perl

use strict;
use warnings;
use Test2::V0;

use lib 'lib';

use PAGI::Middleware::CORS;

# =============================================================================
# Test: CORS warns when wildcard origins used with credentials
# =============================================================================

subtest 'wildcard origins with credentials emits warning' => sub {
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, $_[0] };

    PAGI::Middleware::CORS->new(
        origins     => ['*'],
        credentials => 1,
    );

    is scalar(@warnings), 1, 'exactly one warning emitted';
    like $warnings[0], qr/wildcard.*credentials/i,
        'warning mentions wildcard and credentials';
};

subtest 'wildcard origins without credentials emits no warning' => sub {
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, $_[0] };

    PAGI::Middleware::CORS->new(
        origins     => ['*'],
        credentials => 0,
    );

    is scalar(@warnings), 0, 'no warnings emitted';
};

subtest 'explicit origins with credentials emits no warning' => sub {
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, $_[0] };

    PAGI::Middleware::CORS->new(
        origins     => ['https://example.com'],
        credentials => 1,
    );

    is scalar(@warnings), 0, 'no warnings emitted';
};

subtest 'default config emits no warning' => sub {
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, $_[0] };

    PAGI::Middleware::CORS->new();

    is scalar(@warnings), 0, 'no warnings emitted';
};

done_testing;
