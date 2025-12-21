package PAGI::Middleware::Session;

use strict;
use warnings;
use parent 'PAGI::Middleware';
use Future::AsyncAwait;
use Digest::SHA qw(sha256_hex);

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

=head1 CONFIGURATION

=over 4

=item * secret (required)

Secret key for session ID generation and validation.

=item * cookie_name (default: 'pagi_session')

Name of the session cookie.

=item * cookie_options (default: { httponly => 1, path => '/' })

Options for the session cookie.

=item * expire (default: 3600)

Session expiration time in seconds.

=item * store (default: in-memory)

Session store object. Must implement get($id), set($id, $data), delete($id).

=back

=cut

my %sessions;  # In-memory session store

sub _init {
    my ($self, $config) = @_;

    $self->{secret} = $config->{secret}
        // die "Session middleware requires 'secret' option";
    $self->{cookie_name} = $config->{cookie_name} // 'pagi_session';
    $self->{cookie_options} = $config->{cookie_options} // {
        httponly => 1,
        path     => '/',
    };
    $self->{expire} = $config->{expire} // 3600;
    $self->{store} = $config->{store};
}

sub wrap {
    my ($self, $app) = @_;

    return async sub  {
        my ($scope, $receive, $send) = @_;
        if ($scope->{type} ne 'http') {
            await $app->($scope, $receive, $send);
            return;
        }

        # Parse cookies to get session ID
        my $cookie_header = $self->_get_header($scope, 'cookie') // '';
        my $cookies = $self->_parse_cookies($cookie_header);
        my $session_id = $cookies->{$self->{cookie_name}};

        # Validate and load session
        my ($session, $is_new) = $self->_load_or_create_session($session_id);
        $session_id = $session->{_id};

        # Add session to scope
        my $new_scope = {
            %$scope,
            'pagi.session'    => $session,
            'pagi.session_id' => $session_id,
        };

        # Track if session was modified
        my $original_session = { %$session };

        # Wrap send to set session cookie
        my $wrapped_send = async sub  {
        my ($event) = @_;
            if ($event->{type} eq 'http.response.start') {
                # Save session if modified
                $self->_save_session($session_id, $session);

                # Set session cookie if new or regenerated
                if ($is_new || $session->{_regenerated}) {
                    my @headers = @{$event->{headers} // []};
                    my $cookie = $self->_format_cookie($session_id);
                    push @headers, ['Set-Cookie', $cookie];
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

sub _load_or_create_session {
    my ($self, $session_id) = @_;

    my $is_new = 0;

    # Validate session ID format and load existing session
    if ($session_id && $self->_valid_session_id($session_id)) {
        my $session = $self->_get_session($session_id);
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

    my $random = join('', map { sprintf("%02x", int(rand(256))) } 1..16);
    my $time = time();
    return sha256_hex("$random-$time-$self->{secret}");
}

sub _valid_session_id {
    my ($self, $id) = @_;

    return $id =~ /^[a-f0-9]{64}$/;
}

sub _get_session {
    my ($self, $id) = @_;

    if ($self->{store}) {
        return $self->{store}->get($id);
    }
    return $sessions{$id};
}

sub _save_session {
    my ($self, $id, $session) = @_;

    if ($self->{store}) {
        return $self->{store}->set($id, $session);
    }
    $sessions{$id} = $session;
}

sub _is_expired {
    my ($self, $session) = @_;

    my $last_access = $session->{_last_access} // $session->{_created} // 0;
    return (time() - $last_access) > $self->{expire};
}

sub _format_cookie {
    my ($self, $session_id) = @_;

    my $cookie = "$self->{cookie_name}=$session_id";
    my $opts = $self->{cookie_options};

    $cookie .= "; Path=" . ($opts->{path} // '/');
    $cookie .= "; HttpOnly" if $opts->{httponly};
    $cookie .= "; Secure" if $opts->{secure};
    $cookie .= "; SameSite=$opts->{samesite}" if $opts->{samesite};
    $cookie .= "; Max-Age=$self->{expire}" if $self->{expire};

    return $cookie;
}

sub _parse_cookies {
    my ($self, $header) = @_;

    my %cookies;
    for my $pair (split /\s*;\s*/, $header) {
        my ($name, $value) = split /=/, $pair, 2;
        next unless defined $name && $name ne '';
        $name =~ s/^\s+//;
        $name =~ s/\s+$//;
        $value //= '';
        $value =~ s/^\s+//;
        $value =~ s/\s+$//;
        $cookies{$name} = $value;
    }
    return \%cookies;
}

sub _get_header {
    my ($self, $scope, $name) = @_;

    $name = lc($name);
    for my $h (@{$scope->{headers} // []}) {
        return $h->[1] if lc($h->[0]) eq $name;
    }
    return;
}

# Class method to clear all sessions (useful for testing)
sub clear_sessions {
    %sessions = ();
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
