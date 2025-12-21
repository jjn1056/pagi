use strict;
use warnings;
use Test2::V0;
use IO::Async::Loop;
use Net::Async::HTTP;
use Future::AsyncAwait;
use Scalar::Util qw(refaddr);
use File::Temp qw(tempfile);

use PAGI::Server;

# Test: Fork Loop Isolation
# This test verifies that child processes in multi-worker mode get
# a fresh IO::Async::Loop instance, not the parent's cached $ONE_TRUE_LOOP.
#
# Background: IO::Async::Loop uses a singleton pattern via $ONE_TRUE_LOOP.
# When using $loop->fork(), this is properly cleared in the child.
# When using POSIX fork() directly (as PAGI::Server currently does),
# the child may incorrectly receive the parent's cached loop.

my $loop = IO::Async::Loop->new;

# Capture the parent's loop address for comparison
my $parent_loop_addr = refaddr($loop);

subtest 'Child process gets fresh loop (not parent cached)' => sub {
    # Create a temp file for the worker to report its loop address
    my ($fh, $filename) = tempfile(UNLINK => 1);
    close($fh);

    # App that reports the loop state
    my $diagnostic_app = async sub  {
        my ($scope, $receive, $send) = @_;
        if ($scope->{type} eq 'lifespan') {
            # During lifespan startup, capture loop info
            while (1) {
                my $event = await $receive->();
                if ($event->{type} eq 'lifespan.startup') {
                    # Get the current loop and check $ONE_TRUE_LOOP
                    my $worker_loop = IO::Async::Loop->new;
                    my $worker_loop_addr = refaddr($worker_loop);

                    # Check if $ONE_TRUE_LOOP is defined (it shouldn't be if fork was done correctly)
                    my $one_true_loop_defined = defined($IO::Async::Loop::ONE_TRUE_LOOP) ? 1 : 0;
                    my $one_true_loop_addr = $one_true_loop_defined
                        ? refaddr($IO::Async::Loop::ONE_TRUE_LOOP)
                        : 0;

                    # Write diagnostic info to temp file
                    open my $out, '>', $filename or die "Cannot write to $filename: $!";
                    print $out "worker_loop_addr=$worker_loop_addr\n";
                    print $out "one_true_loop_defined=$one_true_loop_defined\n";
                    print $out "one_true_loop_addr=$one_true_loop_addr\n";
                    print $out "parent_loop_addr=$parent_loop_addr\n";
                    print $out "pid=$$\n";
                    close $out;

                    await $send->({ type => 'lifespan.startup.complete' });
                }
                elsif ($event->{type} eq 'lifespan.shutdown') {
                    await $send->({ type => 'lifespan.shutdown.complete' });
                    return;
                }
            }
        }
        elsif ($scope->{type} eq 'http') {
            # Drain request
            while (1) {
                my $event = await $receive->();
                last if $event->{type} ne 'http.request';
                last unless $event->{more};
            }

            await $send->({
                type    => 'http.response.start',
                status  => 200,
                headers => [['content-type', 'text/plain']],
            });
            await $send->({
                type => 'http.response.body',
                body => "OK from worker $$",
                more => 0,
            });
        }
        else {
            die "Unsupported scope type: $scope->{type}";
        }
    };

    # Create multi-worker server
    my $server = PAGI::Server->new(
        app     => $diagnostic_app,
        host    => '127.0.0.1',
        port    => 0,
        workers => 1,  # Just need one worker to test
        quiet   => 1,
    );

    $loop->add($server);

    # Start the server (this forks)
    # In multi-worker mode, this blocks in the parent, so we need to fork ourselves
    # to test this properly

    my $test_pid = fork();
    die "Fork failed: $!" unless defined $test_pid;

    if ($test_pid == 0) {
        # Child: run the server
        eval {
            $server->listen;
            $loop->run;  # Run the event loop (listen no longer blocks for multi-worker)
        };
        exit(0);
    }

    # Parent: wait for server to start, then check results
    sleep(2);  # Give server time to start and write diagnostic file

    # Read diagnostic info
    my %diag;
    if (-e $filename && -s $filename) {
        open my $in, '<', $filename or die "Cannot read $filename: $!";
        while (<$in>) {
            chomp;
            my ($key, $value) = split /=/, $_, 2;
            $diag{$key} = $value;
        }
        close $in;
    }

    # Clean up server
    kill 'TERM', $test_pid;
    waitpid($test_pid, 0);

    # Now check the results
    ok(exists $diag{worker_loop_addr}, 'Worker reported loop address');
    ok(exists $diag{parent_loop_addr}, 'Worker reported parent loop address');

    if (exists $diag{worker_loop_addr} && exists $diag{parent_loop_addr}) {
        # THE KEY TEST: Worker should have a DIFFERENT loop than parent
        # If $ONE_TRUE_LOOP was properly cleared, the worker's loop should be new
        isnt(
            $diag{worker_loop_addr},
            $diag{parent_loop_addr},
            'Worker has different loop instance than parent (fork isolation working)'
        );

        # Additional check: if $ONE_TRUE_LOOP is defined in child,
        # it should point to the worker's new loop, not parent's
        if ($diag{one_true_loop_defined}) {
            isnt(
                $diag{one_true_loop_addr},
                $diag{parent_loop_addr},
                '$ONE_TRUE_LOOP in child does not point to parent loop'
            );
        }
    }

    # Debug output
    diag("Parent loop addr: $parent_loop_addr");
    diag("Worker loop addr: " . ($diag{worker_loop_addr} // 'unknown'));
    diag("ONE_TRUE_LOOP defined in child: " . ($diag{one_true_loop_defined} // 'unknown'));
    diag("ONE_TRUE_LOOP addr in child: " . ($diag{one_true_loop_addr} // 'unknown'));
    diag("Worker PID: " . ($diag{pid} // 'unknown'));
};

# Test with different loop backends (skip if not available)
subtest 'Loop isolation with IO::Async::Loop::Poll' => sub {
    # Poll is always available as it's part of core IO::Async
    pass('Poll backend test placeholder - will be expanded in Step 2');
};

subtest 'Loop isolation with IO::Async::Loop::Select' => sub {
    # Select is always available
    pass('Select backend test placeholder - will be expanded in Step 2');
};

subtest 'Loop isolation with IO::Async::Loop::Epoll' => sub {
    eval { require IO::Async::Loop::Epoll };
    if ($@) {
        skip_all('IO::Async::Loop::Epoll not installed');
        return;
    }
    pass('Epoll backend test placeholder - will be expanded in Step 2');
};

subtest 'Loop isolation with IO::Async::Loop::EV' => sub {
    eval { require IO::Async::Loop::EV };
    if ($@) {
        skip_all('IO::Async::Loop::EV not installed');
        return;
    }
    pass('EV backend test placeholder - will be expanded in Step 2');
};

done_testing;
