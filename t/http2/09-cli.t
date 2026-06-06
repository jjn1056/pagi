use strict;
use warnings;
use Test2::V0;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use File::Temp qw(tempfile);

plan skip_all => "Server integration tests not supported on Windows" if $^O eq 'MSWin32';

# ============================================================
# Test: --http2 CLI flag chain
# ============================================================
# --http2 must flow: bin/pagi-server CLI -> server_options ->
# server constructor. PAGITest::FakeServer (t/lib) stands in for
# PAGI::Server, so no sockets are involved and the chain is
# observable from its STDOUT.

my $pagi_server = "$FindBin::Bin/../../bin/pagi-server";
my $tlib        = "$FindBin::Bin/../../t/lib";

my ($app_fh, $app_file) = tempfile(SUFFIX => '.pl', UNLINK => 1);
print $app_fh "sub {}\n";
close $app_fh;

sub run_cli {
    my (@flags) = @_;
    local $ENV{PAGI_ENV} = 'production';   # deterministic mode, no Lint wrap
    return `$^X -Ilib -I$tlib $pagi_server @flags -s PAGITest::FakeServer $app_file 2>&1`;
}

subtest '--http2 reaches the server constructor' => sub {
    my $out = run_cli('--http2');
    like($out, qr/FAKESERVER http2=1/, '--http2 passes http2 => 1 via server_options');
};

subtest 'http2 is absent without the flag' => sub {
    my $out = run_cli();
    like($out, qr/FAKESERVER http2=unset/, 'no --http2 means no http2 option');
};

subtest 'environment variables play no part' => sub {
    local $ENV{_PAGI_SERVER_HTTP2} = 0;    # would force-disable under the old design
    my $out = run_cli('--http2');
    like($out, qr/FAKESERVER http2=1/, 'flag works regardless of environment');
};

subtest 'bin/pagi-server documents --http2' => sub {
    open my $fh, '<', $pagi_server or die "Cannot open $pagi_server: $!";
    my $content = do { local $/; <$fh> };
    close $fh;
    like($content, qr/--http2/, 'bin/pagi-server mentions --http2');
};

done_testing;
