package PAGI::Session;

use strict;
use warnings;

=head1 NAME

PAGI::Session - Standalone helper object for session data access

=head1 SYNOPSIS

    use PAGI::Session;

    # Construct from scope session data
    my $session = PAGI::Session->new($scope->{'pagi.session'});

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

Creates a new session helper wrapping the given data hashref. The
helper stores a reference to the hash, so mutations via C<set()>
and C<delete()> are visible to the session middleware.

=cut

sub new {
    my ($class, $data) = @_;

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

Sets a key in the session data.

=cut

sub set {
    my ($self, $key, $value) = @_;
    $self->{_data}{$key} = $value;
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

Removes a key from the session data.

=cut

sub delete {
    my ($self, $key) = @_;
    delete $self->{_data}{$key};
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

=head2 regenerate

    $session->regenerate;

Requests session ID regeneration by setting C<< $data->{_regenerated} = 1 >>.
The session middleware will assign a new ID on the next response.

=cut

sub regenerate {
    my ($self) = @_;
    $self->{_data}{_regenerated} = 1;
}

=head2 destroy

    $session->destroy;

Marks the session for destruction by setting C<< $data->{_destroyed} = 1 >>.
The session middleware will delete the session data on the next response.

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
