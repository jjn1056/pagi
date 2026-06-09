use strict;
use warnings;
use Test2::V0;

# The PAGI distribution is the specification: PAGI.pm plus the
# PAGI::Spec::* POD generated at build time. Only PAGI.pm exists in the
# repo (the generated docs are not present until `dzil build`), so this
# load test covers the one shippable module.
require PAGI;
ok(PAGI->VERSION, 'PAGI loads and reports a version');

done_testing;
