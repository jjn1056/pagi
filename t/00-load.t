use strict;
use warnings;
use Test2::V0;

# The PAGI distribution is the specification: PAGI.pm plus the
# PAGI::Spec::* POD documents. PAGI.pm is the only loadable module (the
# spec documents are pure POD, checked in t/pod-syntax.t), so this load
# test covers the one shippable module.
require PAGI;
ok(PAGI->VERSION, 'PAGI loads and reports a version');

done_testing;
