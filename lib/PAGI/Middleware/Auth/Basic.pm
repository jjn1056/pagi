package PAGI::Middleware::Auth::Basic;

use strict;
use warnings;
use parent 'PAGI::Middleware';
use Future::AsyncAwait;
use MIME::Base64 qw(decode_base64);

=head1 NAME

PAGI::Middleware::Auth::Basic - HTTP Basic Authentication middleware

=head1 SYNOPSIS

    use PAGI::Middleware::Builder;

    my $app = builder {
        enable 'Auth::Basic',
            realm => 'Restricted Area',
            authenticator => sub  {
        my ($username, $password) = @_;
                return $username eq 'admin' && $password eq 'secret';
            };
        $my_app;
    };

    # In your app:
    async sub app {
        my ($scope, $receive, $send) = @_;
    
        my $auth = $scope->{'pagi.auth'};
        my $username = $auth->{username};
    }

=head1 DESCRIPTION

PAGI::Middleware::Auth::Basic implements HTTP Basic Authentication (RFC 7617).
It validates credentials and returns 401 Unauthorized for failed authentication.

=head1 CONFIGURATION

=over 4

=item * authenticator (required)

Coderef that receives ($username, $password) and returns true for valid credentials.

=item * realm (default: 'Restricted')

The authentication realm shown in the WWW-Authenticate header.

=item * paths (optional)

Arrayref of path patterns to protect. If not specified, all paths are protected.

=back

=cut

sub _init {
    my ($self, $config) = @_;

    $self->{authenticator} = $config->{authenticator}
        // die "Auth::Basic requires 'authenticator' option";
    $self->{realm} = $config->{realm} // 'Restricted';
    $self->{paths} = $config->{paths};
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
            await $self->_send_unauthorized($send);
            return;
        }

        # Parse Basic authentication
        my ($username, $password) = $self->_parse_basic_auth($auth_header);

        unless (defined $username) {
            await $self->_send_unauthorized($send);
            return;
        }

        # Validate credentials
        my $valid = eval { $self->{authenticator}->($username, $password) };
        if ($@ || !$valid) {
            await $self->_send_unauthorized($send);
            return;
        }

        # Add auth info to scope
        my $new_scope = {
            %$scope,
            'pagi.auth' => {
                type     => 'basic',
                username => $username,
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

sub _parse_basic_auth {
    my ($self, $header) = @_;

    return unless $header =~ /^Basic\s+(.+)$/i;

    my $encoded = $1;
    my $decoded = eval { decode_base64($encoded) };
    return unless $decoded;

    my ($username, $password) = split /:/, $decoded, 2;
    return unless defined $username;

    return ($username, $password // '');
}

async sub _send_unauthorized {
    my ($self, $send) = @_;

    my $realm_escaped = $self->{realm};
    $realm_escaped =~ s/"/\\"/g;

    my $body = 'Unauthorized';

    await $send->({
        type    => 'http.response.start',
        status  => 401,
        headers => [
            ['Content-Type', 'text/plain'],
            ['Content-Length', length($body)],
            ['WWW-Authenticate', qq{Basic realm="$realm_escaped", charset="UTF-8"}],
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
        type     => 'basic',
        username => 'the-username',
    }

=back

=head1 SECURITY CONSIDERATIONS

HTTP Basic Authentication transmits credentials in base64 encoding (not encrypted).
Always use HTTPS when using Basic Authentication in production.

=head1 SEE ALSO

L<PAGI::Middleware> - Base class for middleware

L<PAGI::Middleware::Auth::Bearer> - Bearer token authentication

=cut
