package PAGI::Middleware::RequestId;

use strict;
use warnings;
use experimental 'signatures';
use parent 'PAGI::Middleware';
use Future::AsyncAwait;

=head1 NAME

PAGI::Middleware::RequestId - Unique request ID middleware

=head1 SYNOPSIS

    use PAGI::Middleware::Builder;

    my $app = builder {
        enable 'RequestId',
            header       => 'X-Request-ID',
            trust_incoming => 0;
        $my_app;
    };

=head1 DESCRIPTION

PAGI::Middleware::RequestId generates unique request IDs and adds them
to both the scope and response headers. This is useful for request
tracing and log correlation.

=head1 CONFIGURATION

=over 4

=item * header (default: 'X-Request-ID')

The header name to use for the request ID.

=item * trust_incoming (default: 0)

If true, use an existing request ID from the incoming request headers
instead of generating a new one.

=item * generator (default: built-in UUID generator)

A coderef that generates unique IDs. Receives the scope as argument.

=back

=cut

# Simple counter for uniqueness within process
my $counter = 0;

sub _init ($self, $config) {
    $self->{header}         = $config->{header} // 'X-Request-ID';
    $self->{trust_incoming} = $config->{trust_incoming} // 0;
    $self->{generator}      = $config->{generator} // \&_generate_id;
}

sub _generate_id ($scope = undef) {
    # Generate a UUID-like ID: timestamp + counter + random
    my $time = time();
    $counter = ($counter + 1) % 0xFFFF;
    my $rand = int(rand(0xFFFFFFFF));
    return sprintf('%08x-%04x-%04x-%04x-%012x',
        $time,
        $$,
        $counter,
        int(rand(0xFFFF)),
        $rand
    );
}

sub wrap ($self, $app) {
    my $header_name = lc($self->{header});

    return async sub ($scope, $receive, $send) {
        # Only handle HTTP requests
        if ($scope->{type} ne 'http') {
            await $app->($scope, $receive, $send);
            return;
        }

        # Check for existing request ID if trust_incoming is enabled
        my $request_id;
        if ($self->{trust_incoming}) {
            for my $h (@{$scope->{headers} // []}) {
                if (lc($h->[0]) eq $header_name) {
                    $request_id = $h->[1];
                    last;
                }
            }
        }

        # Generate new ID if none found
        $request_id //= $self->{generator}->($scope);

        # Add request ID to scope
        my $modified_scope = $self->modify_scope($scope, {
            request_id => $request_id,
        });

        # Intercept send to add request ID to response
        my $wrapped_send = async sub ($event) {
            if ($event->{type} eq 'http.response.start') {
                push @{$event->{headers}}, [$self->{header}, $request_id];
            }
            await $send->($event);
        };

        await $app->($modified_scope, $receive, $wrapped_send);
    };
}

1;

__END__

=head1 GENERATED IDS

The default ID generator creates IDs in the format:

    TTTTTTTT-PPPP-CCCC-RRRR-RRRRRRRRRRRR

Where:
- TTTTTTTT: Unix timestamp (hex)
- PPPP: Process ID (hex)
- CCCC: Counter (hex)
- RRRR-RRRRRRRRRRRR: Random bytes (hex)

This ensures uniqueness across processes and restarts.

=head1 SEE ALSO

L<PAGI::Middleware> - Base class for middleware

=cut
