#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use POSIX ':sys_wait_h';
use IO::Socket::INET;
use File::Temp qw(tempdir);
use File::Spec;
use Cwd qw(abs_path);

BEGIN { require FindBin; }

plan skip_all => "Hot restart tests require RELEASE_TESTING"
    unless $ENV{RELEASE_TESTING};
plan skip_all => "Not supported on Windows" if $^O eq 'MSWin32';

# Ensure the re-exec'd process can find our local lib/ code.
# _hot_restart does fork+exec with $^X and $0, which does not preserve
# perl's -Ilib flag. PERL5LIB is inherited across fork+exec.
my $lib_dir = abs_path(File::Spec->catdir($FindBin::Bin, '..', 'lib'));
$ENV{PERL5LIB} = join(':', grep { defined } $lib_dir, $ENV{PERL5LIB});

my $bin = abs_path(File::Spec->catfile($FindBin::Bin, '..', 'bin', 'pagi-server'));

# Prevent stray SIGTERMs from server shutdown from killing the test process.
# Server shutdown can send TERM to process groups that include us.
$SIG{TERM} = 'IGNORE';

my @pids_to_cleanup;
END {
    for my $pid (@pids_to_cleanup) {
        next unless $pid && kill(0, $pid);
        kill('TERM', $pid);
    }
    # Give them a moment to exit
    select(undef, undef, undef, 1) if @pids_to_cleanup;
    for my $pid (@pids_to_cleanup) {
        next unless $pid && kill(0, $pid);
        kill('KILL', $pid);
        waitpid($pid, WNOHANG);
    }
    # Reset $? so waitpid results don't leak into our exit code
    $? = 0;
}

sub find_pids_on_port {
    my ($port) = @_;
    my @pids;
    my $output = `lsof -ti tcp:$port -sTCP:LISTEN 2>/dev/null`;
    if (defined $output) {
        @pids = grep { $_ && $_ =~ /^\d+$/ } split /\n/, $output;
    }
    return @pids;
}

sub http_get {
    my ($port, $timeout) = @_;
    $timeout //= 5;
    my $client = IO::Socket::INET->new(
        PeerAddr => '127.0.0.1',
        PeerPort => $port,
        Proto    => 'tcp',
        Timeout  => $timeout,
    ) or return undef;
    print $client "GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";
    my $resp = '';
    while (my $line = <$client>) { $resp .= $line; }
    close $client;
    return $resp;
}

sub wait_for_port {
    my ($port, $timeout) = @_;
    $timeout //= 10;
    my $start = time();
    while (time() - $start < $timeout) {
        my $sock = IO::Socket::INET->new(
            PeerAddr => '127.0.0.1',
            PeerPort => $port,
            Proto    => 'tcp',
            Timeout  => 1,
        );
        if ($sock) {
            close $sock;
            return 1;
        }
        select(undef, undef, undef, 0.3);
    }
    return 0;
}

sub wait_for_exit {
    my ($pid, $timeout) = @_;
    $timeout //= 15;
    my $start = time();
    while (time() - $start < $timeout) {
        # Use waitpid with WNOHANG to reap zombies and detect exit.
        # kill(0) returns true for zombies, so we must actually reap.
        my $ret = waitpid($pid, WNOHANG);
        return 1 if $ret > 0;       # reaped, process exited
        return 1 if $ret == -1;     # already reaped or doesn't exist
        select(undef, undef, undef, 0.5);
    }
    return 0;
}

# Write a PAGI app that reports its PID in the response
sub write_pid_app {
    my ($dir) = @_;
    my $app_file = File::Spec->catfile($dir, 'app.pl');
    open my $fh, '>', $app_file or die "Cannot write $app_file: $!";
    print $fh <<'APP';
use strict;
use warnings;
use Future::AsyncAwait;

my $app = async sub {
    my ($scope, $receive, $send) = @_;

    if ($scope->{type} eq 'lifespan') {
        while (1) {
            my $event = await $receive->();
            if ($event->{type} eq 'lifespan.startup') {
                await $send->({ type => 'lifespan.startup.complete' });
            } elsif ($event->{type} eq 'lifespan.shutdown') {
                await $send->({ type => 'lifespan.shutdown.complete' });
                last;
            }
        }
        return;
    }

    await $send->({
        type    => 'http.response.start',
        status  => 200,
        headers => [['content-type', 'text/plain']],
    });
    await $send->({
        type => 'http.response.body',
        body => "pid=$$",
        more => 0,
    });
};

$app;
APP
    close $fh;
    return $app_file;
}

