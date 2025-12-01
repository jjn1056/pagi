package PAGI::Middleware::Head;

use strict;
use warnings;
use experimental 'signatures';
use parent 'PAGI::Middleware';
use Future::AsyncAwait;

=head1 NAME

PAGI::Middleware::Head - HEAD request handling middleware

=head1 SYNOPSIS

    use PAGI::Middleware::Builder;

    my $app = builder {
        enable 'Head';
        $my_app;
    };

=head1 DESCRIPTION

PAGI::Middleware::Head handles HEAD requests by suppressing the response
body while preserving all headers. The inner application runs normally
(as if it were a GET request), allowing Content-Length and other headers
to be calculated, but the body is not sent to the client.

This middleware changes the method from HEAD to GET before passing to the
inner app, then suppresses the body in the response.

=head1 CONFIGURATION

No configuration options.

=cut

sub wrap ($self, $app) {
    return async sub ($scope, $receive, $send) {
        # Skip for non-HTTP requests
        if ($scope->{type} ne 'http') {
            await $app->($scope, $receive, $send);
            return;
        }

        # Only handle HEAD requests
        my $is_head = $scope->{method} eq 'HEAD';

        if (!$is_head) {
            await $app->($scope, $receive, $send);
            return;
        }

        # Change HEAD to GET for inner app
        my $modified_scope = $self->modify_scope($scope, { method => 'GET' });

        # Intercept send to suppress body
        my $wrapped_send = async sub ($event) {
            my $type = $event->{type};

            if ($type eq 'http.response.start') {
                # Pass through headers as-is (including Content-Length)
                await $send->($event);
            }
            elsif ($type eq 'http.response.body') {
                # Suppress body content but preserve the event structure
                # Send an empty body with more => 0 to complete the response
                if (!$event->{more}) {
                    await $send->({
                        type => 'http.response.body',
                        body => '',
                        more => 0,
                    });
                }
                # Otherwise, skip the event entirely (streaming chunks)
            }
            elsif ($type eq 'http.response.trailers') {
                # Skip trailers for HEAD requests
            }
            else {
                # Pass through other events
                await $send->($event);
            }
        };

        await $app->($modified_scope, $receive, $wrapped_send);
    };
}

1;

__END__

=head1 NOTES

=over 4

=item * HEAD requests are converted to GET for the inner app, so the
app can calculate Content-Length normally.

=item * The body is suppressed in the response, but headers are preserved.

=item * This middleware should be placed BEFORE ContentLength middleware
in the stack, so Content-Length is calculated from the GET response.

=item * Trailers are also suppressed for HEAD requests.

=back

=head1 SEE ALSO

L<PAGI::Middleware> - Base class for middleware

L<PAGI::Middleware::ContentLength> - Auto Content-Length header

=cut
