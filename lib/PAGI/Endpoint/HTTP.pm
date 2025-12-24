package PAGI::Endpoint::HTTP;

use strict;
use warnings;

use Future::AsyncAwait;
use Carp qw(croak);
use Module::Load qw(load);

our $VERSION = '0.01';

# Factory class methods - override in subclass for customization
sub request_class  { 'PAGI::Request' }
sub response_class { 'PAGI::Response' }

sub new {
    my ($class, %args) = @_;
    return bless \%args, $class;
}

# HTTP methods we support
our @HTTP_METHODS = qw(get post put patch delete head options);

sub allowed_methods {
    my ($self) = @_;
    my @allowed;
    for my $method (@HTTP_METHODS) {
        push @allowed, uc($method) if $self->can($method);
    }
    # HEAD is allowed if GET is defined
    push @allowed, 'HEAD' if $self->can('get') && !$self->can('head');
    # OPTIONS is always allowed
    push @allowed, 'OPTIONS' unless grep { $_ eq 'OPTIONS' } @allowed;
    return sort @allowed;
}

async sub dispatch {
    my ($self, $req, $res) = @_;
    my $http_method = lc($req->method // 'GET');

    # OPTIONS - return allowed methods
    if ($http_method eq 'options') {
        if ($self->can('options')) {
            return await $self->options($req, $res);
        }
        my $allow = join(', ', $self->allowed_methods);
        await $res->header('Allow', $allow)->empty;
        return;
    }

    # HEAD falls back to GET if not explicitly defined
    if ($http_method eq 'head' && !$self->can('head') && $self->can('get')) {
        $http_method = 'get';
    }

    # Check if we have a handler for this method
    if ($self->can($http_method)) {
        return await $self->$http_method($req, $res);
    }

    # 405 Method Not Allowed
    my $allow = join(', ', $self->allowed_methods);
    await $res->header('Allow', $allow)
              ->status(405)
              ->text("405 Method Not Allowed");
}

sub to_app {
    my ($class) = @_;
    # Load the request/response classes
    my $req_class = $class->request_class;
    my $res_class = $class->response_class;
    load($req_class);
    load($res_class);

    return async sub {
        my ($scope, $receive, $send) = @_;

        my $type = $scope->{type} // 'http';
        croak "Expected http scope, got '$type'" unless $type eq 'http';

        my $endpoint = $class->new;
        my $req = $req_class->new($scope, $receive);
        my $res = $res_class->new($send);

        await $endpoint->dispatch($req, $res);
    };
}

1;

__END__

=head1 NAME

PAGI::Endpoint::HTTP - Class-based HTTP endpoint handler

=head1 SYNOPSIS

    package MyApp::UserAPI;
    use parent 'PAGI::Endpoint::HTTP';
    use Future::AsyncAwait;

    async sub get {
        my ($self, $req, $res) = @_;
        my $users = get_all_users();
        await $res->json($users);
    }

    async sub post {
        my ($self, $req, $res) = @_;
        my $data = await $req->json;
        my $user = create_user($data);
        await $res->status(201)->json($user);
    }

    async sub delete {
        my ($self, $req, $res) = @_;
        my $id = $req->path_param('id');
        delete_user($id);
        await $res->status(204)->empty;
    }

    # Use with PAGI server
    my $app = MyApp::UserAPI->to_app;

=head1 DESCRIPTION

PAGI::Endpoint::HTTP provides a Starlette-inspired class-based approach
to handling HTTP requests. Define methods named after HTTP verbs (get,
post, put, patch, delete, head, options) and the endpoint automatically
dispatches to them.

=head2 Features

=over 4

=item * Automatic method dispatch based on HTTP verb

=item * 405 Method Not Allowed for undefined methods

=item * OPTIONS handling with Allow header

=item * HEAD falls back to GET if not defined

=item * Factory methods for framework customization

=back

=head1 HTTP METHODS

Define any of these async methods to handle requests:

    async sub get { my ($self, $req, $res) = @_; ... }
    async sub post { my ($self, $req, $res) = @_; ... }
    async sub put { my ($self, $req, $res) = @_; ... }
    async sub patch { my ($self, $req, $res) = @_; ... }
    async sub delete { my ($self, $req, $res) = @_; ... }
    async sub head { my ($self, $req, $res) = @_; ... }
    async sub options { my ($self, $req, $res) = @_; ... }

Each receives:

=over 4

=item C<$self> - The endpoint instance

=item C<$req> - A L<PAGI::Request> object (or custom request class)

=item C<$res> - A L<PAGI::Response> object (or custom response class)

=back

=head1 CLASS METHODS

=head2 to_app

    my $app = MyEndpoint->to_app;

Returns a PAGI-compatible async coderef that can be used directly
with PAGI::Server or composed with middleware.

=head2 request_class

    sub request_class { 'PAGI::Request' }

Override to use a custom request class.

=head2 response_class

    sub response_class { 'PAGI::Response' }

Override to use a custom response class.

=head1 INSTANCE METHODS

=head2 dispatch

    await $endpoint->dispatch($req, $res);

Dispatches the request to the appropriate HTTP method handler.
Called automatically by C<to_app>.

=head2 allowed_methods

    my @methods = $endpoint->allowed_methods;

Returns list of HTTP methods this endpoint handles.

=head1 FRAMEWORK INTEGRATION

Framework designers can subclass and customize:

    package MyFramework::Endpoint;
    use parent 'PAGI::Endpoint::HTTP';

    sub request_class { 'MyFramework::Request' }
    sub response_class { 'MyFramework::Response' }

    # Add framework-specific helpers
    sub db {
        my ($self) = @_;
        $self->{db} //= connect_db();
    }

=head1 SEE ALSO

L<PAGI::Endpoint::WebSocket>, L<PAGI::Endpoint::SSE>,
L<PAGI::Request>, L<PAGI::Response>

=cut
