package PAGI::Middleware::MethodOverride;

use strict;
use warnings;
use parent 'PAGI::Middleware';
use Future::AsyncAwait;

=head1 NAME

PAGI::Middleware::MethodOverride - Override HTTP method from request data

=head1 SYNOPSIS

    use PAGI::Middleware::Builder;

    my $app = builder {
        enable 'MethodOverride',
            param => '_method',
            allowed_methods => [qw(PUT PATCH DELETE)];
        $my_app;
    };

=head1 DESCRIPTION

PAGI::Middleware::MethodOverride allows overriding the HTTP method
using a form field, query parameter, or header. This enables HTML
forms (which only support GET and POST) to submit PUT, PATCH, and
DELETE requests.

=head1 CONFIGURATION

=over 4

=item * param (default: '_method')

Form field or query parameter name for method override.

=item * header (default: 'X-HTTP-Method-Override')

HTTP header name for method override.

=item * allowed_methods (default: [PUT, PATCH, DELETE])

Methods that can be overridden to. GET and POST are not allowed
for security reasons.

=item * check_header (default: 1)

Check the X-HTTP-Method-Override header.

=item * check_param (default: 1)

Check the _method query/form parameter.

=back

=cut

sub _init {
    my ($self, $config) = @_;

    $self->{param} = $config->{param} // '_method';
    $self->{header} = $config->{header} // 'x-http-method-override';
    $self->{allowed_methods} = $config->{allowed_methods} // [qw(PUT PATCH DELETE)];
    $self->{check_header} = $config->{check_header} // 1;
    $self->{check_param} = $config->{check_param} // 1;

    # Build allowed method lookup
    $self->{allowed_lookup} = { map { uc($_) => 1 } @{$self->{allowed_methods}} };
}

sub wrap {
    my ($self, $app) = @_;

    return async sub  {
        my ($scope, $receive, $send) = @_;
        if ($scope->{type} ne 'http') {
            await $app->($scope, $receive, $send);
            return;
        }

        # Only apply to POST requests
        if (uc($scope->{method} // '') ne 'POST') {
            await $app->($scope, $receive, $send);
            return;
        }

        my $override_method = $self->_get_override_method($scope);

        if ($override_method) {
            # Validate method is allowed
            my $upper_method = uc($override_method);
            if ($self->{allowed_lookup}{$upper_method}) {
                # Create new scope with overridden method
                my $new_scope = {
                    %$scope,
                    method => $upper_method,
                    original_method => $scope->{method},
                };
                await $app->($new_scope, $receive, $send);
                return;
            }
        }

        await $app->($scope, $receive, $send);
    };
}

sub _get_override_method {
    my ($self, $scope) = @_;

    # Check header first (most secure)
    if ($self->{check_header}) {
        my $header_name = lc($self->{header});
        for my $h (@{$scope->{headers} // []}) {
            if (lc($h->[0]) eq $header_name) {
                return $h->[1];
            }
        }
    }

    # Check query parameter
    if ($self->{check_param}) {
        my $query = $scope->{query_string} // '';
        my $param_name = $self->{param};

        # Simple query string parsing
        for my $pair (split /&/, $query) {
            my ($key, $value) = split /=/, $pair, 2;
            $key //= '';
            $value //= '';

            # URL decode
            $key =~ s/\+/ /g;
            $key =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/ge;
            $value =~ s/\+/ /g;
            $value =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/ge;

            if ($key eq $param_name) {
                return $value;
            }
        }
    }

    return;
}

1;

__END__

=head1 HOW IT WORKS

When a POST request is received:

=over 4

=item 1. Check X-HTTP-Method-Override header (if enabled)

=item 2. Check _method query parameter (if enabled)

=item 3. If found and method is allowed, override scope->{method}

=item 4. Original method preserved in scope->{original_method}

=back

=head1 SECURITY NOTES

=over 4

=item * Only POST requests can be overridden

GET requests cannot be overridden as they should be safe and idempotent.

=item * Only specific methods allowed

By default only PUT, PATCH, DELETE are allowed. GET and POST are
never allowed as override targets.

=item * Header takes precedence

The X-HTTP-Method-Override header is checked before query parameters,
as it's harder to inject via CSRF attacks.

=back

=head1 HTML FORM USAGE

    <form method="POST" action="/resource/123">
        <input type="hidden" name="_method" value="DELETE">
        <button type="submit">Delete</button>
    </form>

=head1 AJAX USAGE

    fetch('/resource/123', {
        method: 'POST',
        headers: {
            'X-HTTP-Method-Override': 'DELETE'
        }
    });

=head1 SEE ALSO

L<PAGI::Middleware> - Base class for middleware

=cut
