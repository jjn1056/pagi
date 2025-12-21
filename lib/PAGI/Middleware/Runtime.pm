package PAGI::Middleware::Runtime;

use strict;
use warnings;
use parent 'PAGI::Middleware';
use Future::AsyncAwait;
use Time::HiRes qw(time);

=head1 NAME

PAGI::Middleware::Runtime - Request timing middleware

=head1 SYNOPSIS

    use PAGI::Middleware::Builder;

    my $app = builder {
        enable 'Runtime',
            header    => 'X-Runtime',
            precision => 6;
        $my_app;
    };

=head1 DESCRIPTION

PAGI::Middleware::Runtime measures the time taken to process a request
and adds it as a response header. This is useful for performance
monitoring and debugging.

=head1 CONFIGURATION

=over 4

=item * header (default: 'X-Runtime')

The header name to use for the runtime value.

=item * precision (default: 6)

Number of decimal places for the duration in seconds.

=back

=cut

sub _init {
    my ($self, $config) = @_;

    $self->{header}    = $config->{header} // 'X-Runtime';
    $self->{precision} = $config->{precision} // 6;
}

sub wrap {
    my ($self, $app) = @_;

    return async sub  {
        my ($scope, $receive, $send) = @_;
        # Only handle HTTP requests
        if ($scope->{type} ne 'http') {
            await $app->($scope, $receive, $send);
            return;
        }

        my $start_time = time();

        # Intercept send to add runtime header
        my $wrapped_send = async sub  {
        my ($event) = @_;
            if ($event->{type} eq 'http.response.start') {
                my $duration = time() - $start_time;
                my $formatted = sprintf('%.*f', $self->{precision}, $duration);
                push @{$event->{headers}}, [$self->{header}, $formatted];
            }
            await $send->($event);
        };

        await $app->($scope, $receive, $wrapped_send);
    };
}

1;

__END__

=head1 EXAMPLE OUTPUT

The X-Runtime header contains the request processing time in seconds:

    X-Runtime: 0.001234

=head1 SEE ALSO

L<PAGI::Middleware> - Base class for middleware

L<PAGI::Middleware::AccessLog> - Access logging middleware

=cut
