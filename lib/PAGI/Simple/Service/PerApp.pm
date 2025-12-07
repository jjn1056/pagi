package PAGI::Simple::Service::PerApp;

use strict;
use warnings;
use experimental 'signatures';

our $VERSION = '0.01';

use parent 'PAGI::Simple::Service::_Base';

=head1 NAME

PAGI::Simple::Service::PerApp - App-level singleton service scope

=head1 SYNOPSIS

    package MyApp::Service::DB;
    use parent 'PAGI::Simple::Service::PerApp';

    sub dbh ($self) {
        return $self->{dbh} //= DBI->connect($self->{dsn});
    }

    1;

    # In routes - same instance across all requests:
    my $db1 = $c->service('DB');
    # ... later, different request ...
    my $db2 = $c->service('DB');
    # $db1 == $db2 (same singleton instance)

=head1 DESCRIPTION

PerApp services are singletons created at application startup. The instance
is created during lifespan.startup and reused for all subsequent requests.

B<Important:> PerApp services do NOT have access to request context (C<c()>
returns undef). They should only store app-level resources.

This is ideal for:

=over 4

=item * Database connection pools

=item * External service clients

=item * Configuration-driven services

=item * Expensive resources to initialize once

=item * Stateless services with shared data

=back

=head1 METHODS

=head2 init_service

    my $instance = MyApp::Service::DB->init_service($app, $config);

Called at startup. Returns the singleton instance directly (not a coderef).
This instance is stored in the service registry and returned on every call
to C<< $c->service('Name') >>.

=cut

sub init_service ($class, $app, $config) {
    return $class->new(%$config, app => $app);
}

=head2 c

    my $c = $service->c;  # Always returns undef

PerApp services do not have request context. This method always returns undef.
If you need request-specific data, use PerRequest instead.

=cut

sub c ($self) {
    return undef;
}

=head1 NOTES

=over 4

=item * PerApp services are created during lifespan.startup

=item * The singleton persists for the lifetime of the application

=item * Do not store request-specific data in PerApp services

=item * Thread safety is the responsibility of the service implementation

=back

=head1 SEE ALSO

L<PAGI::Simple::Service::_Base>,
L<PAGI::Simple::Service::Factory>,
L<PAGI::Simple::Service::PerRequest>

=cut

1;
