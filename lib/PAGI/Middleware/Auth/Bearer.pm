package PAGI::Middleware::Auth::Bearer;

use strict;
use warnings;
use parent 'PAGI::Middleware';
use Future::AsyncAwait;
use JSON::PP ();
use MIME::Base64 qw(decode_base64url);
use Digest::SHA qw(hmac_sha256);

=head1 NAME

PAGI::Middleware::Auth::Bearer - Bearer token authentication middleware

=head1 SYNOPSIS

    use PAGI::Middleware::Builder;

    my $app = builder {
        enable 'Auth::Bearer',
            secret => 'your-jwt-secret',
            algorithms => ['HS256'];
        $my_app;
    };

    # In your app:
    async sub app {
        my ($scope, $receive, $send) = @_;
    
        my $auth = $scope->{'pagi.auth'};
        my $user_id = $auth->{claims}{sub};
    }

=head1 DESCRIPTION

PAGI::Middleware::Auth::Bearer validates Bearer tokens in the Authorization
header. It supports JWT (JSON Web Tokens) with HMAC-SHA256 signatures.

=head1 CONFIGURATION

=over 4

=item * secret (required for JWT)

Secret key for JWT signature verification.

=item * algorithms (default: ['HS256'])

Allowed JWT algorithms.

=item * validator (optional)

Custom token validator coderef. Receives ($token) and returns claims hashref or undef.
If provided, bypasses built-in JWT validation.

=item * realm (default: 'Bearer')

The authentication realm for WWW-Authenticate header.

=item * paths (optional)

Arrayref of path patterns to protect.

=back

=cut

sub _init {
    my ($self, $config) = @_;

    $self->{secret} = $config->{secret};
    $self->{algorithms} = $config->{algorithms} // ['HS256'];
    $self->{validator} = $config->{validator};
    $self->{realm} = $config->{realm} // 'Bearer';
    $self->{paths} = $config->{paths};

    die "Auth::Bearer requires 'secret' or 'validator' option"
        unless $self->{secret} || $self->{validator};
}

sub wrap {
    my ($self, $app) = @_;

    return async sub  {
        my ($scope, $receive, $send) = @_;
        if ($scope->{type} ne 'http') {
            await $app->($scope, $receive, $send);
            return;
        }

        # Check if path requires authentication
        unless ($self->_requires_auth($scope->{path})) {
            await $app->($scope, $receive, $send);
            return;
        }

        # Get Authorization header
        my $auth_header = $self->_get_header($scope, 'authorization');

        unless ($auth_header) {
            await $self->_send_unauthorized($send, 'Token required');
            return;
        }

        # Parse Bearer token
        my $token = $self->_parse_bearer_token($auth_header);

        unless ($token) {
            await $self->_send_unauthorized($send, 'Invalid authorization header');
            return;
        }

        # Validate token
        my $claims = $self->_validate_token($token);

        unless ($claims) {
            await $self->_send_unauthorized($send, 'Invalid token');
            return;
        }

        # Add auth info to scope
        my $new_scope = {
            %$scope,
            'pagi.auth' => {
                type   => 'bearer',
                token  => $token,
                claims => $claims,
            },
        };

        await $app->($new_scope, $receive, $send);
    };
}

sub _requires_auth {
    my ($self, $path) = @_;

    return 1 unless $self->{paths};

    for my $pattern (@{$self->{paths}}) {
        if (ref $pattern eq 'Regexp') {
            return 1 if $path =~ $pattern;
        } else {
            return 1 if index($path, $pattern) == 0;
        }
    }
    return 0;
}

sub _parse_bearer_token {
    my ($self, $header) = @_;

    return unless $header =~ /^Bearer\s+(.+)$/i;
    return $1;
}

sub _validate_token {
    my ($self, $token) = @_;

    # Use custom validator if provided
    if ($self->{validator}) {
        return $self->{validator}->($token);
    }

    # Validate as JWT
    return $self->_validate_jwt($token);
}

sub _validate_jwt {
    my ($self, $token) = @_;

    my @parts = split /\./, $token;
    return unless @parts == 3;

    my ($header_b64, $payload_b64, $signature_b64) = @parts;

    # Decode and parse header
    my $header_json = eval { decode_base64url($header_b64) };
    return unless $header_json;
    my $header = eval { JSON::PP::decode_json($header_json) };
    return unless $header;

    # Check algorithm
    my $alg = $header->{alg} // '';
    return unless grep { $_ eq $alg } @{$self->{algorithms}};

    # Verify signature
    my $signature_input = "$header_b64.$payload_b64";
    my $expected_signature;

    if ($alg eq 'HS256') {
        $expected_signature = $self->_base64url_encode(
            hmac_sha256($signature_input, $self->{secret})
        );
    } else {
        return;  # Unsupported algorithm
    }

    return unless $self->_secure_compare($signature_b64, $expected_signature);

    # Decode payload
    my $payload_json = eval { decode_base64url($payload_b64) };
    return unless $payload_json;
    my $claims = eval { JSON::PP::decode_json($payload_json) };
    return unless $claims;

    # Check expiration
    if (exists $claims->{exp}) {
        return if time() > $claims->{exp};
    }

    # Check not-before
    if (exists $claims->{nbf}) {
        return if time() < $claims->{nbf};
    }

    return $claims;
}

sub _base64url_encode {
    my ($self, $data) = @_;

    my $encoded = MIME::Base64::encode_base64($data, '');
    $encoded =~ tr{+/}{-_};
    $encoded =~ s/=+$//;
    return $encoded;
}

sub _secure_compare {
    my ($self, $a, $b) = @_;

    return 0 unless length($a) == length($b);
    my $result = 0;
    for my $i (0 .. length($a) - 1) {
        $result |= ord(substr($a, $i, 1)) ^ ord(substr($b, $i, 1));
    }
    return $result == 0;
}

async sub _send_unauthorized {
    my ($self, $send, $error) = @_;

    my $body = $error;

    await $send->({
        type    => 'http.response.start',
        status  => 401,
        headers => [
            ['Content-Type', 'text/plain'],
            ['Content-Length', length($body)],
            ['WWW-Authenticate', qq{Bearer realm="$self->{realm}"}],
        ],
    });
    await $send->({
        type => 'http.response.body',
        body => $body,
        more => 0,
    });
}

sub _get_header {
    my ($self, $scope, $name) = @_;

    $name = lc($name);
    for my $h (@{$scope->{headers} // []}) {
        return $h->[1] if lc($h->[0]) eq $name;
    }
    return;
}

1;

__END__

=head1 SCOPE EXTENSIONS

This middleware adds the following to $scope when authentication succeeds:

=over 4

=item * pagi.auth

Hashref with authentication info:

    {
        type   => 'bearer',
        token  => 'the-raw-token',
        claims => {
            sub => 'user-id',
            exp => 1234567890,
            # ... other JWT claims
        },
    }

=back

=head1 JWT SUPPORT

Currently supported algorithms:

=over 4

=item * HS256 (HMAC-SHA256)

=back

Standard JWT claims checked:

=over 4

=item * exp - Expiration time

=item * nbf - Not before time

=back

=head1 SEE ALSO

L<PAGI::Middleware> - Base class for middleware

L<PAGI::Middleware::Auth::Basic> - HTTP Basic authentication

=cut
