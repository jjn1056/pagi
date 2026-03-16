package PAGI::Middleware::Session::Store::Memory;

use strict;
use warnings;
use parent 'PAGI::Middleware::Session::Store';
use Future;

=head1 NAME

PAGI::Middleware::Session::Store::Memory - In-memory session store

=head1 SYNOPSIS

    use PAGI::Middleware::Session::Store::Memory;

    my $store = PAGI::Middleware::Session::Store::Memory->new();

    # All methods return Futures
    await $store->set('session_id', { user_id => 123 });
    my $data = await $store->get('session_id');
    await $store->delete('session_id');

    # For testing
    PAGI::Middleware::Session::Store::Memory->clear_all();

=head1 DESCRIPTION

Implements the L<PAGI::Middleware::Session::Store> interface using a
package-level hash. Sessions are shared across all instances within the
same process but are not shared between workers and are lost on restart.

B<Warning:> This store is suitable for development and single-process
deployments only. For production multi-worker deployments, use a store
backed by Redis, a database, or another shared storage.

=cut

my %sessions;

=head1 METHODS

=head2 get

    my $future = $store->get($id);

Returns a Future resolving to the session hashref, or undef if no
session exists for the given ID.

=cut

sub get {
    my ($self, $id) = @_;

    return Future->done($sessions{$id});
}

=head2 set

    my $future = $store->set($id, $data);

Stores the session data hashref under the given ID. Returns a Future
resolving to the transport value (the session ID for server-side stores,
or encoded data for cookie stores).

=cut

sub set {
    my ($self, $id, $data) = @_;

    $sessions{$id} = $data;
    return Future->done($id);
}

=head2 delete

    my $future = $store->delete($id);

Removes the session for the given ID. Returns a Future resolving to 1.

=cut

sub delete {
    my ($self, $id) = @_;

    delete $sessions{$id};
    return Future->done(1);
}

=head2 clear_all

    PAGI::Middleware::Session::Store::Memory->clear_all();

Class method that removes all sessions from the in-memory store.
Useful for test cleanup.

=cut

sub clear_all {
    %sessions = ();
}

1;

__END__

=head1 SEE ALSO

L<PAGI::Middleware::Session::Store> - Base store interface

L<PAGI::Middleware::Session> - Session management middleware

=cut