subtest 'USR2 hot restart in multi-worker mode' => sub {
    my $tmpdir = tempdir(CLEANUP => 1);
    my $app_file = write_pid_app($tmpdir);
    my $port = 40000 + int(rand(20000));

    # Start the server in multi-worker mode
    my $master_pid = fork();
    die "fork failed: $!" unless defined $master_pid;

    my $server_log = File::Spec->catfile($tmpdir, 'server.log');
    if ($master_pid == 0) {
        # Own process group so server signals don't reach the test process
        setpgrp(0, 0);
        # Redirect output to log file for post-mortem debugging
        open STDOUT, '>', $server_log or POSIX::_exit(1);
        open STDERR, '>&STDOUT' or POSIX::_exit(1);
        exec($^X, '-Ilib', $bin,
            '--host', '127.0.0.1',
            '--port', $port,
            '--workers', 2,
            '--quiet',
            '--heartbeat-timeout', 5,
            '--no-default-middleware',
            '--no-access-log',
            $app_file,
        ) or POSIX::_exit(1);
    }

    push @pids_to_cleanup, $master_pid;

    # Wait for server to be ready
    ok(wait_for_port($port, 15), "server started on port $port")
        or do {
            diag "Server did not start; killing master $master_pid";
            kill('TERM', $master_pid);
            return;
        };

    # Make a request to get a worker PID
    my $resp1 = http_get($port);
    ok(defined $resp1, 'got response before restart');
    my ($pid_before) = ($resp1 // '') =~ /pid=(\d+)/;
    ok(defined $pid_before, "extracted worker PID before restart: " . ($pid_before // 'none'));

    # Send USR2 to trigger hot restart
    kill('USR2', $master_pid);

    # Wait for the restart to complete.
    # handoff_delay = heartbeat_timeout/2 + 1 = 3.5s, plus worker startup time.
    diag "Waiting for hot restart to complete...";
    select(undef, undef, undef, 10);

    # Verify the port is still accepting connections
    ok(wait_for_port($port, 5), 'port still accepting connections after restart');

    # Make another request to get the new worker PID
    my $resp2 = http_get($port);
    ok(defined $resp2, 'got response after restart');
    my ($pid_after) = ($resp2 // '') =~ /pid=(\d+)/;
    ok(defined $pid_after, "extracted worker PID after restart: " . ($pid_after // 'none'));

    # The new workers should have different PIDs
    if (defined $pid_before && defined $pid_after) {
        isnt($pid_after, $pid_before, 'worker PID changed after hot restart');
    }

    # The old master should have been killed by the new master's handoff
    ok(wait_for_exit($master_pid, 10), "old master $master_pid exited after handoff")
        or do {
            # Dump server log on failure to help diagnose
            if (open my $log_fh, '<', $server_log) {
                local $/;
                diag "Server log:\n" . <$log_fh>;
                close $log_fh;
            }
        };

    # Clean up the new master and its workers
    my @new_pids = find_pids_on_port($port);
    for my $pid (@new_pids) {
        next if $pid == $$;  # never kill ourselves
        push @pids_to_cleanup, $pid;
        kill('TERM', $pid);
    }

    # Wait for cleanup to take effect
    select(undef, undef, undef, 2);
};

subtest 'USR2 in single-worker mode is ignored' => sub {
    my $tmpdir = tempdir(CLEANUP => 1);
    my $app_file = write_pid_app($tmpdir);
    my $port = 40000 + int(rand(20000));

    # Start single-worker server (no --workers flag)
    my $server_pid = fork();
    die "fork failed: $!" unless defined $server_pid;

    if ($server_pid == 0) {
        # Own process group so server signals don't reach the test process
        setpgrp(0, 0);
        exec($^X, '-Ilib', $bin,
            '--host', '127.0.0.1',
            '--port', $port,
            '--quiet',
            '--no-default-middleware',
            '--no-access-log',
            $app_file,
        ) or POSIX::_exit(1);
    }

    push @pids_to_cleanup, $server_pid;

    ok(wait_for_port($port, 15), "single-worker server started on port $port")
        or do {
            diag "Server did not start; killing $server_pid";
            kill('TERM', $server_pid);
            return;
        };

    # Verify it works before USR2
    my $resp1 = http_get($port);
    ok(defined $resp1, 'got response before USR2');
    like($resp1, qr/200/, 'got 200 status before USR2');

    # Send USR2 — should be ignored in single-worker mode
    kill('USR2', $server_pid);

    # Wait a moment for the signal to be processed
    select(undef, undef, undef, 2);

    # Verify server still works
    ok(kill(0, $server_pid), 'server process still alive after USR2');

    my $resp2 = http_get($port);
    ok(defined $resp2, 'got response after USR2');
    like($resp2, qr/200/, 'got 200 status after USR2');

    # Clean up
    kill('TERM', $server_pid);
};

done_testing;
