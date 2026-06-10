use strict;
use warnings;
use Test::More;
use Test::Pod 1.41;

# The PAGI distribution's deliverable is documentation: PAGI.pm plus the
# PAGI::Spec::* and PAGI::Tutorial POD. Since the spec is now authored
# directly as POD (rather than generated from markdown), verify that every
# shipped POD file parses cleanly.
all_pod_files_ok();
