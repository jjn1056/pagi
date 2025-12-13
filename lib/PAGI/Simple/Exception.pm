package PAGI::Simple::Exception;

use strict;
use warnings;
use experimental 'signatures';

=head1 NAME

PAGI::Simple::Exception - Simple exception class for PAGI::Simple

=head1 SYNOPSIS

    use PAGI::Simple::Exception;

    die PAGI::Simple::Exception->new(
        message => "Missing required parameters: name, email",
        status  => 400,
    );

    # Catching:
    eval { ... };
    if (my $e = $@) {
        if (blessed($e) && $e->isa('PAGI::Simple::Exception')) {
            my $status = $e->status;
            my $msg = $e->message;
        }
    }

=head1 DESCRIPTION

A minimal exception class that carries a message and an HTTP status code.
Used by L<PAGI::Simple::StructuredParams> for validation errors.

=cut

use overload
    '""' => sub { shift->message },
    fallback => 1;

sub new ($class, %args) {
    return bless {
        message => $args{message} // 'An error occurred',
        status  => $args{status} // 500,
    }, $class;
}

=head2 message

    my $msg = $exception->message;

Returns the error message.

=cut

sub message ($self) {
    return $self->{message};
}

=head2 status

    my $status = $exception->status;

Returns the HTTP status code (e.g., 400 for bad request).

=cut

sub status ($self) {
    return $self->{status};
}

1;
