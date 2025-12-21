package PAGI::App::Delayed;

use strict;
use warnings;
use Future::AsyncAwait;
use Future;

=head1 NAME

PAGI::App::Delayed - Delayed/deferred response handling

=head1 SYNOPSIS

    use PAGI::App::Delayed;

    # Delay response by fixed time
    my $app = PAGI::App::Delayed->new(
        app   => $inner_app,
        delay => 1.5,  # seconds
    )->to_app;

    # Delay until Future resolves
    my $app = PAGI::App::Delayed->new(
        app  => $inner_app,
        wait => sub { $some_future },
    )->to_app;

=cut

sub new {
    my ($class, %args) = @_;

    return bless {
        app     => $args{app},
        delay   => $args{delay},
        wait    => $args{wait},
        timeout => $args{timeout},
    }, $class;
}

sub to_app {
    my ($self) = @_;

    my $app = $self->{app};
    my $delay = $self->{delay};
    my $wait = $self->{wait};
    my $timeout = $self->{timeout};

    return async sub  {
        my ($scope, $receive, $send) = @_;
        # Apply delay
        if (defined $delay && $delay > 0) {
            await _sleep($delay);
        }

        # Wait for condition
        if ($wait) {
            my $future = $wait->($scope);
            if ($future && $future->isa('Future')) {
                if ($timeout) {
                    my $timer = _sleep($timeout)->then(sub {
                        Future->fail('timeout');
                    });
                    eval {
                        await Future->wait_any($future, $timer);
                    };
                    if ($@ && $@ =~ /timeout/) {
                        await $send->({
                            type    => 'http.response.start',
                            status  => 504,
                            headers => [['content-type', 'text/plain']],
                        });
                        await $send->({
                            type => 'http.response.body',
                            body => 'Gateway Timeout',
                            more => 0,
                        });
                        return;
                    }
                } else {
                    await $future;
                }
            }
        }

        await $app->($scope, $receive, $send);
    };
}

# Simple async sleep using IO::Async if available
sub _sleep {
    my ($seconds) = @_;

    # Try to use IO::Async::Timer if in an IO::Async loop
    eval {
        require IO::Async::Loop;
        my $loop = IO::Async::Loop->new;
        return $loop->delay_future(after => $seconds);
    };

    # Fallback to blocking sleep (not ideal but works)
    return Future->call(sub {
        select(undef, undef, undef, $seconds);
        return Future->done;
    });
}

1;

__END__

=head1 DESCRIPTION

Delays response processing by a fixed time or until a Future resolves.
Useful for implementing debouncing, polling delays, or waiting for
external conditions.

=head1 OPTIONS

=over 4

=item * C<app> - The inner application

=item * C<delay> - Fixed delay in seconds before processing

=item * C<wait> - Coderef returning a Future to wait for

=item * C<timeout> - Maximum wait time (returns 504 if exceeded)

=back

=head1 USE CASES

=over 4

=item * Rate limiting with delay instead of rejection

=item * Implementing long-polling

=item * Waiting for resource availability

=item * Debouncing rapid requests

=back

=cut
