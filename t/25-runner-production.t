#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use File::Temp qw(tempfile tempdir);
use POSIX qw(WNOHANG);
use FindBin;
use Time::HiRes qw(sleep);

use lib "$FindBin::Bin/../lib";
use PAGI::Runner;

# Skip on Windows - fork and daemon operations not supported
plan skip_all => 'Fork tests not supported on Windows' if $^O eq 'MSWin32';

subtest 'PID file creation and cleanup' => sub {
    my ($fh, $pid_file) = tempfile(UNLINK => 1);
    close $fh;
    unlink $pid_file;  # Remove it so we can test creation

    # Start server with PID file (use fork to isolate)
    my $pid = fork();
    die "Cannot fork: $!" unless defined $pid;

    if ($pid == 0) {
        # Child process
        my $runner = PAGI::Runner->new(
            port => 0,  # Random port
            quiet => 1,
        );
        $runner->load_app('PAGI::App::Directory', root => '.');

        # Just test PID file writing, don't run server
        $runner->_write_pid_file($pid_file);

        # Verify we wrote our own PID
        open(my $pfh, '<', $pid_file) or exit(1);
        my $written_pid = <$pfh>;
        chomp $written_pid;
        close $pfh;

        exit($written_pid == $$ ? 0 : 1);
    }

    # Parent - wait for child
    waitpid($pid, 0);
    my $exit_code = $? >> 8;

    is($exit_code, 0, 'PID file creation succeeded');
    ok(-f $pid_file, 'PID file exists');

    # Verify content
    if (-f $pid_file) {
        open(my $pfh, '<', $pid_file);
        my $written_pid = <$pfh>;
        chomp $written_pid;
        close $pfh;
        ok($written_pid =~ /^\d+$/, 'PID file contains numeric PID');
        is($written_pid, $pid, 'PID matches child process');
    }

    # Test cleanup
    my $runner = PAGI::Runner->new(port => 0, quiet => 1);
    $runner->{_pid_file_path} = $pid_file;
    $runner->_remove_pid_file;
    ok(!-f $pid_file, 'PID file removed by cleanup');
};

subtest 'PID file with actual server process' => sub {
    my ($fh, $pid_file) = tempfile(UNLINK => 1);
    close $fh;
    unlink $pid_file;

    # Fork a server process that actually runs
    my $server_pid = fork();
    die "Cannot fork: $!" unless defined $server_pid;

    if ($server_pid == 0) {
        # Child - start actual server
        my $runner = PAGI::Runner->new(
            port => 0,  # Random port
            quiet => 1,
            pid_file => $pid_file,
        );
        $runner->load_app("$FindBin::Bin/../examples/01-hello-http/app.pl");

        # Write PID file before running
        $runner->_write_pid_file($pid_file);

        # Run for a short time then exit
        alarm(2);  # Exit after 2 seconds

        eval {
            my $server = $runner->prepare_server;
            require IO::Async::Loop;
            my $loop = IO::Async::Loop->new;
            $loop->add($server);
            $server->listen->get;
            $loop->run;
        };

        # Clean up PID file on exit
        $runner->_remove_pid_file;
        exit(0);
    }

    # Parent - wait for PID file to be created
    my $retries = 20;
    while ($retries-- > 0 && !-f $pid_file) {
        sleep(0.05);
    }

    ok(-f $pid_file, 'Server created PID file');

    if (-f $pid_file) {
        open(my $pfh, '<', $pid_file);
        my $written_pid = <$pfh>;
        chomp $written_pid;
        close $pfh;

        is($written_pid, $server_pid, 'PID file contains server PID');
    }

    # Kill the server
    kill 'TERM', $server_pid;
    waitpid($server_pid, 0);

    # Give it time to clean up
    sleep(0.1);

    ok(!-f $pid_file, 'Server cleaned up PID file on exit');
};

