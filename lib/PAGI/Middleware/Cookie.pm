package PAGI::Middleware::Cookie;

use strict;
use warnings;
use parent 'PAGI::Middleware';
use Future::AsyncAwait;
use Cookie::Baker ();

=head1 NAME

PAGI::Middleware::Cookie - Cookie parsing middleware

=head1 SYNOPSIS

    use PAGI::Middleware::Builder;

    my $app = builder {
        enable 'Cookie';
        $my_app;
    };

    # In your app:
    async sub app {
        my ($scope, $receive, $send) = @_;

        my $cookies = $scope->{'pagi.cookies'};
        my $session_id = $cookies->{session_id};
    }

=head1 DESCRIPTION

PAGI::Middleware::Cookie parses the Cookie header and makes the parsed
cookies available in C<< $scope->{'pagi.cookies'} >> as a hashref.

It also provides a helper for setting response cookies.

=head1 CONFIGURATION

=over 4

=item * secret (optional)

Secret key for signed cookies. Required for C<get_signed>/C<set_signed>.

=back

=cut

sub _init {
    my ($self, $config) = @_;

    $self->{secret} = $config->{secret};
}

sub wrap {
    my ($self, $app) = @_;

    return async sub  {
        my ($scope, $receive, $send) = @_;
        if ($scope->{type} ne 'http') {
            await $app->($scope, $receive, $send);
            return;
        }

        # Parse cookies from Cookie header
        my $cookie_header = $self->_get_header($scope, 'cookie') // '';
        my $cookies = $self->_parse_cookies($cookie_header);

        # Create cookie jar for setting response cookies
        my @response_cookies;
        my $cookie_jar = PAGI::Middleware::Cookie::Jar->new(
            \@response_cookies,
            sub { $self->_format_set_cookie(@_) },
        );

        # Add cookies and jar to scope
        my $new_scope = {
            %$scope,
            'pagi.cookies'    => $cookies,
            'pagi.cookie_jar' => $cookie_jar,
        };

        # Wrap send to add Set-Cookie headers
        my $wrapped_send = async sub  {
        my ($event) = @_;
            if ($event->{type} eq 'http.response.start' && @response_cookies) {
                my @headers = @{$event->{headers} // []};
                for my $cookie (@response_cookies) {
                    push @headers, ['Set-Cookie', $cookie];
                }
                await $send->({
                    %$event,
                    headers => \@headers,
                });
            } else {
                await $send->($event);
            }
        };

        await $app->($new_scope, $receive, $wrapped_send);
    };
}

sub _parse_cookies {
    my ($self, $header) = @_;

    return {} unless defined $header && length $header;
    return Cookie::Baker::crush_cookie($header);
}

sub _format_set_cookie {
    my ($self, $name, $value, %opts) = @_;

    my %cookie_opts = (
        value => $value,
        path  => $opts{path} // '/',
    );
    $cookie_opts{domain}    = $opts{domain}   if defined $opts{domain};
    $cookie_opts{expires}   = $opts{expires}  if defined $opts{expires};
    $cookie_opts{'max-age'} = $opts{max_age}  if defined $opts{max_age};
    $cookie_opts{secure}    = $opts{secure}   if $opts{secure};
    $cookie_opts{httponly}  = $opts{httponly} if $opts{httponly};
    $cookie_opts{samesite}  = $opts{samesite} if defined $opts{samesite};
    return Cookie::Baker::bake_cookie($name, \%cookie_opts);
}

sub _get_header {
    my ($self, $scope, $name) = @_;

    $name = lc($name);
    for my $h (@{$scope->{headers} // []}) {
        return $h->[1] if lc($h->[0]) eq $name;
    }
    return;
}

# Simple cookie jar class for method-style access
package PAGI::Middleware::Cookie::Jar;

use strict;
use warnings;

sub new {
    my ($class, $cookies_ref, $formatter) = @_;

    return bless {
        cookies   => $cookies_ref,
        formatter => $formatter,
    }, $class;
}

sub set {
    my ($self, $name, $value, %opts) = @_;

    push @{$self->{cookies}}, $self->{formatter}->($name, $value, %opts);
}

sub delete {
    my ($self, $name, %opts) = @_;

    my %cookie_opts = (
        value   => '',
        expires => 0,  # Epoch 0 = expired
        path    => $opts{path} // '/',
    );
    $cookie_opts{domain} = $opts{domain} if defined $opts{domain};
    push @{$self->{cookies}}, Cookie::Baker::bake_cookie($name, \%cookie_opts);
}

package PAGI::Middleware::Cookie;

1;

__END__

=head1 SCOPE EXTENSIONS

This middleware adds the following to $scope:

=over 4

=item * pagi.cookies

Hashref of parsed cookies from the Cookie header.

=item * pagi.cookie_jar

Object with methods for setting response cookies:

    $scope->{'pagi.cookie_jar'}->set('name', 'value',
        path     => '/',
        httponly => 1,
        secure   => 1,
        samesite => 'Strict',
        max_age  => 3600,
    );

    $scope->{'pagi.cookie_jar'}->delete('name');

=back

=head1 SEE ALSO

L<PAGI::Middleware> - Base class for middleware

L<PAGI::Middleware::Session> - Session management using cookies

=cut

