# PAGI specification distribution.
#
# The spec modules (PAGI.pm + the generated PAGI::Spec::* POD) are pure
# documentation, so the only runtime requirement is Perl. Through the 0.002
# releases, installing PAGI also installed PAGI-Server and PAGI-Tools, for
# code that relied on `requires 'PAGI'` from before the split; since 0.003000
# it does not. Require PAGI::Server and/or PAGI::Tools directly.

requires 'perl', '5.018';

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
