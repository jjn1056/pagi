package PAGI::Middleware::RateLimit;

use strict;
use warnings;
use parent 'PAGI::Middleware';
use Future::AsyncAwait;

=head1 NAME

PAGI::Middleware::RateLimit - Request rate limiting middleware

=head1 SYNOPSIS

    use PAGI::Middleware::Builder;

    my $app = builder {
        enable 'RateLimit',
            requests_per_second => 10,
            burst => 20,
            key_generator => sub  {
        my ($scope) = @_; $scope->{client}[0] };
        $my_app;
    };

=head1 DESCRIPTION

PAGI::Middleware::RateLimit implements token bucket rate limiting per client.
Clients exceeding the rate limit receive 429 Too Many Requests.

=head1 CONFIGURATION

=over 4

=item * requests_per_second (default: 10)

Average requests allowed per second.

=item * burst (default: 20)

Maximum burst size (bucket capacity).

=item * key_generator (default: client IP)

Coderef to generate rate limit key from $scope.

=item * backend (default: in-memory)

Rate limit storage backend. Can be 'memory' or a custom object
implementing get/set methods.

=item * cleanup_interval (default: 60)

Seconds between periodic cleanup of stale buckets.

=item * max_buckets (default: 10000)

Maximum number of tracked client buckets. When exceeded, the oldest
half are evicted as a safety valve.

=back

=cut

my %buckets;  # In-memory storage
my $_time_offset = 0;

sub _clear_buckets { %buckets = (); $_time_offset = 0; }
sub _bucket_count  { return scalar keys %buckets }
sub _advance_time_for_test { $_time_offset += $_[1] }
sub _now { return time() + $_time_offset }

sub _init {
    my ($self, $config) = @_;

    $self->{requests_per_second} = $config->{requests_per_second} // 10;
    $self->{burst} = $config->{burst} // 20;
    $self->{key_generator} = $config->{key_generator} // sub  {
        my ($scope) = @_;
        return $scope->{client}[0] // 'unknown';
    };
    $self->{backend} = $config->{backend} // 'memory';
    $self->{cleanup_interval} = $config->{cleanup_interval} // 60;
    $self->{max_buckets}      = $config->{max_buckets} // 10_000;
}

sub wrap {
    my ($self, $app) = @_;

    return async sub  {
        my ($scope, $receive, $send) = @_;
        if ($scope->{type} ne 'http') {
            await $app->($scope, $receive, $send);
            return;
        }

        my $key = $self->{key_generator}->($scope);
        my ($allowed, $remaining, $reset) = $self->_check_rate_limit($key);

        if (!$allowed) {
            await $self->_send_rate_limited($send, $remaining, $reset);
            return;
        }

        # Add rate limit headers to response
        my $wrapped_send = async sub  {
        my ($event) = @_;
            if ($event->{type} eq 'http.response.start') {
                my @headers = @{$event->{headers} // []};
                push @headers, ['X-RateLimit-Limit', $self->{burst}];
                push @headers, ['X-RateLimit-Remaining', $remaining];
                push @headers, ['X-RateLimit-Reset', $reset];
                await $send->({
                    %$event,
                    headers => \@headers,
                });
            } else {
                await $send->($event);
            }
        };

        await $app->($scope, $receive, $wrapped_send);
    };
}

sub _check_rate_limit {
    my ($self, $key) = @_;

    my $now = _now();
    my $rate = $self->{requests_per_second};
    my $burst = $self->{burst};

    # Get or initialize bucket
    my $bucket = $buckets{$key} //= {
        tokens    => $burst,
        last_time => $now,
    };

    # Refill tokens based on time elapsed
    my $elapsed = $now - $bucket->{last_time};
    my $refill = $elapsed * $rate;
    $bucket->{tokens} = $bucket->{tokens} + $refill;
    $bucket->{tokens} = $burst if $bucket->{tokens} > $burst;
    $bucket->{last_time} = $now;

    # Determine rate limit result
    my @result;
    if ($bucket->{tokens} >= 1) {
        $bucket->{tokens} -= 1;
        my $remaining = int($bucket->{tokens});
        my $reset = $now + int(($burst - $bucket->{tokens}) / $rate);
        @result = (1, $remaining, $reset);  # Allowed
    } else {
        my $wait_time = (1 - $bucket->{tokens}) / $rate;
        my $reset = $now + int($wait_time) + 1;
        @result = (0, 0, $reset);  # Not allowed
    }

    # Periodic cleanup of stale buckets
    if (!$self->{_last_cleanup} || ($now - $self->{_last_cleanup}) >= $self->{cleanup_interval}) {
        $self->{_last_cleanup} = $now;
        my $stale_threshold = $now - (2 * $burst / $rate);
        for my $k (keys %buckets) {
            delete $buckets{$k} if $buckets{$k}{last_time} < $stale_threshold;
        }
    }

    # Safety valve: evict oldest buckets when over max
    if (keys %buckets > $self->{max_buckets}) {
        my @sorted = sort { $buckets{$a}{last_time} <=> $buckets{$b}{last_time} } keys %buckets;
        my $to_remove = @sorted - int($self->{max_buckets} / 2);
        delete $buckets{$_} for @sorted[0 .. $to_remove - 1];
    }

    return @result;
}

async sub _send_rate_limited {
    my ($self, $send, $remaining, $reset) = @_;

    my $retry_after = $reset - _now();
    $retry_after = 1 if $retry_after < 1;

    my $body = 'Rate limit exceeded. Try again later.';

    await $send->({
        type    => 'http.response.start',
        status  => 429,
        headers => [
            ['Content-Type', 'text/plain'],
            ['Content-Length', length($body)],
            ['Retry-After', $retry_after],
            ['X-RateLimit-Limit', $self->{burst}],
            ['X-RateLimit-Remaining', 0],
            ['X-RateLimit-Reset', $reset],
        ],
    });
    await $send->({
        type => 'http.response.body',
        body => $body,
        more => 0,
    });
}

# Class method to reset rate limits (useful for testing)
sub reset_all {
    _clear_buckets();
}

1;

__END__

=head1 RATE LIMITING ALGORITHM

This middleware uses the token bucket algorithm:

=over 4

=item * Each client has a "bucket" that holds tokens

=item * Tokens are added at a constant rate (requests_per_second)

=item * The bucket has a maximum capacity (burst)

=item * Each request consumes one token

=item * If no tokens available, request is rejected

=back

This allows short bursts of traffic while maintaining an average rate.

=head1 MULTI-WORKER NOTE

The in-memory bucket storage is per-process. In a pre-fork multi-worker
setup each worker maintains its own independent rate limit state, so the
effective rate limit is multiplied by the number of workers. For accurate
cross-worker rate limiting, use an external backend such as Redis.

=head1 SEE ALSO

L<PAGI::Middleware> - Base class for middleware

=cut
