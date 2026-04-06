package PAGI::Context::SSE;

use strict;
use warnings;

our @ISA = ('PAGI::Context');

=head1 NAME

PAGI::Context::SSE - SSE-specific context subclass

=head1 DESCRIPTION

Returned by C<< PAGI::Context->new(...) >> when C<< $scope->{type} >> is
C<'sse'>. Adds a lazy accessor for L<PAGI::SSE>.

Inherits all shared methods from L<PAGI::Context>.

=head1 METHODS

=head2 sse

    my $sse = $ctx->sse;

Returns a L<PAGI::SSE> instance. Lazy-constructed and cached.

=cut

sub sse {
    my ($self) = @_;
    return $self->{_sse} //= do {
        require PAGI::SSE;
        PAGI::SSE->new($self->{scope}, $self->{receive}, $self->{send});
    };
}

1;

__END__

=head1 SEE ALSO

L<PAGI::Context>, L<PAGI::SSE>

=cut
