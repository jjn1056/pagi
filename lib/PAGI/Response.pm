package PAGI::Response;

use strict;
use warnings;
use v5.32;
use feature 'signatures';
no warnings 'experimental::signatures';

use Future::AsyncAwait;
use Carp qw(croak);

our $VERSION = '0.01';

sub new ($class, $send = undef) {
    croak("send is required") unless $send;
    croak("send must be a coderef") unless ref($send) eq 'CODE';

    my $self = bless {
        send    => $send,
        _status => 200,
        _headers => [],
        _sent   => 0,
    }, $class;

    return $self;
}

1;
