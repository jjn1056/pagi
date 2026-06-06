package PAGITest::FakeServer;
use strict;
use warnings;

our $VERSION = '0.001';

# Minimal implementation of the PAGI server-runner contract
# (new(%options) + run) used to test the CLI -> server_options ->
# constructor chain without opening sockets.

sub new {
    my ($class, %options) = @_;
    return bless { options => \%options }, $class;
}

sub run {
    my ($self) = @_;
    my $http2 = $self->{options}{http2};
    print "FAKESERVER http2=" . (defined $http2 ? $http2 : 'unset') . "\n";
    return;
}

1;