subtest 'User/group validation' => sub {
    my $runner = PAGI::Runner->new(
        user => 'nonexistent_user_12345',
        port => 0,
        quiet => 1,
    );

    # Should fail for non-root trying to use --user
    eval { $runner->_drop_privileges };
    if ($> == 0) {
        # Running as root - should reject unknown user
        like($@, qr/Unknown user/, 'Rejects unknown user (as root)');

        # Test unknown group
        my $runner2 = PAGI::Runner->new(
            group => 'nonexistent_group_12345',
            port => 0,
            quiet => 1,
        );
        eval { $runner2->_drop_privileges };
        like($@, qr/Unknown group/, 'Rejects unknown group (as root)');
    } else {
        # Not root - should require root
        like($@, qr/Must run as root/, 'Requires root for --user');

        # Test group also requires root
        my $runner3 = PAGI::Runner->new(
            group => 'nogroup',
            port => 0,
            quiet => 1,
        );
        eval { $runner3->_drop_privileges };
        like($@, qr/Must run as root/, 'Requires root for --group');
    }
};

subtest 'CLI option parsing - daemonize' => sub {
    my $runner = PAGI::Runner->new;
    $runner->parse_options('-D');

    is($runner->{daemonize}, 1, '-D short flag sets daemonize');

    my $runner2 = PAGI::Runner->new;
    $runner2->parse_options('--daemonize');

    is($runner2->{daemonize}, 1, '--daemonize long flag sets daemonize');
};

subtest 'CLI option parsing - pid file' => sub {
    my $runner = PAGI::Runner->new;
    $runner->parse_options('--pid', '/tmp/test.pid');

    is($runner->{pid_file}, '/tmp/test.pid', '--pid option parsed');
};

subtest 'CLI option parsing - user and group' => sub {
    my $runner = PAGI::Runner->new;
    $runner->parse_options(
        '--user', 'nobody',
        '--group', 'nogroup',
    );

    is($runner->{user}, 'nobody', '--user option parsed');
    is($runner->{group}, 'nogroup', '--group option parsed');
};

subtest 'CLI option parsing - all production options together' => sub {
    my $runner = PAGI::Runner->new;
    my @remaining = $runner->parse_options(
        '-D',
        '--pid', '/var/run/pagi.pid',
        '--user', 'www-data',
        '--group', 'www-data',
        '-p', '8080',
        'app.pl',
    );

    is($runner->{daemonize}, 1, 'daemonize parsed');
    is($runner->{pid_file}, '/var/run/pagi.pid', 'pid parsed');
    is($runner->{user}, 'www-data', 'user parsed');
    is($runner->{group}, 'www-data', 'group parsed');
    is($runner->{port}, 8080, 'port also parsed');
    is(scalar @remaining, 1, 'app.pl remains');
    is($remaining[0], 'app.pl', 'correct app arg');
};

subtest 'Daemonize integration test' => sub {
    # This is a minimal test of daemonization
    # Full test would require more complex process management

    my $runner = PAGI::Runner->new(
        port => 0,
        quiet => 1,
        daemonize => 1,
    );

    ok($runner->can('_daemonize'), 'daemonize method exists');
    is($runner->{daemonize}, 1, 'daemonize flag set');
};

subtest 'PID file path storage' => sub {
    my $runner = PAGI::Runner->new(port => 0, quiet => 1);
    my $pid_file = '/tmp/test_storage.pid';

    # Create a dummy file
    open(my $fh, '>', $pid_file) or die $!;
    print $fh "$$\n";
    close $fh;

    $runner->_write_pid_file($pid_file);
    is($runner->{_pid_file_path}, $pid_file, 'PID file path stored internally');

    ok(-f $pid_file, 'PID file exists');

    $runner->_remove_pid_file;
    ok(!-f $pid_file, 'Remove cleans up file');

    # Should be idempotent
    ok(lives { $runner->_remove_pid_file }, 'Remove is idempotent');
};

done_testing;
