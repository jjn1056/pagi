package PAGI::Simple::Service::Factory;

use strict;
use warnings;
use experimental 'signatures';

our $VERSION = '0.01';

use parent 'PAGI::Simple::Service::_Base';

=head1 NAME

PAGI::Simple::Service::Factory - Factory scope service (new instance per call)

=head1 SYNOPSIS

    package MyApp::Service::Todo;
    use parent 'PAGI::Simple::Service::Factory';

    sub all ($self) {
        # Return all todos
    }

    1;

    # In routes - each call creates a new instance:
    my $s1 = $c->service('Todo');
    my $s2 = $c->service('Todo');
    # $s1 != $s2 (different instances)

=head1 DESCRIPTION

Factory is the simplest service scope. Each call to C<< $c->service('Name') >>
creates a fresh instance. There is no caching.

This is ideal for:

=over 4

=item * Stateless service objects

=item * Services that need isolated state per call

=item * When you explicitly want new instances

=back

=head1 METHODS

=head2 init_service

    my $factory = MyApp::Service::Todo->init_service($app, $config);

Called at startup. Returns a coderef that creates new instances when called.

=cut

sub init_service ($class, $app, $config) {
    return sub ($c, $runtime_args = {}) {
        return $class->new(%$config, %$runtime_args, c => $c, app => $app);
    };
}

=head1 SEE ALSO

L<PAGI::Simple::Service::_Base>,
L<PAGI::Simple::Service::PerRequest>,
L<PAGI::Simple::Service::PerApp>

=cut

1;
