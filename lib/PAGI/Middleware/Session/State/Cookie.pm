package PAGI::Middleware::Session::State::Cookie;

use strict;
use warnings;
use parent 'PAGI::Middleware::Session::State';

=head1 NAME

PAGI::Middleware::Session::State::Cookie - Cookie-based session ID transport

=head1 SYNOPSIS

    use PAGI::Middleware::Session::State::Cookie;

    my $state = PAGI::Middleware::Session::State::Cookie->new(
        cookie_name    => 'pagi_session',
        cookie_options => { httponly => 1, path => '/', samesite => 'Lax' },
        expire         => 3600,
    );

    # Extract session ID from request
    my $id = $state->extract($scope);

    # Inject Set-Cookie header into response
    $state->inject(\@headers, $id, {});

=head1 DESCRIPTION

Implements the L<PAGI::Middleware::Session::State> interface using HTTP
cookies for session ID transport. The session ID is read from the Cookie
request header and set via the Set-Cookie response header.

=head1 CONFIGURATION

=over 4

=item * cookie_name (default: 'pagi_session')

Name of the cookie used to store the session ID.

=item * cookie_options (default: { httponly => 1, path => '/', samesite => 'Lax' })

Cookie attributes applied when setting the response cookie.

=item * expire (default: 3600)

Max-Age value for the session cookie, in seconds.

=back

=cut

sub new {
    my ($class, %options) = @_;

    $options{cookie_name} //= 'pagi_session';
    $options{cookie_options} //= {
        httponly => 1,
        path     => '/',
        samesite => 'Lax',
    };
    $options{expire} //= 3600;

    return $class->SUPER::new(%options);
}

=head2 extract

    my $session_id = $state->extract($scope);

Find the Cookie header in C<$scope-E<gt>{headers}> (case-insensitive),
parse the cookie string, and return the value matching C<cookie_name>.
Returns undef if no matching cookie is found.

=cut

sub extract {
    my ($self, $scope) = @_;

    my $cookie_header = $self->_get_header($scope, 'cookie');
    return unless defined $cookie_header;

    my $cookies = $self->_parse_cookies($cookie_header);
    return $cookies->{$self->{cookie_name}};
}

=head2 inject

    $state->inject(\@headers, $id, \%options);

Format a Set-Cookie string and push C<['Set-Cookie', $cookie_string]>
onto the provided headers arrayref.

=cut

sub inject {
    my ($self, $headers, $id, $options) = @_;

    my $cookie = $self->_format_cookie($id);
    push @$headers, ['Set-Cookie', $cookie];
}

=head2 clear

    $state->clear(\@headers);

Expire the session cookie by pushing a Set-Cookie header with
C<Max-Age=0>. Called when a session is destroyed.

=cut

sub clear {
    my ($self, $headers) = @_;
    my $cookie = "$self->{cookie_name}=; Path=" . ($self->{cookie_options}{path} // '/') . "; Max-Age=0";
    $cookie .= "; HttpOnly" if $self->{cookie_options}{httponly};
    push @$headers, ['Set-Cookie', $cookie];
}

sub _get_header {
    my ($self, $scope, $name) = @_;

    $name = lc($name);
    for my $h (@{$scope->{headers} // []}) {
        return $h->[1] if lc($h->[0]) eq $name;
    }
    return;
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

1;

__END__

=head1 SEE ALSO

L<PAGI::Middleware::Session::State> - Base state interface

L<PAGI::Middleware::Session> - Session management middleware

=cut
