use strict;
use warnings;
use IO::Select;
use IO::Socket::INET;
use Time::HiRes qw(time);

# A client that reads while it writes, to watch both directions at once.
# It uploads 5, 10 and -3 over four seconds and prints every line that comes
# back as it arrives. With "leave", it hangs up after the second number.
#
#   perl examples/20-streaming-echo/client.pl 5020
#   perl examples/20-streaming-echo/client.pl 5020 leave

my ($port, $leave) = @ARGV;
die "usage: $0 PORT [leave]\n" unless $port;
my $t0  = time;
my $s   = IO::Socket::INET->new(PeerAddr => "127.0.0.1:$port") or die "can't connect: $!\n";
my $sel = IO::Select->new($s);
print $s "PUT / HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n\r\n";

my @plan = ([0.2, "5\n"], [1.7, "10\n"], [3.4, "-3\n"], [4.0, undef]);   # undef: the end of the upload
my ($raw, $done) = ('', 0);
while (!$done && time - $t0 < 8) {
    if (@plan && time - $t0 >= $plan[0][0]) {
        my (undef, $line) = @{ shift @plan };
        if (defined $line) {
            printf "%5.1fs  -> %s", time - $t0, $line;
            printf $s "%x\r\n%s\r\n", length $line, $line;
        }
        else {
            printf "%5.1fs  -> (end of upload)\n", time - $t0;
            print $s "0\r\n\r\n";
        }
        if ($leave && @plan == 2) {
            printf "%5.1fs  (hanging up)\n", time - $t0;
            exit;
        }
    }
    next unless $sel->can_read(0.05);
    my $n = sysread($s, my $chunk, 4096);
    last unless $n;
    $raw .= $chunk;
    $raw =~ s/\A.*?\r\n\r\n//s if $raw =~ /\AHTTP/;    # drop the response head
    while ($raw =~ s/\A([0-9a-f]+)\r\n//) {            # one chunk at a time
        my $length = hex $1;
        if ($length == 0) { $done = 1; last }
        my $data = substr($raw, 0, $length, '');
        $raw =~ s/\A\r\n//;
        printf "%5.1fs  <- %s", time - $t0, $data;
    }
}
