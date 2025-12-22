package PAGI::Endpoint::HTTP;

use strict;
use warnings;
use v5.32;
use feature 'signatures';
no warnings 'experimental::signatures';

use Future::AsyncAwait;
use Carp qw(croak);
use Module::Load qw(load);

our $VERSION = '0.01';

# Factory class methods - override in subclass for customization
sub request_class  { 'PAGI::Request' }
sub response_class { 'PAGI::Response' }

sub new ($class, %args) {
    return bless \%args, $class;
}

# HTTP methods we support
our @HTTP_METHODS = qw(get post put patch delete head options);

sub allowed_methods ($self) {
    my @allowed;
    for my $method (@HTTP_METHODS) {
        push @allowed, uc($method) if $self->can($method);
    }
    return @allowed;
}

async sub dispatch ($self, $req, $res) {
    my $http_method = lc($req->method // 'GET');

    # HEAD falls back to GET if not explicitly defined
    if ($http_method eq 'head' && !$self->can('head') && $self->can('get')) {
        $http_method = 'get';
    }

    # Check if we have a handler for this method
    if ($self->can($http_method)) {
        return await $self->$http_method($req, $res);
    }

    # 405 Method Not Allowed
    my @allowed = $self->allowed_methods;
    await $res->text("405 Method Not Allowed", status => 405);
}

sub to_app ($class) {
    # Load the request/response classes
    my $req_class = $class->request_class;
    my $res_class = $class->response_class;
    load($req_class);
    load($res_class);

    return async sub ($scope, $receive, $send) {
        my $endpoint = $class->new;
        my $req = $req_class->new($scope, $receive);
        my $res = $res_class->new($send);

        await $endpoint->dispatch($req, $res);
    };
}

1;
