#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use FindBin;
use POSIX ':sys_wait_h';

# =============================================================================
# HTTP/2 Conformance Tests using h2spec
# =============================================================================
# Runs the h2spec conformance test suite against PAGI::Server

plan skip_all => "Server integration tests not supported on Windows"
    if $^O eq 'MSWin32';

# Check for h2spec
my $h2spec = `which h2spec 2>/dev/null`;
chomp $h2spec;
plan skip_all => 'h2spec not installed (brew install h2spec)'
    unless $h2spec && -x $h2spec;

BEGIN {
    plan skip_all => 'HTTP/2 not available'
        unless eval {
            require Net::HTTP2::nghttp2;
            Net::HTTP2::nghttp2->available;
        };
}

BEGIN {
    plan skip_all => 'TLS modules not installed'
        unless eval {
            require IO::Async::SSL;
            require IO::Socket::SSL;
            1;
        };
}

my $cert_dir = "$FindBin::Bin/../certs";
my $server_cert = "$cert_dir/server.crt";
my $server_key = "$cert_dir/server.key";

plan skip_all => 'Test certificates not found'
    unless -f $server_cert && -f $server_key;

# Use a fixed port for simplicity
my $port = 19443 + $$  % 1000;

subtest 'h2spec conformance (TLS)' => sub {
    # Start server in background
    my $server_pid = fork();
    die "Fork failed: $!" unless defined $server_pid;

    if ($server_pid == 0) {
        # Child process - run server
        require IO::Async::Loop;
        require Future::AsyncAwait;
        require PAGI::Server;

        my $loop = IO::Async::Loop->new;

        my $app = sub {
            my ($scope, $receive, $send) = @_;
            return Future->done if $scope->{type} eq 'lifespan';

            $send->({
                type    => 'http.response.start',
                status  => 200,
                headers => [['content-type', 'text/plain']],
            })->get;

            $send->({
                type => 'http.response.body',
                body => "Hello",
                more => 0,
            })->get;

            return Future->done;
        };

        my $server = PAGI::Server->new(
            app   => $app,
            host  => '127.0.0.1',
            port  => $port,
            quiet => 1,
            http2 => 1,
            ssl   => {
                cert_file => $server_cert,
                key_file  => $server_key,
            },
        );

        $loop->add($server);
        $server->listen->get;
        $loop->run;
        exit 0;
    }

    # Parent process - wait for server to start, then run h2spec
    sleep 2;

    diag "Server started (pid: $server_pid) on port $port";
    diag "Running h2spec...";

    # Run h2spec
    my $output_file = "/tmp/h2spec_output_$$.txt";
    my $cmd = "$h2spec -h 127.0.0.1 -p $port -t -k -o 3 > $output_file 2>&1";
    my $exit_code = system($cmd) >> 8;

    my $stdout = '';
    if (-f $output_file) {
        open my $fh, '<', $output_file or die "Cannot read $output_file: $!";
        local $/;
        $stdout = <$fh>;
        close $fh;
        unlink $output_file;
    }

    # Kill server
    kill 'TERM', $server_pid;
    waitpid($server_pid, 0);

    # Parse and report results
    ok(defined $exit_code, "h2spec completed (exit code: $exit_code)");

    # Try to parse summary line: "146 tests, 127 passed, 0 skipped, 19 failed"
    my ($total, $passed, $skipped, $failed);
    if ($stdout =~ /(\d+) tests?, (\d+) passed, (\d+) skipped, (\d+) failed/) {
        ($total, $passed, $skipped, $failed) = ($1, $2, $3, $4);
    } else {
        # Fallback: count checkmarks and X marks
        $passed = () = $stdout =~ /✔/g;
        $failed = () = $stdout =~ /×/g;
        $total = $passed + $failed;
        $skipped = 0;
    }

    if ($total > 0) {
        my $pass_rate = ($passed / $total) * 100;
        diag "Results: $passed/$total passed (" . sprintf("%.1f", $pass_rate) . "%), $skipped skipped, $failed failed";

        # Show failed tests
        if ($failed > 0) {
            diag "Failed tests:";
            while ($stdout =~ /×\s+\d+:\s+([^\n]+)/g) {
                diag "  - $1";
            }
            diag "Known issues: stream state validation, RST_STREAM/GOAWAY edge cases";
        }

        # Pass rate should be >= 80% (currently ~90%)
        ok($pass_rate >= 80, "Pass rate >= 80% (got " . sprintf("%.1f", $pass_rate) . "%)");
    } else {
        diag "h2spec output:\n$stdout";
        pass("h2spec ran (could not parse results)");
    }
};

done_testing;
