package PAGI::Stash;

use strict;
use warnings;
use Scalar::Util 'blessed';

=head1 NAME

PAGI::Stash - Standalone helper for per-request shared state

=head1 SYNOPSIS

    use PAGI::Stash;

    # Middleware sets shared state for downstream handlers
    my $auth_middleware = sub ($app) {
        async sub ($scope, $receive, $send) {
            my $stash = PAGI::Stash->new($scope);
            $stash->set(user => authenticate($scope));
            await $app->($scope, $receive, $send);
        };
    };

    # Handler reads what middleware stored
    async sub ($scope, $receive, $send) {
        my $stash = PAGI::Stash->new($scope);
        my $user  = $stash->get('user');           # dies if missing
        my $theme = $stash->get('theme', 'dark');  # default if missing
        ...
    };

=head1 DESCRIPTION

PAGI::Stash wraps C<< $scope->{'pagi.stash'} >> and provides a clean
accessor interface with strict key checking. It is a standalone helper
not attached to any protocol object.

The strict C<get()> method dies when a key does not exist, catching
typos at runtime. Use the two-argument form C<get($key, $default)>
for keys that may or may not be present.

The stash lives in the PAGI scope hashref and is shared across all
middleware, handlers, and protocol objects processing the same request.

=head1 CONSTRUCTOR

=head2 new

    my $stash = PAGI::Stash->new($scope);
    my $stash = PAGI::Stash->new($request);   # any object with ->scope
    my $stash = PAGI::Stash->new(@_);          # extra args ignored

Scope-based constructor. Resolves to the C<< $scope->{'pagi.stash'} >>
hashref, creating it lazily if it does not exist. Accepts a scope hashref
directly, or any blessed object with a C<scope()> method. Extra positional
arguments are silently ignored.

=head2 from_data

    my $stash = PAGI::Stash->from_data({ user => 'alice' });

Test convenience constructor. Wraps a raw hashref directly as the
backing data, bypassing scope resolution.

=cut

sub new {
    my ($class, @args) = @_;

    my $arg = $args[0];

    # Object with ->scope method (e.g., PAGI::Request, PAGI::SSE)
    if (blessed($arg) && $arg->can('scope')) {
        my $scope = $arg->scope;
        die "PAGI::Stash requires scope hashref from ->scope method\n"
            unless ref $scope eq 'HASH';
        $scope->{'pagi.stash'} //= {};
        return bless { _data => $scope->{'pagi.stash'} }, $class;
    }

    # Unblessed hashref — treat as scope
    if (ref $arg eq 'HASH') {
        $arg->{'pagi.stash'} //= {};
        return bless { _data => $arg->{'pagi.stash'} }, $class;
    }

    die "PAGI::Stash requires a scope hashref or object with ->scope method\n";
}

sub from_data {
    my ($class, $data) = @_;
    die "from_data() requires a hashref\n" unless ref $data eq 'HASH';
    return bless { _data => $data }, $class;
}

=head1 METHODS

=head2 get

    my $val  = $stash->get('user');            # strict: dies if missing
    my $val  = $stash->get('theme', 'dark');   # permissive: returns default

With one argument, dies if the key does not exist. The error message
lists available keys (10 or fewer) or reports the count.

With two arguments, returns the default if the key is missing.

=cut

sub get {
    my ($self, @args) = @_;
    die "get() requires 1 or 2 arguments\n" if @args == 0 || @args > 2;
    my ($key, @rest) = @args;
    if (!exists $self->{_data}{$key}) {
        return $rest[0] if @rest;
        my @all_keys = sort keys %{$self->{_data}};
        if (@all_keys <= 10) {
            die "Stash key '$key' does not exist. Available keys: "
                . join(', ', @all_keys) . "\n";
        }
        else {
            die "Stash key '$key' does not exist (stash has "
                . scalar(@all_keys) . " keys)\n";
        }
    }
    return $self->{_data}{$key};
}

=head2 set

    $stash->set(user => $u);
    $stash->set(user => $u, role => 'admin');
    $stash->set(user => $u)->set(role => 'admin');

Sets key-value pairs. Returns C<$self> for chaining. No-ops on zero
args. Dies on odd number of args.

=cut

sub set {
    my ($self, @args) = @_;
    return $self unless @args;
    die "set() requires key => value pairs\n" if @args % 2;
    my %pairs = @args;
    $self->{_data}{$_} = $pairs{$_} for CORE::keys %pairs;
    return $self;
}

=head2 exists

    if ($stash->exists('user')) { ... }

Returns true (1) if the key exists, false (0) otherwise.

=cut

sub exists {
    my ($self, $key) = @_;
    return exists $self->{_data}{$key} ? 1 : 0;
}

=head2 delete

    $stash->delete('user');
    $stash->delete('user', 'role', 'debug');

Removes one or more keys. Returns C<$self> for chaining.

=cut

sub delete {
    my ($self, @keys) = @_;
    delete $self->{_data}{$_} for @keys;
    return $self;
}

=head2 keys

    my @keys = $stash->keys;

Returns all keys in the stash.

=cut

sub keys {
    my ($self) = @_;
    return keys %{$self->{_data}};
}

=head2 slice

    my %subset = $stash->slice('user', 'role', 'theme');

Returns a hash of key-value pairs for the requested keys. Missing keys
are silently skipped.

=cut

sub slice {
    my ($self, @keys) = @_;
    return map { CORE::exists($self->{_data}{$_}) ? ($_ => $self->{_data}{$_}) : () } @keys;
}

=head2 data

    my $href = $stash->data;
    $href->{user} = $val;

Returns the raw backing hashref. Mutations are visible through
C<get()>/C<set()> since they operate on the same reference.

=cut

sub data {
    my ($self) = @_;
    return $self->{_data};
}

1;

__END__

=head1 SEE ALSO

L<PAGI::Session> - Session data helper with the same accessor conventions

=cut
