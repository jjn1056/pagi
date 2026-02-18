package PAGI::Middleware::RequestId;

use strict;
use warnings;
use parent 'PAGI::Middleware';
use Future::AsyncAwait;
use PAGI::Utils::Random qw(secure_random_bytes);

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

sub _init {
    my ($self, $config) = @_;

    $self->{header}         = $config->{header} // 'X-Request-ID';
    $self->{trust_incoming} = $config->{trust_incoming} // 0;
    $self->{generator}      = $config->{generator} // \&_generate_id;
}

sub _generate_id {
    my ($scope) = @_;

    # Generate a UUID-like ID: timestamp + PID + counter + secure random
    my $time = time();
    $counter = ($counter + 1) % 0xFFFF;
    my $rand_bytes = secure_random_bytes(6);
    return sprintf('%08x-%04x-%04x-%s',
        $time,
        $$ & 0xFFFF,
        $counter,
        unpack('H12', $rand_bytes),
    );
}

sub wrap {
    my ($self, $app) = @_;

    my $header_name = lc($self->{header});

    return async sub  {
        my ($scope, $receive, $send) = @_;
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
        my $wrapped_send = async sub  {
        my ($event) = @_;
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

    TTTTTTTT-PPPP-CCCC-RRRRRRRRRRRR

Where:
- TTTTTTTT: Unix timestamp (hex)
- PPPP: Process ID (hex, lower 16 bits)
- CCCC: Counter (hex)
- RRRRRRRRRRRR: Cryptographically secure random bytes (hex)

This ensures uniqueness across processes and restarts. The random
component uses C<PAGI::Utils::Random::secure_random_bytes> for
unpredictability.

=head1 SEE ALSO

L<PAGI::Middleware> - Base class for middleware

=cut
