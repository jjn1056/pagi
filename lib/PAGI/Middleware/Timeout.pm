package PAGI::Middleware::Timeout;

use strict;
use warnings;
use parent 'PAGI::Middleware';
use Future::AsyncAwait;
use Future;

=head1 NAME

PAGI::Middleware::Timeout - Request timeout middleware

=head1 SYNOPSIS

    use PAGI::Middleware::Builder;

    my $app = builder {
        enable 'Timeout',
            timeout => 30,
            on_timeout => sub  {
        my ($scope) = @_;
                warn "Request to $scope->{path} timed out";
            };
        $my_app;
    };

=head1 DESCRIPTION

PAGI::Middleware::Timeout enforces a maximum request duration. If the
application doesn't respond within the timeout, a 504 Gateway Timeout
response is sent.

=head1 CONFIGURATION

=over 4

=item * timeout (default: 30)

Timeout in seconds.

=item * on_timeout (optional)

Callback called when timeout occurs. Receives $scope.

=item * loop (optional)

IO::Async::Loop instance. If not provided, attempts to get current loop.

=back

=cut

sub _init {
    my ($self, $config) = @_;

    $self->{timeout} = $config->{timeout} // 30;
    $self->{on_timeout} = $config->{on_timeout};
    $self->{loop} = $config->{loop};
}

sub wrap {
    my ($self, $app) = @_;

    return async sub  {
        my ($scope, $receive, $send) = @_;
        if ($scope->{type} ne 'http') {
            await $app->($scope, $receive, $send);
            return;
        }

        my $loop = $self->{loop} // $self->_get_loop();
        my $timeout = $self->{timeout};
        my $timed_out = 0;
        my $response_started = 0;

        # Wrapped send that tracks if response started
        my $wrapped_send = async sub  {
        my ($event) = @_;
            return if $timed_out;
            if ($event->{type} eq 'http.response.start') {
                $response_started = 1;
            }
            await $send->($event);
        };

        # Create timeout future
        my $timeout_future = $loop->delay_future(after => $timeout);

        # Create app future
        my $app_future = Future->call(sub {
            return $app->($scope, $receive, $wrapped_send);
        });

        # Race between app and timeout
        my $result = await Future->wait_any(
            $app_future->then(sub { Future->done('completed') }),
            $timeout_future->then(sub { Future->done('timeout') }),
        );

        if ($result eq 'timeout' && !$response_started) {
            $timed_out = 1;

            # Call timeout callback if provided
            if ($self->{on_timeout}) {
                eval { $self->{on_timeout}->($scope) };
            }

            # Send 504 response
            await $self->_send_timeout($send);

            # Cancel the app future if still running
            $app_future->cancel if !$app_future->is_ready;
        }
    };
}

sub _get_loop {
    my ($self) = @_;

    # Try to get the current loop from IO::Async
    require IO::Async::Loop;
    return IO::Async::Loop->new;
}

async sub _send_timeout {
    my ($self, $send) = @_;

    my $body = 'Request timeout';

    await $send->({
        type    => 'http.response.start',
        status  => 504,
        headers => [
            ['Content-Type', 'text/plain'],
            ['Content-Length', length($body)],
        ],
    });
    await $send->({
        type => 'http.response.body',
        body => $body,
        more => 0,
    });
}

1;

__END__

=head1 NOTES

The timeout only applies to the time before the response headers are sent.
Once streaming has begun, the timeout no longer applies (to avoid cutting
off partial responses).

If you need to timeout the entire request including body streaming, you'll
need to implement that at the connection level in the server.

=head1 SEE ALSO

L<PAGI::Middleware> - Base class for middleware

=cut
