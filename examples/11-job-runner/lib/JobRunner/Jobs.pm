package JobRunner::Jobs;

use strict;
use warnings;

use Exporter 'import';
use Future::AsyncAwait;
use IO::Async::Timer::Countdown;

our @EXPORT_OK = qw(
    get_job_types get_job_type
    validate_job_params execute_job
);

# Job type definitions
my %JOB_TYPES = (
    countdown => {
        name        => 'countdown',
        description => 'Count down from N seconds',
        params      => [
            {
                name    => 'seconds',
                type    => 'integer',
                default => 10,
                min     => 1,
                max     => 60,
                description => 'Number of seconds to count down',
            },
        ],
        execute => \&_execute_countdown,
    },

    prime => {
        name        => 'prime',
        description => 'Find prime numbers up to N',
        params      => [
            {
                name    => 'limit',
                type    => 'integer',
                default => 1000,
                min     => 10,
                max     => 100000,
                description => 'Find primes up to this number',
            },
        ],
        execute => \&_execute_prime,
    },

    fibonacci => {
        name        => 'fibonacci',
        description => 'Calculate Fibonacci sequence',
        params      => [
            {
                name    => 'count',
                type    => 'integer',
                default => 20,
                min     => 5,
                max     => 50,
                description => 'Number of Fibonacci numbers to calculate',
            },
        ],
        execute => \&_execute_fibonacci,
    },

    echo => {
        name        => 'echo',
        description => 'Echo a message after delay',
        params      => [
            {
                name    => 'message',
                type    => 'string',
                default => 'Hello, World!',
                max_length => 200,
                description => 'Message to echo back',
            },
            {
                name    => 'delay',
                type    => 'integer',
                default => 3,
                min     => 1,
                max     => 30,
                description => 'Delay in seconds before echoing',
            },
        ],
        execute => \&_execute_echo,
    },
);

#
# Job Type Registry
#

sub get_job_types {
    my () = @_;

    return [
        map {
            {
                name        => $_->{name},
                description => $_->{description},
                params      => $_->{params},
            }
        }
        values %JOB_TYPES
    ];
}

sub get_job_type {
    my ($name) = @_;

    return $JOB_TYPES{$name};
}

#
# Parameter Validation
#

sub validate_job_params {
    my ($type_name, $params) = @_;

    my $job_type = $JOB_TYPES{$type_name};

    unless ($job_type) {
        return (0, "Unknown job type: $type_name");
    }

    $params //= {};

    # Validate each defined parameter
    for my $param_def (@{$job_type->{params}}) {
        my $name = $param_def->{name};
        my $value = $params->{$name} // $param_def->{default};

        # Check if value is present (after applying default)
        unless (defined $value) {
            return (0, "Missing required parameter: $name");
        }

        # Type validation
        if ($param_def->{type} eq 'integer') {
            unless ($value =~ /^\d+$/) {
                return (0, "Parameter '$name' must be an integer");
            }
            $value = int($value);

            # Range validation
            if (defined $param_def->{min} && $value < $param_def->{min}) {
                return (0, "Parameter '$name' must be at least $param_def->{min}");
            }
            if (defined $param_def->{max} && $value > $param_def->{max}) {
                return (0, "Parameter '$name' must be at most $param_def->{max}");
            }
        }
        elsif ($param_def->{type} eq 'string') {
            unless (length $value) {
                return (0, "Parameter '$name' cannot be empty");
            }
            if (defined $param_def->{max_length} && length($value) > $param_def->{max_length}) {
                return (0, "Parameter '$name' is too long (max $param_def->{max_length})");
            }
        }
        elsif ($param_def->{type} eq 'array') {
            unless (ref $value eq 'ARRAY') {
                return (0, "Parameter '$name' must be an array");
            }
            if (defined $param_def->{max_items} && @$value > $param_def->{max_items}) {
                return (0, "Parameter '$name' has too many items (max $param_def->{max_items})");
            }
        }

        # Store validated/normalized value back
        $params->{$name} = $value;
    }

    return (1, undef, $params);
}

#
# Job Execution
#

sub execute_job {
    my ($job, $loop, $progress_cb, $cancel_check) = @_;

    my $job_type = $JOB_TYPES{$job->{type}};

    unless ($job_type) {
        return Future->fail("Unknown job type: $job->{type}");
    }

    return $job_type->{execute}->($job, $loop, $progress_cb, $cancel_check);
}

#
# Job Type Implementations
#

