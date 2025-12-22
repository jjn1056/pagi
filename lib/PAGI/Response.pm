package PAGI::Response;

use strict;
use warnings;
use v5.32;
use feature 'signatures';
no warnings 'experimental::signatures';

use Future::AsyncAwait;
use Carp qw(croak);
use Encode qw(encode);

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

sub status ($self, $code) {
    croak("Status must be a number between 100-599")
        unless defined $code && $code =~ /^\d+$/ && $code >= 100 && $code <= 599;
    $self->{_status} = $code;
    return $self;
}

sub header ($self, $name, $value) {
    push @{$self->{_headers}}, [$name, $value];
    return $self;
}

sub content_type ($self, $type) {
    # Remove existing content-type headers
    $self->{_headers} = [grep { lc($_->[0]) ne 'content-type' } @{$self->{_headers}}];
    push @{$self->{_headers}}, ['content-type', $type];
    return $self;
}

async sub send ($self, $body = undef) {
    croak("Response already sent") if $self->{_sent};
    $self->{_sent} = 1;

    # Send start
    await $self->{send}->({
        type    => 'http.response.start',
        status  => $self->{_status},
        headers => $self->{_headers},
    });

    # Send body
    await $self->{send}->({
        type => 'http.response.body',
        body => $body,
        more => 0,
    });
}

async sub send_utf8 ($self, $body, %opts) {
    my $charset = $opts{charset} // 'utf-8';

    # Ensure content-type has charset
    my $has_ct = 0;
    for my $h (@{$self->{_headers}}) {
        if (lc($h->[0]) eq 'content-type') {
            $has_ct = 1;
            unless ($h->[1] =~ /charset=/i) {
                $h->[1] .= "; charset=$charset";
            }
            last;
        }
    }
    unless ($has_ct) {
        push @{$self->{_headers}}, ['content-type', "text/plain; charset=$charset"];
    }

    # Encode body
    my $encoded = encode($charset, $body // '');

    await $self->send($encoded);
}

1;
