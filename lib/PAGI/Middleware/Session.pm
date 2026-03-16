package PAGI::Middleware::Session;

use strict;
use warnings;
use parent 'PAGI::Middleware';
use Future::AsyncAwait;
use Digest::SHA qw(sha256_hex);
use PAGI::Utils::Random qw(secure_random_bytes);

=head1 NAME

PAGI::Middleware::Session - Session management middleware

=head1 SYNOPSIS

    use PAGI::Middleware::Builder;

    my $app = builder {
        enable 'Session',
            secret => 'your-secret-key',
            cookie_name => 'session_id';
        $my_app;
    };

    # In your app:
    async sub app {
        my ($scope, $receive, $send) = @_;

        my $session = $scope->{'pagi.session'};
        $session->{user_id} = 123;
        $session->{logged_in} = 1;
    }

=head1 DESCRIPTION

PAGI::Middleware::Session provides server-side session management with
cookie-based session IDs. Sessions are stored in memory by default.

B<Warning:> The default in-memory store is suitable for development and
single-process deployments only. Sessions are not shared between workers
and are lost on restart. For production multi-worker deployments, provide
a C<store> object backed by Redis, a database, or another shared storage.

=head1 CONFIGURATION

=over 4

=item * secret (required)

Secret key for session ID generation and validation.

=item * cookie_name (default: 'pagi_session')

Name of the session cookie.

=item * cookie_options (default: { httponly => 1, path => '/', samesite => 'Lax' })

Options for the session cookie. For production HTTPS deployments,
add C<< secure => 1 >> to prevent the cookie from being sent over
plain HTTP.

=item * expire (default: 3600)

Session expiration time in seconds.

=item * state (optional)

A session state object that implements C<extract($scope)> and
C<inject(\@headers, $id, \%options)>. If not provided, a
L<PAGI::Middleware::Session::State::Cookie> instance is created
using C<cookie_name>, C<cookie_options>, and C<expire>.

=item * store (optional)

A session store object that implements async C<get($id)>,
C<set($id, $data)>, C<delete($id)>. If not provided, a
L<PAGI::Middleware::Session::Store::Memory> instance is created.

=back

=head1 CUSTOM STORES

For production multi-worker deployments, implement a store class with three
methods. Here's a Redis example:

    package MyApp::Session::Redis;
    use Redis;
    use JSON::MaybeXS qw(encode_json decode_json);

    sub new {
        my ($class, %opts) = @_;
        return bless {
            redis  => Redis->new(server => $opts{server} // '127.0.0.1:6379'),
            prefix => $opts{prefix} // 'session:',
            expire => $opts{expire} // 3600,
        }, $class;
    }

    sub get {
        my ($self, $id) = @_;
        my $data = $self->{redis}->get($self->{prefix} . $id);
        return $data ? decode_json($data) : undef;
    }

    sub set {
        my ($self, $id, $session) = @_;
        my $key = $self->{prefix} . $id;
        $self->{redis}->setex($key, $self->{expire}, encode_json($session));
    }

    sub delete {
        my ($self, $id) = @_;
        $self->{redis}->del($self->{prefix} . $id);
    }

    1;

Then use it:

    enable 'Session',
        secret => $ENV{SESSION_SECRET},
        store  => MyApp::Session::Redis->new(
            server => 'redis.example.com:6379',
            expire => 7200,
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
        my $wrapped_send = async sub  {
        my ($event) = @_;
            if ($event->{type} eq 'http.response.start') {
                # Save session
                await $self->_save_session($session_id, $session);

                # Inject session ID into response if new or regenerated
                if ($is_new || $session->{_regenerated}) {
                    my @headers = @{$event->{headers} // []};
                    $self->{state}->inject(\@headers, $session_id, {});
                    await $send->({
                        %$event,
                        headers => \@headers,
                    });
                    return;
                }
            }
            await $send->($event);
        };

        await $app->($new_scope, $receive, $wrapped_send);
    };
}

async sub _load_or_create_session {
    my ($self, $session_id) = @_;

    # Validate session ID format and load existing session
    if ($session_id && $self->_valid_session_id($session_id)) {
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

sub _valid_session_id {
    my ($self, $id) = @_;

    return $id =~ /^[a-f0-9]{64}$/;
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

This middleware adds the following to $scope:

=over 4

=item * pagi.session

Hashref of session data. Modify this directly to update the session.
Keys starting with C<_> are reserved for internal use.

=item * pagi.session_id

The session ID string.

=back

=head1 SESSION DATA

Special session keys:

=over 4

=item * _id - Session ID (read-only)

=item * _created - Unix timestamp when session was created

=item * _last_access - Unix timestamp of last access

=item * _regenerated - Set to 1 to regenerate session ID

=back

=head1 SEE ALSO

L<PAGI::Middleware> - Base class for middleware

L<PAGI::Middleware::Cookie> - Cookie parsing

=cut
