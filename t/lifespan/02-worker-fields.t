#!/usr/bin/env perl

# =============================================================================
# Test: Lifespan scope includes worker fields (PAGI spec compliance)
#
# Per lifespan.mkdn:
# - pagi["is_worker"] (Int, optional) - 1 if running as a worker, 0 otherwise
# - pagi["worker_num"] (Int, optional) - Worker identifier (1, 2, 3, ...)
# =============================================================================

use strict;
use warnings;
use Test2::V0;

subtest 'lifespan scope includes worker fields' => sub {
    # Read the Server.pm source
    my $source = do {
        open my $fh, '<', 'lib/PAGI/Server.pm' or die "Cannot read: $!";
        local $/;
        <$fh>;
    };

    # Find the lifespan scope creation
    like(
        $source,
        qr/type\s*=>\s*'lifespan'/,
        'lifespan scope creation exists'
    );

    # Verify is_worker is included in pagi hashref
    like(
        $source,
        qr/is_worker\s*=>\s*\$self->\{is_worker\}/,
        'is_worker field is included in pagi hashref'
    );

    # Verify worker_num is included in pagi hashref
    like(
        $source,
        qr/worker_num\s*=>\s*\$self->\{worker_num\}/,
        'worker_num field is included in pagi hashref'
    );
};

subtest 'worker fields are set during worker process creation' => sub {
    my $source = do {
        open my $fh, '<', 'lib/PAGI/Server.pm' or die "Cannot read: $!";
        local $/;
        <$fh>;
    };

    # Verify is_worker is set to 1 in worker process
    like(
        $source,
        qr/\{is_worker\}\s*=\s*1/,
        'is_worker is set to 1 in worker process'
    );

    # Verify worker_num is assigned from the worker number parameter
    like(
        $source,
        qr/\{worker_num\}\s*=\s*\$worker_num/,
        'worker_num is assigned from worker number'
    );
};

done_testing;
