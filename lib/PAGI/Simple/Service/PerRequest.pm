package PAGI::Simple::Service::PerRequest;

use strict;
use warnings;
use experimental 'signatures';

our $VERSION = '0.01';

use parent 'PAGI::Simple::Service::_Base';

=head1 NAME

PAGI::Simple::Service::PerRequest - Per-request cached service scope

=head1 SYNOPSIS

    package MyApp::Service::CurrentUser;
    use parent 'PAGI::Simple::Service::PerRequest';

    sub name ($self) {
        return $self->{user_data}{name};
    }

    1;

    # In routes - same instance within a request:
    my $u1 = $c->service('CurrentUser');
    my $u2 = $c->service('CurrentUser');
    # $u1 == $u2 (same instance)

=head1 DESCRIPTION

PerRequest services are cached in the request stash. Within a single request,
multiple calls to C<< $c->service('Name') >> return the same instance.

Different requests always get different instances.

This is ideal for:

=over 4

=item * CurrentUser - Load user once per request, access many times

=item * Request-specific computed data

=item * Expensive operations that should only run once per request

=back

=head1 METHODS

=head2 init_service

    my $factory = MyApp::Service::User->init_service($app, $config);

Called at startup. Returns a coderef that creates/caches instances per request.

=cut

sub init_service ($class, $app, $config) {
    return sub ($c, $runtime_args = {}) {
        my $key = "_service_$class";

        # Check cache
        if (exists $c->stash->{$key}) {
            # Warn if new args were passed to cached instance
            if (%$runtime_args) {
                warn "[PAGI::Simple] Service '$class' already cached for this request, "
                   . "ignoring new arguments\n";
            }
            return $c->stash->{$key};
        }

        # Create new instance
        my $instance = $class->new(%$config, %$runtime_args, c => $c, app => $app);

        # Cache it
        $c->stash->{$key} = $instance;

        # Register for cleanup callback
        $instance->_register_for_cleanup($c);

        return $instance;
    };
}

=head1 LIFECYCLE

PerRequest services can override C<on_request_end> for cleanup:

    sub on_request_end ($self, $c) {
        # Cleanup logic here
    }

This is called automatically at the end of the request for any
PerRequest service that was instantiated.

=head1 SEE ALSO

L<PAGI::Simple::Service::_Base>,
L<PAGI::Simple::Service::Factory>,
L<PAGI::Simple::Service::PerApp>

=cut

1;
