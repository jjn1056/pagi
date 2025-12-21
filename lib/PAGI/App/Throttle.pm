package PAGI::App::Throttle;

use strict;
use warnings;
use Future::AsyncAwait;

=head1 NAME

PAGI::App::Throttle - Rate-limited request processing

=head1 SYNOPSIS

    use PAGI::App::Throttle;

    my $app = PAGI::App::Throttle->new(
        app      => $inner_app,
        rate     => 10,        # requests per second
        burst    => 20,        # max burst
        key_for  => sub { $_[0]->{client}[0] },  # key by IP
    )->to_app;

=cut

# Token bucket state per key
my %buckets;

sub new {
    my ($class, %args) = @_;

    return bless {
        app      => $args{app},
        rate     => $args{rate} // 10,
        burst    => $args{burst} // ($args{rate} // 10),
        key_for  => $args{key_for},
        on_limit => $args{on_limit},
        headers  => $args{headers} // 1,
    }, $class;
}

sub to_app {
    my ($self) = @_;

    my $app = $self->{app};
    my $rate = $self->{rate};
    my $burst = $self->{burst};
    my $key_for = $self->{key_for};
    my $on_limit = $self->{on_limit};
    my $add_headers = $self->{headers};

    return async sub  {
        my ($scope, $receive, $send) = @_;
        my $key = $key_for ? $key_for->($scope) : 'global';
        $key //= 'global';

        # Initialize bucket
        $buckets{$key} //= {
            tokens    => $burst,
            last_time => time(),
        };

        my $bucket = $buckets{$key};

        # Refill tokens based on elapsed time
        my $now = time();
        my $elapsed = $now - $bucket->{last_time};
        $bucket->{tokens} += $elapsed * $rate;
        $bucket->{tokens} = $burst if $bucket->{tokens} > $burst;
        $bucket->{last_time} = $now;

        # Check if request allowed
        if ($bucket->{tokens} >= 1) {
            $bucket->{tokens} -= 1;

            # Wrap send to add rate limit headers
            my $wrapped_send = $send;
            if ($add_headers) {
                $wrapped_send = async sub  {
        my ($event) = @_;
                    if ($event->{type} eq 'http.response.start') {
                        my @headers = @{$event->{headers} // []};
                        push @headers, ['x-ratelimit-limit', $burst];
                        push @headers, ['x-ratelimit-remaining', int($bucket->{tokens})];
                        push @headers, ['x-ratelimit-reset', int($now + ($burst - $bucket->{tokens}) / $rate)];
                        $event = { %$event, headers => \@headers };
                    }
                    await $send->($event);
                };
            }

            await $app->($scope, $receive, $wrapped_send);
        } else {
            # Rate limited
            my $retry_after = int((1 - $bucket->{tokens}) / $rate) + 1;

            if ($on_limit) {
                await $on_limit->($scope, $receive, $send, $retry_after);
            } else {
                my @headers = (
                    ['content-type', 'text/plain'],
                    ['retry-after', $retry_after],
                );

                if ($add_headers) {
                    push @headers, ['x-ratelimit-limit', $burst];
                    push @headers, ['x-ratelimit-remaining', 0];
                    push @headers, ['x-ratelimit-reset', int($now + $retry_after)];
                }

                await $send->({
                    type    => 'http.response.start',
                    status  => 429,
                    headers => \@headers,
                });
                await $send->({
                    type => 'http.response.body',
                    body => 'Too Many Requests',
                    more => 0,
                });
            }
        }
    };
}

# Class method to reset a key's bucket
sub reset {
    my ($class, $key) = @_;

    delete $buckets{$key};
}

# Class method to reset all buckets
sub reset_all {
    my ($class) = @_;

    %buckets = ();
}

# Class method to get bucket info
sub info {
    my ($class, $key) = @_;

    return undef unless $buckets{$key};
    return {
        tokens => $buckets{$key}{tokens},
        last_time => $buckets{$key}{last_time},
    };
}

1;

__END__

=head1 DESCRIPTION

Token bucket rate limiting for PAGI applications. Limits requests
based on configurable rate and burst settings.

=head1 OPTIONS

=over 4

=item * C<app> - The inner application to rate limit

=item * C<rate> - Requests per second (default: 10)

=item * C<burst> - Maximum burst size (default: rate)

=item * C<key_for> - Coderef to extract rate limit key from scope

=item * C<on_limit> - Custom handler for rate-limited requests

=item * C<headers> - Add rate limit headers (default: 1)

=back

=head1 RATE LIMIT HEADERS

When enabled, adds these headers:

=over 4

=item * X-RateLimit-Limit - Maximum requests allowed

=item * X-RateLimit-Remaining - Requests remaining

=item * X-RateLimit-Reset - Unix timestamp when limit resets

=back

=head1 CLASS METHODS

=head2 reset($key)

Reset the token bucket for a specific key.

=head2 reset_all()

Reset all token buckets.

=head2 info($key)

Get bucket info (tokens, last_time) for a key.

=cut
