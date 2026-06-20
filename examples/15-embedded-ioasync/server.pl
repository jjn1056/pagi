#!/usr/bin/env perl
use strict;
use warnings;
use IO::Async::Loop;
use Future::IO::Impl::IOAsync;   # we embed, so WE wire the Future::IO backend
use Future::AsyncAwait;
use PAGI::Server;

my $app = async sub {
    my ($scope, $receive, $send) = @_;
    die "Unsupported scope type: $scope->{type}" if $scope->{type} ne 'http';
    await $send->({
        type    => 'http.response.start',
        status  => 200,
        headers => [ ['content-type', 'text/plain'] ],
    });
    await $send->({
        type => 'http.response.body',
        body => "Hello from a PAGI::Server embedded in an IO::Async app\n",
    });
};

my $loop = IO::Async::Loop->new;

# Host-app activity sharing the SAME loop, to prove cohabitation.
my $tick;
$tick = sub {
    warn "[host app] tick at " . time . "\n";
    $loop->watch_time(after => 2, code => $tick);
};
$loop->watch_time(after => 2, code => $tick);

my $server = PAGI::Server->new(app => $app, port => 5015);
$loop->add($server);
$server->listen->get;     # listen without running the loop
print "embedded PAGI::Server listening on http://localhost:5015\n";
$loop->run;               # the host app owns the loop
