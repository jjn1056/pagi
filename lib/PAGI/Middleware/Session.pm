package PAGI::Middleware::Session;

use strict;
use warnings;
use parent 'PAGI::Middleware';
use Future::AsyncAwait;
use Digest::SHA qw(sha256_hex);
use PAGI::Utils::Random qw(secure_random_bytes);

=head1 NAME

PAGI::Middleware::Session - Session management middleware with pluggable State/Store

=head1 SYNOPSIS

    use PAGI::Middleware::Builder;

    # Default (cookie-based, in-memory store)
    my $app = builder {
        enable 'Session', secret => 'your-secret-key';
        $my_app;
    };

    # Explicit state and store
    use PAGI::Middleware::Session::State::Header;
    use PAGI::Middleware::Session::Store::Memory;

    my $app = builder {
        enable 'Session',
            secret => 'your-secret-key',
            state  => PAGI::Middleware::Session::State::Header->new(
                header_name => 'X-Session-ID',
            ),
            store  => PAGI::Middleware::Session::Store::Memory->new;
        $my_app;
    };

    # In your app:
    async sub app {
        my ($scope, $receive, $send) = @_;

        # Raw hashref access
        my $session = $scope->{'pagi.session'};
        $session->{user_id} = 123;

        # Or use the PAGI::Session helper
        use PAGI::Session;
        my $s = PAGI::Session->new($scope->{'pagi.session'});
        $s->set('user_id', 123);
        my $uid = $s->get('user_id');  # dies if key missing
    }

=head1 DESCRIPTION

PAGI::Middleware::Session provides server-side session management with a
pluggable architecture for session ID transport (State) and session data
storage (Store).

The B<State> layer controls how the session ID travels between client and
server (cookies, headers, bearer tokens, or custom logic). The B<Store>
layer controls where session data is persisted (memory, Redis, database).

By default, sessions use cookie-based IDs and in-memory storage.

B<Warning:> The default in-memory store is suitable for development and
single-process deployments only. Sessions are not shared between workers
and are lost on restart. For production multi-worker deployments, provide
a C<store> object backed by Redis, a database, or another shared storage.

=head1 CONFIGURATION

=over 4

=item * secret (required)

Secret key used for session ID generation.

=item * expire (default: 3600)

Session expiration time in seconds.

=item * state (optional)

A L<PAGI::Middleware::Session::State> object that implements C<extract($scope)>
and C<inject(\@headers, $id, \%options)>. If not provided, a
L<PAGI::Middleware::Session::State::Cookie> instance is created using
C<cookie_name>, C<cookie_options>, and C<expire>.

=item * store (optional)

A L<PAGI::Middleware::Session::Store> object that implements async C<get($id)>,
C<set($id, $data)>, and C<delete($id)>. If not provided, a
L<PAGI::Middleware::Session::Store::Memory> instance is created.

=item * cookie_name (default: 'pagi_session')

Name of the session cookie. Only used when C<state> defaults to
L<PAGI::Middleware::Session::State::Cookie>.

=item * cookie_options (default: { httponly => 1, path => '/', samesite => 'Lax' })

Options for the session cookie. Only used when C<state> defaults to
L<PAGI::Middleware::Session::State::Cookie>. For production HTTPS
deployments, add C<< secure => 1 >>.

=back

=head1 STATE CLASSES

State classes control how the session ID is extracted from requests and
injected into responses. All implement the L<PAGI::Middleware::Session::State>
interface.

=over 4

=item L<PAGI::Middleware::Session::State::Cookie>

Default. Reads the session ID from a request cookie and sets it via
C<Set-Cookie> on the response. Suitable for browser-based web applications.

=item L<PAGI::Middleware::Session::State::Header>

Reads the session ID from a custom HTTP header. Requires C<header_name>;
accepts an optional C<pattern> regex with a capture group. Injection is a
no-op (the client manages header-based transport).

    PAGI::Middleware::Session::State::Header->new(
        header_name => 'X-Session-ID',
    );

=item L<PAGI::Middleware::Session::State::Bearer>

Convenience subclass of State::Header that reads an opaque bearer token from
the C<Authorization: Bearer E<lt>tokenE<gt>> header. Intended for opaque
session tokens, B<not> JWTs. For JWT authentication, use
L<PAGI::Middleware::Auth::Bearer> instead.

    PAGI::Middleware::Session::State::Bearer->new();

=item L<PAGI::Middleware::Session::State::Callback>

