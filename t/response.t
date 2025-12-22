use strict;
use warnings;
use v5.32;
use Test2::V0;
use Future;

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

done_testing;
