package PAGI::Utils;

use strict;
use warnings;
use Exporter 'import';
use Future::AsyncAwait;
use PAGI::Lifespan;

our @EXPORT_OK = qw(handle_lifespan);
our %EXPORT_TAGS = (all => \@EXPORT_OK);

async sub handle_lifespan {
    my ($scope, $receive, $send, %opts) = @_;

    return 0 unless $scope && ($scope->{type} // '') eq 'lifespan';

    my $manager = PAGI::Lifespan->for_scope($scope);
    $manager->register(%opts) if $opts{startup} || $opts{shutdown};

    return await $manager->handle($scope, $receive, $send);
}

1;

__END__

=head1 NAME

PAGI::Utils - Shared utility helpers for PAGI

=head1 SYNOPSIS

    use PAGI::Utils qw(handle_lifespan);

    return await handle_lifespan($scope, $receive, $send,
        startup  => async sub { my ($state) = @_; ... },
        shutdown => async sub { my ($state) = @_; ... },
    ) if $scope->{type} eq 'lifespan';

=head1 FUNCTIONS

=head2 handle_lifespan

    await handle_lifespan($scope, $receive, $send, %opts);

Consumes lifespan events, runs registered startup/shutdown hooks, and sends
the appropriate completion messages. Hooks are taken from
C<< $scope->{'pagi.lifespan.handlers'} >>, and optional C<startup> and
C<shutdown> callbacks can be passed in via C<%opts>.

=cut