Custom session ID transport using coderefs. Requires an C<extract> coderef;
accepts an optional C<inject> coderef (defaults to no-op).

    PAGI::Middleware::Session::State::Callback->new(
        extract => sub { my ($scope) = @_; ... },
        inject  => sub { my ($headers, $id, $options) = @_; ... },
    );

=back

=head1 STORE CLASSES

Store classes control where session data is persisted. All implement the
L<PAGI::Middleware::Session::Store> interface; methods return L<Future>
objects for async compatibility.

=over 4

=item L<PAGI::Middleware::Session::Store::Memory>

Default. In-memory hash storage. Not shared across workers or restarts.
Suitable for development and testing only.

=item External stores

Redis, database, and other shared stores are available as separate CPAN
distributions. Any object implementing C<get($id)>, C<set($id, $data)>,
and C<delete($id)> (returning Futures) can be used.

=back

=head1 PAGI::Session HELPER

L<PAGI::Session> is a standalone helper object that wraps the raw session
data hashref with a clean accessor interface.

    use PAGI::Session;
    my $session = PAGI::Session->new($scope->{'pagi.session'});

Key methods:

=over 4

=item * C<get($key)> - Dies if the key does not exist (catches typos).

=item * C<get($key, $default)> - Returns C<$default> for missing keys.

=item * C<set($key, $value)> - Sets a session value.

=item * C<exists($key)> - Checks key existence.

=item * C<delete($key)> - Removes a key.

=item * C<keys> - Lists user keys (excludes internal C<_>-prefixed keys).

=item * C<id> - Returns the session ID.

=item * C<regenerate> - Requests session ID regeneration on next response.

=item * C<destroy> - Marks the session for deletion.

=back

The helper stores a reference to the underlying hash, so mutations are
visible to the middleware.

=head1 IDEMPOTENCY

The middleware skips processing if C<< $scope-E<gt>{'pagi.session'} >>
already exists. This prevents double-initialization when the middleware
appears more than once in a stack.

For mixed auth patterns (e.g. web cookies for browsers, bearer tokens for
APIs), use L<PAGI::Middleware::Session::State::Callback> with fallback
logic instead of stacking multiple Session middleware instances:

    use PAGI::Middleware::Session::State::Callback;
    use PAGI::Middleware::Session::State::Cookie;
    use PAGI::Middleware::Session::State::Bearer;

    my $cookie_state = PAGI::Middleware::Session::State::Cookie->new(
        cookie_name => 'pagi_session',
        expire      => 3600,
    );
    my $bearer_state = PAGI::Middleware::Session::State::Bearer->new();

    enable 'Session',
        secret => $ENV{SESSION_SECRET},
        state  => PAGI::Middleware::Session::State::Callback->new(
            extract => sub {
                my ($scope) = @_;
                return $bearer_state->extract($scope)
                    // $cookie_state->extract($scope);
            },
            inject => sub {
                my ($headers, $id, $options) = @_;
                $cookie_state->inject($headers, $id, $options);
            },
        );

=cut

sub _init {
    my ($self, $config) = @_;

    $self->{secret} = $config->{secret}
        // die "Session middleware requires 'secret' option";
    $self->{expire} = $config->{expire} // 3600;

    # State: pluggable session ID transport
    if ($config->{state}) {
        $self->{state} = $config->{state};
    } else {
        require PAGI::Middleware::Session::State::Cookie;
        $self->{state} = PAGI::Middleware::Session::State::Cookie->new(
            cookie_name    => $config->{cookie_name} // 'pagi_session',
            cookie_options => $config->{cookie_options} // {
                httponly => 1,
                path     => '/',
                samesite => 'Lax',
            },
            expire => $self->{expire},
        );
    }

    # Store: pluggable async session storage
    if ($config->{store}) {
        $self->{store} = $config->{store};
    } else {
        require PAGI::Middleware::Session::Store::Memory;
        $self->{store} = PAGI::Middleware::Session::Store::Memory->new();
    }
}