async sub _execute_countdown {
    my ($job, $loop, $progress_cb, $cancel_check) = @_;

    my $seconds = $job->{params}{seconds} // 10;
    my $remaining = $seconds;

    while ($remaining > 0) {
        # Check for cancellation
        if ($cancel_check->()) {
            die "Job cancelled";
        }

        # Calculate progress
        my $elapsed = $seconds - $remaining;
        my $percent = int(($elapsed / $seconds) * 100);
        my $message = "$remaining second" . ($remaining == 1 ? '' : 's') . " remaining...";

        $progress_cb->($percent, $message);

        # Wait 1 second
        await _delay($loop, 1);

        $remaining--;
    }

    # Final progress update
    $progress_cb->(100, 'Complete!');

    return {
        message  => "Countdown complete!",
        duration => $seconds,
    };
}

async sub _execute_prime {
    my ($job, $loop, $progress_cb, $cancel_check) = @_;

    my $limit = $job->{params}{limit} // 1000;
    my @primes;
    my $checked = 0;
    my $last_update = 0;

    for my $n (2 .. $limit) {
        # Check for cancellation periodically
        if ($cancel_check->()) {
            die "Job cancelled";
        }

        # Check if prime
        my $is_prime = 1;
        for my $d (2 .. int(sqrt($n))) {
            if ($n % $d == 0) {
                $is_prime = 0;
                last;
            }
        }
        push @primes, $n if $is_prime;

        $checked++;

        # Update progress every 5%
        my $percent = int(($checked / ($limit - 1)) * 100);
        if ($percent >= $last_update + 5) {
            $progress_cb->($percent, "Checked $checked numbers, found " . scalar(@primes) . " primes...");
            $last_update = $percent;

            # Yield to event loop periodically
            await _delay($loop, 0.01) if $percent % 20 == 0;
        }
    }

    $progress_cb->(100, 'Complete!');

    return {
        message     => "Found " . scalar(@primes) . " prime numbers up to $limit",
        prime_count => scalar(@primes),
        largest     => $primes[-1],
        sample      => [ @primes[0..9] ],  # First 10 primes
    };
}

async sub _execute_fibonacci {
    my ($job, $loop, $progress_cb, $cancel_check) = @_;

    my $count = $job->{params}{count} // 20;
    my @fib = (0, 1);

    for my $i (2 .. $count - 1) {
        if ($cancel_check->()) {
            die "Job cancelled";
        }

        push @fib, $fib[-1] + $fib[-2];

        my $percent = int(($i / ($count - 1)) * 100);
        $progress_cb->($percent, "Calculated F($i) = $fib[-1]");

        # Small delay to make progress visible
        await _delay($loop, 0.1);
    }

    $progress_cb->(100, 'Complete!');

    return {
        message  => "Calculated $count Fibonacci numbers",
        count    => $count,
        sequence => \@fib,
        last     => $fib[-1],
    };
}

async sub _execute_echo {
    my ($job, $loop, $progress_cb, $cancel_check) = @_;

    my $message = $job->{params}{message} // 'Hello, World!';
    my $delay = $job->{params}{delay} // 3;

    for my $i (1 .. $delay) {
        if ($cancel_check->()) {
            die "Job cancelled";
        }

        my $remaining = $delay - $i + 1;
        my $percent = int((($i - 1) / $delay) * 100);
        $progress_cb->($percent, "Echoing in $remaining second" . ($remaining == 1 ? '' : 's') . "...");

        await _delay($loop, 1);
    }

    $progress_cb->(100, 'Complete!');

    return {
        message => $message,
        echoed  => $message,
        delay   => $delay,
    };
}

#
# Utility Functions
#

sub _delay {
    my ($loop, $seconds) = @_;

    my $future = $loop->new_future;

    my $timer = IO::Async::Timer::Countdown->new(
        delay     => $seconds,
        on_expire => sub { $future->done },
    );

    $loop->add($timer);
    $timer->start;

    return $future->on_done(sub {
        $loop->remove($timer);
    })->on_fail(sub {
        $loop->remove($timer);
    });
}

1;

__END__

# NAME

JobRunner::Jobs - Job type definitions and execution

# DESCRIPTION

Defines available job types, their parameters, and execution logic.

## Job Types

- **countdown** - Count down from N seconds with progress updates
- **prime** - Find all prime numbers up to N
- **fibonacci** - Calculate Fibonacci sequence up to N terms
- **echo** - Echo a message back after a delay
