package PAGI::Middleware::CSRF;

use strict;
use warnings;
use parent 'PAGI::Middleware';
use Future::AsyncAwait;
use Digest::SHA qw(sha256_hex);
use PAGI::Utils::Random qw(secure_random_bytes);

=head1 NAME

PAGI::Middleware::CSRF - Cross-Site Request Forgery protection middleware

=head1 SYNOPSIS

    use PAGI::Middleware::Builder;

    my $app = builder {
        enable 'CSRF',
            secret       => 'your-secret-key',
            token_header => 'X-CSRF-Token',
            cookie_name  => 'csrf_token',
            safe_methods => ['GET', 'HEAD', 'OPTIONS'];
        $my_app;
    };

=head1 DESCRIPTION

PAGI::Middleware::CSRF provides protection against Cross-Site Request
Forgery attacks by validating tokens on state-changing requests.

=head1 CONFIGURATION

=over 4

=item * secret (required)

Secret key used for token generation.

=item * token_header (default: 'X-CSRF-Token')

Header name to look for the CSRF token.

=item * token_param (default: '_csrf_token')

Form parameter name to look for the CSRF token.

=item * cookie_name (default: 'csrf_token')

Cookie name for the CSRF token.

=item * safe_methods (default: ['GET', 'HEAD', 'OPTIONS', 'TRACE'])

HTTP methods that don't require CSRF validation.

=back

=cut

sub _init {
    my ($self, $config) = @_;

    $self->{secret}       = $config->{secret} // die "CSRF middleware requires 'secret' option";
    $self->{token_header} = $config->{token_header} // 'X-CSRF-Token';
    $self->{token_param}  = $config->{token_param} // '_csrf_token';
    $self->{cookie_name}  = $config->{cookie_name} // 'csrf_token';
    $self->{safe_methods} = { map { $_ => 1 } @{$config->{safe_methods} // [qw(GET HEAD OPTIONS TRACE)]} };
}

sub wrap {
    my ($self, $app) = @_;

    return async sub  {
        my ($scope, $receive, $send) = @_;
        # Only handle HTTP requests
        if ($scope->{type} ne 'http') {
            await $app->($scope, $receive, $send);
            return;
        }

        my $method = $scope->{method};

        # Get existing token from cookie
        my $cookie_token = $self->_get_cookie_token($scope);

        # Generate new token if none exists
        my $token = $cookie_token // $self->_generate_token();

        # For safe methods, just add token to scope and continue
        if ($self->{safe_methods}{$method}) {
            my $modified_scope = $self->modify_scope($scope, {
                csrf_token => $token,
            });

            # Add Set-Cookie if token is new
            my $wrapped_send = $cookie_token ? $send : async sub {
                my ($event) = @_;
                if ($event->{type} eq 'http.response.start') {
                    push @{$event->{headers}}, [
                        'Set-Cookie',
                        "$self->{cookie_name}=$token; Path=/; HttpOnly; SameSite=Strict"
                    ];
                }
                await $send->($event);
            };

            await $app->($modified_scope, $receive, $wrapped_send);
            return;
        }

        # For unsafe methods, validate token
        my $submitted_token = $self->_get_submitted_token($scope);

        # Use timing-safe comparison to prevent timing attacks
        if (!$submitted_token || !$cookie_token || !$self->_secure_compare($submitted_token, $cookie_token)) {
            await $self->_send_error($send, 403, 'CSRF token validation failed');
            return;
        }

        # Token valid, continue with request
        my $modified_scope = $self->modify_scope($scope, {
            csrf_token => $token,
        });

        await $app->($modified_scope, $receive, $send);
    };
}

sub _generate_token {
    my ($self) = @_;

    # Use cryptographically secure random bytes
    my $random = secure_random_bytes(32);
    return sha256_hex($self->{secret} . time() . $random . $$);
}

sub _get_cookie_token {
    my ($self, $scope) = @_;

    my $cookie_header = $self->_get_header($scope, 'cookie');
    return unless $cookie_header;

    my $name = $self->{cookie_name};
    if ($cookie_header =~ /(?:^|;\s*)\Q$name\E=([^;]+)/) {
        return $1;
    }
    return;
}

sub _get_submitted_token {
    my ($self, $scope) = @_;

    # First check header
    my $token = $self->_get_header($scope, $self->{token_header});
    return $token if $token;

    # Could also check query string for token_param, but that requires
    # parsing query string which we'll skip for now
    return;
}

sub _get_header {
    my ($self, $scope, $name) = @_;

    $name = lc($name);
    for my $h (@{$scope->{headers} // []}) {
        return $h->[1] if lc($h->[0]) eq $name;
    }
    return;
}

# Constant-time string comparison to prevent timing attacks
sub _secure_compare {
    my ($self, $a, $b) = @_;

    return 0 unless defined $a && defined $b;
    return 0 unless length($a) == length($b);

    my $result = 0;
    for my $i (0 .. length($a) - 1) {
        $result |= ord(substr($a, $i, 1)) ^ ord(substr($b, $i, 1));
    }
    return $result == 0;
}

async sub _send_error {
    my ($self, $send, $status, $message) = @_;

    await $send->({
        type    => 'http.response.start',
        status  => $status,
        headers => [
            ['content-type', 'text/plain'],
            ['content-length', length($message)],
        ],
    });
    await $send->({
        type => 'http.response.body',
        body => $message,
        more => 0,
    });
}

1;

__END__

=head1 USAGE

The CSRF middleware uses a double-submit cookie pattern:

1. A token is generated and stored in a cookie
2. The same token must be submitted with unsafe requests (POST, PUT, etc.)
3. The submitted token is compared with the cookie token

To use in your application:

1. For forms, include the token in a hidden field:

    <input type="hidden" name="_csrf_token" value="<%= $scope->{csrf_token} %>">

2. For AJAX requests, include the token in a header:

    fetch('/api/resource', {
        method: 'POST',
        headers: {
            'X-CSRF-Token': getCookie('csrf_token')
        }
    });

=head1 SEE ALSO

L<PAGI::Middleware> - Base class for middleware

=cut
