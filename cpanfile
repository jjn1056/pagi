# PAGI specification distribution.
#
# The spec modules (PAGI.pm + the generated PAGI::Spec::* POD) are pure
# documentation. The only runtime requirements are the transitional
# backward-compatibility dependencies below.

requires 'perl', '5.018';

# Transitional backward compatibility -- will be removed in a future release.
# Before the split, the PAGI distribution bundled the reference server and the
# application toolkit, so anything with `requires 'PAGI'` in its cpanfile got
# them. To avoid breaking those dependents, installing PAGI continues to pull
# in PAGI-Server and PAGI-Tools, exactly as before. If you use the server or
# the toolkit, please depend on PAGI::Server and/or PAGI::Tools directly.
requires 'PAGI::Server', '0.002005';
requires 'PAGI::Tools', '0.002001';

on 'test' => sub {
    requires 'Test2::V0',          '0.000159';
    requires 'Future::AsyncAwait', '0.38';
    requires 'IO::Async',          '0.78';
    requires 'Future::IO',         '0.08';
    requires 'Test::Pod',          '1.41';
};

# Development / build dependencies for building the distribution with dzil.
on 'develop' => sub {
    requires 'Dist::Zilla', '6.030';
    requires 'Dist::Zilla::Plugin::MetaJSON';
    requires 'Dist::Zilla::Plugin::MetaResources';
    requires 'Dist::Zilla::Plugin::Prereqs::FromCPANfile';
};
