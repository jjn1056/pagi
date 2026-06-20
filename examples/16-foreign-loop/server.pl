#!/usr/bin/env perl
use strict;
use warnings;
# Force IO::Async onto the EV backend for EVERY IO::Async::Loop->new call
# (the server, and Future::IO's impl, must share one EV-backed loop).
BEGIN { $ENV{IO_ASYNC_LOOP} = 'EV' }
use IO::Async::Loop;
use Future::IO;
use Future::IO::Impl::IOAsync;   # embedder wires the Future::IO backend
use Future::AsyncAwait;
use PAGI::Server;

my $app = async sub {
    my ($scope, $receive, $send) = @_;
    die "Unsupported scope type: $scope->{type}" if $scope->{type} ne 'http';
    # Exercise Future::IO under the foreign loop: if this resolves, Future::IO
    # is ticking on the EV loop. If the request hangs here, it is not.
    await Future::IO->sleep(1);
    await $send->({
        type    => 'http.response.start',
        status  => 200,
        headers => [ ['content-type', 'text/plain'] ],
    });
    await $send->({
        type => 'http.response.body',
        body => "PAGI::Server is running under the EV loop; Future::IO ticked\n",
    });
};

my $loop = IO::Async::Loop->new;   # EV-backed (per IO_ASYNC_LOOP above)
warn "loop backend: " . ref($loop) . "\n";

my $server = PAGI::Server->new(app => $app, port => 5016);
$loop->add($server);
$server->listen->get;
print "PAGI::Server running under EV on http://localhost:5016\n";
$loop->run;
