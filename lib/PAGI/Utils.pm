package PAGI::Utils;

use strict;
use warnings;
use Exporter 'import';
use Future::AsyncAwait;
use Carp qw(croak);
use PAGI::Lifespan;

our @EXPORT_OK = qw(handle_lifespan);
our %EXPORT_TAGS = (all => \@EXPORT_OK);

async sub handle_lifespan {
    my ($scope, $receive, $send, %opts) = @_;

    my $type = $scope->{type} // '';
    croak "handle_lifespan called with scope type '$type' (expected 'lifespan'). "
        . "Check scope type before calling: "
        . "return await handle_lifespan(...) if \$scope->{type} eq 'lifespan'"
        unless $type eq 'lifespan';

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

    return await handle_lifespan($scope, $receive, $send,
        startup  => async sub { my ($state) = @_; ... },
        shutdown => async sub { my ($state) = @_; ... },
    ) if $scope->{type} eq 'lifespan';

Consumes lifespan events, runs registered startup/shutdown hooks, and sends
the appropriate completion messages. Hooks are taken from
C<< $scope->{'pagi.lifespan.handlers'} >>, and optional C<startup> and
C<shutdown> callbacks can be passed in via C<%opts>.

B<Important:> This function will C<croak> if called with a non-lifespan scope.
Always check C<< $scope->{type} eq 'lifespan' >> before calling, as shown
in the synopsis.

=cut
