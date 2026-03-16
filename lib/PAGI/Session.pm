package PAGI::Session;

use strict;
use warnings;
use Scalar::Util 'blessed';

=head1 NAME

PAGI::Session - Standalone helper object for session data access

=head1 SYNOPSIS

    use PAGI::Session;

    # Construct from raw session data, scope, or request object
    my $session = PAGI::Session->new($scope->{'pagi.session'});
    my $session = PAGI::Session->new($scope);
    my $session = PAGI::Session->new($req);  # any object with ->scope

    # Strict get - dies if key doesn't exist (catches typos)
    my $user_id = $session->get('user_id');

    # Safe get with default for optional keys
    my $theme = $session->get('theme', 'light');

    # Set, delete, check existence
    $session->set('cart_count', 3);
    $session->delete('cart_count');
    if ($session->exists('user_id')) { ... }

    # List user keys (excludes internal _prefixed keys)
    my @keys = $session->keys;

    # Session lifecycle
    $session->regenerate;  # Request new session ID
    $session->destroy;     # Mark session for deletion

=head1 DESCRIPTION

PAGI::Session wraps the raw session data hashref and provides a clean
accessor interface with strict key checking. It is a standalone helper
that is not attached to any request or protocol object.

The strict C<get()> method dies when a key does not exist, catching
typos at runtime. Use the two-argument form C<get($key, $default)>
for keys that may or may not be present.

=head1 CONSTRUCTOR

=head2 new

    my $session = PAGI::Session->new($data_hashref);
    my $session = PAGI::Session->new($scope);
    my $session = PAGI::Session->new($request);

Accepts raw session data (hashref), a PAGI scope (hashref with
C<pagi.session> key), or any object with a C<scope()> method
(e.g., L<PAGI::Request>). The helper stores a reference to the
underlying hash, so mutations via C<set()> and C<delete()> are
visible to the session middleware.

=cut

sub new {
    my ($class, $arg) = @_;

    my $data;
    if (blessed($arg) && $arg->can('scope')) {
        # Duck-typed object with scope method (e.g., PAGI::Request, PAGI::SSE)
        $data = $arg->scope->{'pagi.session'};
    }
    elsif (ref $arg eq 'HASH' && exists $arg->{'pagi.session'}) {
        # Scope hashref
        $data = $arg->{'pagi.session'};
    }
    elsif (ref $arg eq 'HASH') {
        # Raw session data hashref
        $data = $arg;
    }

    die "PAGI::Session requires session data (hashref, scope, or object with ->scope)\n"
        unless ref $data eq 'HASH';

    return bless { _data => $data }, $class;
}

=head1 METHODS

=head2 id

    my $id = $session->id;

Returns the session ID from C<< $data->{_id} >>.

=cut

sub id {
    my ($self) = @_;
    return $self->{_data}{_id};
}

=head2 get

    my $value = $session->get('key');           # dies if missing
    my $value = $session->get('key', $default); # returns $default if missing

Retrieves a value from the session. With one argument, dies with an
error including the key name if the key does not exist. With a default
argument, returns the default when the key is missing (even if the
default is C<undef>).

=cut

sub get {
    my ($self, $key, @rest) = @_;
    if (!exists $self->{_data}{$key}) {
        return $rest[0] if @rest;
        die "No session key '$key'\n";
    }
    return $self->{_data}{$key};
}

=head2 set

    $session->set('key', $value);
    $session->set(user_id => 42, role => 'admin', email => 'john@example.com');

Sets one or more keys in the session data. With two arguments, sets a
single key. With more arguments, treats them as key-value pairs.
Dies if given an odd number of arguments greater than one.

=cut

sub set {
    my ($self, @args) = @_;
    die "set() requires key => value pairs\n" if @args > 2 && @args % 2;
    if (@args == 2) {
        $self->{_data}{$args[0]} = $args[1];
    }
    else {
        my %pairs = @args;
        $self->{_data}{$_} = $pairs{$_} for CORE::keys %pairs;
    }
}

=head2 exists

    if ($session->exists('key')) { ... }

Returns true if the key exists in the session data.

=cut

sub exists {
    my ($self, $key) = @_;
    return exists $self->{_data}{$key} ? 1 : 0;
}

=head2 delete

    $session->delete('key');
    $session->delete('k1', 'k2', 'k3');

Removes one or more keys from the session data.

=cut

sub delete {
    my ($self, @keys) = @_;
    delete $self->{_data}{$_} for @keys;
}

=head2 keys

    my @keys = $session->keys;

Returns a list of user keys, filtering out internal keys that start
with an underscore (e.g. C<_id>, C<_created>, C<_last_access>).

=cut

sub keys {
    my ($self) = @_;
    return grep { !/^_/ } keys %{$self->{_data}};
}

=head2 slice

    my %data = $session->slice('user_id', 'role', 'email');

Returns a hash of key-value pairs for the requested keys. Keys that
do not exist in the session are silently skipped (unlike C<get()>,
which dies on missing keys).

=cut

sub slice {
    my ($self, @keys) = @_;
    return map { CORE::exists($self->{_data}{$_}) ? ($_ => $self->{_data}{$_}) : () } @keys;
}

=head2 clear

    $session->clear;

Removes all user keys from the session, preserving internal
C<_>-prefixed keys (C<_id>, C<_created>, C<_last_access>, etc.).
Use this for a "soft logout" that keeps the session ID but wipes
application data.

=cut

sub clear {
    my ($self) = @_;
    for my $key ($self->keys) {
        delete $self->{_data}{$key};
    }
}

=head2 regenerate

    $session->regenerate;

Requests session ID regeneration. The middleware will generate a new
session ID, delete the old session from the store, save session data
under the new ID, and update the client cookie/header.

B<Security:> Always call this after authentication (login) to prevent
session fixation attacks.

=cut

sub regenerate {
    my ($self) = @_;
    $self->{_data}{_regenerated} = 1;
}

=head2 destroy

    $session->destroy;

Marks the session for destruction. The middleware will delete the
session data from the store and clear the client-side state (e.g.,
expire the cookie). Use this for logout.

=cut

sub destroy {
    my ($self) = @_;
    $self->{_data}{_destroyed} = 1;
}

1;

__END__

=head1 SEE ALSO

L<PAGI::Middleware::Session> - Session management middleware

=cut
