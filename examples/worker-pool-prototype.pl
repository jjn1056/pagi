#!/usr/bin/env perl
use v5.36;
use strict;
use warnings;

# Prototype: Future::IO-based Worker Pool
# Testing if we can make a loop-agnostic worker pool
#
# KEY INSIGHT: We can't serialize coderefs, so we use named handlers
# that are registered BEFORE forking workers.

use Future::AsyncAwait;

# Configure Future::IO to use IO::Async
BEGIN { require Future::IO::Impl::IOAsync; }

use Future::IO;
use Future;
use Storable qw(freeze thaw);
use POSIX qw(:sys_wait_h);

package WorkerPool {
    use Future::AsyncAwait;
    use Future::IO;
    use Storable qw(freeze thaw);

    sub new ($class, %opts) {
        my $self = bless {
            workers     => $opts{workers} // 2,
            init        => $opts{init},
            handlers    => $opts{handlers} // {},  # Named handlers
            worker_pids => [],
            pipes       => [],
            queue_limit => $opts{queue_limit} // 10,
        }, $class;

        $self->_start_workers();
        return $self;
    }

    sub _start_workers ($self) {
        for my $i (1 .. $self->{workers}) {
            $self->_start_worker($i);
        }
    }

    sub _start_worker ($self, $id) {
        # Create pipe pairs
        pipe(my $parent_rd, my $child_wr) or die "pipe: $!";
        pipe(my $child_rd, my $parent_wr) or die "pipe: $!";

        # Copy handlers before fork (they're already in parent memory)
        my $handlers = $self->{handlers};
        my $init = $self->{init};

        my $pid = fork();
        die "fork failed: $!" unless defined $pid;

        if ($pid == 0) {
            # Child process (worker)
            close $parent_rd;
            close $parent_wr;

            # Run init if provided
            my $state = {};
            if ($init) {
                $state = $init->() // {};
            }

            # Worker loop - blocking is fine here, we're a separate process
            while (1) {
                # Read job length (4 bytes)
                my $len_buf;
                my $n = sysread($child_rd, $len_buf, 4);
                last unless $n && $n == 4;

                my $len = unpack('N', $len_buf);

                # Read job data
                my $job_data = '';
                while (length($job_data) < $len) {
                    my $chunk;
                    sysread($child_rd, $chunk, $len - length($job_data));
                    $job_data .= $chunk;
                }

                my $job = thaw($job_data);

                # Execute the job by name
                my $result;
                my $error;
                eval {
                    my $handler_name = $job->{handler};
                    my $handler = $handlers->{$handler_name}
                        or die "Unknown handler: $handler_name";
                    my @args = @{$job->{args} // []};
                    $result = $handler->($state, @args);
                };
                $error = $@ if $@;

                # Send result back
                my $response = freeze({ result => $result, error => $error });
                my $resp_len = pack('N', length($response));
                syswrite($child_wr, $resp_len);
                syswrite($child_wr, $response);
            }

            exit(0);
        }

        # Parent process
        close $child_rd;
        close $child_wr;

        # Make pipes non-blocking for async I/O
        $parent_rd->blocking(0);
        $parent_wr->blocking(0);

        push @{$self->{worker_pids}}, $pid;
        push @{$self->{pipes}}, {
            to_worker   => $parent_wr,
            from_worker => $parent_rd,
            busy        => 0,
            id          => $id,
        };

        say "Started worker $id (PID $pid)";
    }

    sub _get_idle_worker ($self) {
        for my $w (@{$self->{pipes}}) {
            return $w unless $w->{busy};
        }
        return undef;
    }

    async sub call ($self, $handler_name, %opts) {
        my $args = $opts{args} // [];

        # Wait for an idle worker
        my $worker;
        while (!($worker = $self->_get_idle_worker())) {
            await Future::IO->sleep(0.01);
        }

        $worker->{busy} = 1;

        my $job = freeze({ handler => $handler_name, args => $args });
        my $len = pack('N', length($job));

        # Send job to worker using Future::IO
        await Future::IO->syswrite($worker->{to_worker}, $len . $job);

        # Read response length (4 bytes)
        my $resp_len_buf = await Future::IO->sysread($worker->{from_worker}, 4);
        my $resp_len = unpack('N', $resp_len_buf);

        # Read response data
        my $resp_data = '';
        while (length($resp_data) < $resp_len) {
            my $chunk = await Future::IO->sysread(
                $worker->{from_worker},
                $resp_len - length($resp_data)
            );
            $resp_data .= $chunk;
        }

        $worker->{busy} = 0;

        my $response = thaw($resp_data);

        if ($response->{error}) {
            die $response->{error};
        }

        return $response->{result};
    }

    sub shutdown ($self) {
        for my $w (@{$self->{pipes}}) {
            close $w->{to_worker};
            close $w->{from_worker};
        }
        for my $pid (@{$self->{worker_pids}}) {
            waitpid($pid, 0);
            say "Worker PID $pid exited";
        }
    }
}

# =============================================================================
# Test the prototype
# =============================================================================

async sub main () {
    say "=== Future::IO Worker Pool Prototype ===\n";

    # Create pool with named handlers (registered BEFORE forking)
    my $pool = WorkerPool->new(
        workers => 2,
        init => sub {
            return {
                worker_pid => $$,
                counter => 0,
            };
        },
        handlers => {
            # Named handlers - these are available to all workers
            hello => sub ($state) {
                sleep(1);
                return "Hello from worker PID $state->{worker_pid}";
            },
            job => sub ($state, $id) {
                sleep(1);
                $state->{counter}++;
                return "Job $id done by PID $state->{worker_pid} (count: $state->{counter})";
            },
            count => sub ($state) {
                $state->{counter}++;
                return "Counter is now $state->{counter} in PID $state->{worker_pid}";
            },
            error => sub ($state) {
                die "Intentional error!";
            },
        },
    );

    say "\n--- Test 1: Simple blocking call ---";
    my $result = await $pool->call('hello');
    say "Result: $result";

    say "\n--- Test 2: Concurrent calls (should interleave) ---";
    my $start = time();

    my @futures;
    for my $i (1..4) {
        push @futures, $pool->call('job', args => [$i]);
    }

    # Wait for all
    my @results = await Future->wait_all(@futures);

    my $elapsed = time() - $start;
    say "Results:";
    for my $f (@results) {
        say "  - " . $f->get;
    }
    say "Elapsed: ${elapsed}s (should be ~2s with 2 workers, not 4s)";

    say "\n--- Test 3: Worker state persists ---";
    for my $i (1..3) {
        my $r = await $pool->call('count');
        say "Result: $r";
    }

    say "\n--- Test 4: Error handling ---";
    eval {
        await $pool->call('error');
    };
    say "Caught error: $@" if $@;

    say "\n--- Shutting down ---";
    $pool->shutdown();

    say "\nDone!";
}

# Run it - await the main future
main()->get;