sub wrap {
    my ($self, $app) = @_;

    return async sub  {
        my ($scope, $receive, $send) = @_;
        if ($scope->{type} ne 'http') {
            await $app->($scope, $receive, $send);
            return;
        }

        # Idempotency: skip if session already exists in scope
        if (exists $scope->{'pagi.session'}) {
            warn "Session middleware: pagi.session already in scope, skipping\n"
                if $ENV{PAGI_DEBUG};
            await $app->($scope, $receive, $send);
            return;
        }

        # Extract session ID via state handler
        my $session_id = $self->{state}->extract($scope);

        # Validate and load session
        my ($session, $is_new) = await $self->_load_or_create_session($session_id);
        $session_id = $session->{_id};

        # Add session to scope
        my $new_scope = {
            %$scope,
            'pagi.session'    => $session,
            'pagi.session_id' => $session_id,
        };

        # Wrap send to save session and inject state
        my $wrapped_send = async sub {
            my ($event) = @_;
            if ($event->{type} eq 'http.response.start') {
                my @headers = @{$event->{headers} // []};

                if ($session->{_destroyed}) {
                    # Destroy: delete from store, clear client state
                    await $self->{store}->delete($session_id);
                    $self->{state}->clear(\@headers);
                }
                elsif ($session->{_regenerated}) {
                    # Regenerate: new ID, delete old, save under new
                    my $old_id = $session_id;
                    $session_id = $self->_generate_session_id();
                    $session->{_id} = $session_id;
                    delete $session->{_regenerated};
                    await $self->{store}->delete($old_id);
                    my $transport = await $self->_save_session($session_id, $session);
                    $self->{state}->inject(\@headers, $transport, {});
                }
                else {
                    # Normal: save and inject if new
                    my $transport = await $self->_save_session($session_id, $session);
                    if ($is_new) {
                        $self->{state}->inject(\@headers, $transport, {});
                    }
                }

                await $send->({ %$event, headers => \@headers });
                return;
            }
            await $send->($event);
        };

        await $app->($new_scope, $receive, $wrapped_send);
    };
}

async sub _load_or_create_session {
    my ($self, $session_id) = @_;

    # Try to load existing session. The store handles validation —
    # server-side stores return undef for unknown IDs, cookie stores
    # return undef if decoding/verification fails.
    if (defined $session_id && length $session_id) {
        my $session = await $self->_get_session($session_id);
        if ($session && !$self->_is_expired($session)) {
            $session->{_last_access} = time();
            return ($session, 0);
        }
    }

    # Create new session
    $session_id = $self->_generate_session_id();
    my $session = {
        _id          => $session_id,
        _created     => time(),
        _last_access => time(),
    };

    return ($session, 1);
}

sub _generate_session_id {
    my ($self) = @_;

    # Use cryptographically secure random bytes
    my $random = unpack('H*', secure_random_bytes(16));
    my $time = time();
    return sha256_hex("$random-$time-$self->{secret}");
}

async sub _get_session {
    my ($self, $id) = @_;
    return await $self->{store}->get($id);
}

async sub _save_session {
    my ($self, $id, $session) = @_;
    return await $self->{store}->set($id, $session);
}

sub _is_expired {
    my ($self, $session) = @_;

    my $last_access = $session->{_last_access} // $session->{_created} // 0;
    return (time() - $last_access) > $self->{expire};
}

# Class method to clear all sessions (useful for testing)
sub clear_sessions {
    require PAGI::Middleware::Session::Store::Memory;
    PAGI::Middleware::Session::Store::Memory::clear_all();
}

1;

__END__

=head1 SCOPE EXTENSIONS

This middleware adds the following to C<$scope>:

=over 4

=item * pagi.session

Hashref of session data. Modify this directly to update the session,
or wrap it with L<PAGI::Session> for strict accessor methods.
Keys starting with C<_> are reserved for internal use.

=item * pagi.session_id

The session ID string.

=back

=head1 SESSION DATA

Keys starting with C<_> are B<reserved> for internal use by the session
middleware. Do not use underscore-prefixed keys for application data.

=head2 Reserved keys (read-only metadata)

=over 4

=item * C<_id> - Session ID

=item * C<_created> - Unix timestamp when session was created

=item * C<_last_access> - Unix timestamp of last access (updated each request)

=back

=head2 Reserved keys (middleware-consumed flags)

These flags are set by the application and consumed by the middleware
during response handling. They are deleted after processing.

=over 4

=item * C<_regenerated> - Set to 1 to regenerate the session ID on this
response. The old session is deleted from the store and a new ID is
issued. B<Always do this after authentication> to prevent session
fixation attacks.

=item * C<_destroyed> - Set to 1 to destroy the session entirely. The
session data is deleted from the store and the client-side state
(cookie) is cleared. Use this for logout.

=back

=head1 SEE ALSO

L<PAGI::Session> - Standalone session helper object

L<PAGI::Middleware::Session::State> - Base class for session ID transport

L<PAGI::Middleware::Session::Store> - Base class for session storage

L<PAGI::Middleware> - Base class for middleware

L<PAGI::Middleware::Cookie> - Cookie parsing

=cut
