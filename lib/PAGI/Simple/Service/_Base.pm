package PAGI::Simple::Service::_Base;

use strict;
use warnings;
use experimental 'signatures';

our $VERSION = '0.01';

=head1 NAME

PAGI::Simple::Service::_Base - Base class for PAGI::Simple services

=head1 SYNOPSIS

    # Don't use this directly - inherit from a scope class:
    use parent 'PAGI::Simple::Service::Factory';     # New instance each call
    use parent 'PAGI::Simple::Service::PerRequest';  # Cached per request
    use parent 'PAGI::Simple::Service::PerApp';      # Singleton

=head1 DESCRIPTION

This is the internal base class providing shared functionality for all
PAGI::Simple service scopes. You should not inherit from this directly;
instead, choose the appropriate scope class for your service's lifecycle.

=head1 METHODS

=head2 new

    my $service = $class->new(%args);

Default constructor. Creates a blessed hashref with the given arguments.

=cut

sub new ($class, %args) {
    return bless \%args, $class;
}

=head2 c

    my $c = $service->c;

Returns the request context passed during instantiation.
Returns undef for PerApp services (which have no request context).

=cut

sub c ($self) {
    return $self->{c};
}

=head2 app

    my $app = $service->app;

Returns the PAGI::Simple app instance.

=cut

sub app ($self) {
    return $self->{app};
}

=head2 on_request_end

    $service->on_request_end($c);

Lifecycle hook called at the end of a request for services that registered
for cleanup. Override this in your service to perform cleanup tasks.

Default implementation does nothing.

=cut

sub on_request_end ($self, $c) {
    # Override in subclasses for cleanup logic
}

=head2 _register_for_cleanup

    $service->_register_for_cleanup($c);

Internal method to register this service instance for C<on_request_end>
callback. Called automatically by scope classes that need cleanup.

=cut

sub _register_for_cleanup ($self, $c) {
    $c->_register_service_for_cleanup($self);
}

=head2 init_service

    my $result = $class->init_service($app, $config);

Class method called at startup to initialize the service. Each scope class
implements this differently:

=over 4

=item * PerApp - Returns the singleton instance

=item * PerRequest - Returns a coderef factory

=item * Factory - Returns a coderef factory

=back

=cut

sub init_service ($class, $app, $config) {
    die "Subclass must implement init_service";
}

=head1 SCOPE CLASSES

PAGI::Simple provides three service scopes:

=over 4

=item * L<PAGI::Simple::Service::Factory> - New instance every call (default)

=item * L<PAGI::Simple::Service::PerRequest> - Cached per request

=item * L<PAGI::Simple::Service::PerApp> - Singleton at app level

=back

=head1 SEE ALSO

L<PAGI::Simple::Service::Factory>,
L<PAGI::Simple::Service::PerRequest>,
L<PAGI::Simple::Service::PerApp>

=cut

1;
