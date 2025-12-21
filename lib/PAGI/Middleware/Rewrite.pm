package PAGI::Middleware::Rewrite;

use strict;
use warnings;
use parent 'PAGI::Middleware';
use Future::AsyncAwait;

=head1 NAME

PAGI::Middleware::Rewrite - URL rewriting middleware

=head1 SYNOPSIS

    use PAGI::Middleware::Builder;

    my $app = builder {
        enable 'Rewrite',
            rules => [
                { from => qr{^/old/(.*)}, to => '/new/$1' },
                { from => '/legacy', to => '/modern' },
            ];
        $my_app;
    };

=head1 DESCRIPTION

PAGI::Middleware::Rewrite rewrites request paths before passing to the
inner application. Supports both exact matches and regex patterns.

=head1 CONFIGURATION

=over 4

=item * rules (required)

Arrayref of rewrite rules. Each rule is a hashref with:

    { from => '/old-path', to => '/new-path' }
    { from => qr{^/user/(\d+)}, to => '/users/$1' }

=item * redirect (default: 0)

If true, send redirect response instead of rewriting internally.

=item * redirect_code (default: 301)

HTTP status code for redirects.

=back

=cut

sub _init {
    my ($self, $config) = @_;

    $self->{rules} = $config->{rules}
        // die "Rewrite middleware requires 'rules' option";
    $self->{redirect} = $config->{redirect} // 0;
    $self->{redirect_code} = $config->{redirect_code} // 301;
}

sub wrap {
    my ($self, $app) = @_;

    return async sub  {
        my ($scope, $receive, $send) = @_;
        if ($scope->{type} ne 'http') {
            await $app->($scope, $receive, $send);
            return;
        }

        my $path = $scope->{path};
        my $new_path = $self->_apply_rules($path);

        # No rewrite needed
        if ($new_path eq $path) {
            await $app->($scope, $receive, $send);
            return;
        }

        # Redirect mode
        if ($self->{redirect}) {
            my $location = $new_path;
            if (defined $scope->{query_string} && $scope->{query_string} ne '') {
                $location .= '?' . $scope->{query_string};
            }
            await $self->_send_redirect($send, $location);
            return;
        }

        # Internal rewrite
        my $new_scope = {
            %$scope,
            path          => $new_path,
            original_path => $scope->{original_path} // $path,
        };

        await $app->($new_scope, $receive, $send);
    };
}

sub _apply_rules {
    my ($self, $path) = @_;

    for my $rule (@{$self->{rules}}) {
        my $from = $rule->{from};
        my $to = $rule->{to};

        if (ref $from eq 'Regexp') {
            if ($path =~ $from) {
                my @captures = ($path =~ $from);
                my $new_path = $to;
                for my $i (0 .. $#captures) {
                    my $n = $i + 1;
                    $new_path =~ s/\$$n/$captures[$i]/g;
                }
                return $new_path;
            }
        } else {
            if ($path eq $from) {
                return $to;
            }
            # Also check prefix match for directory-like rules
            if ($path =~ m{^\Q$from\E(/.*)?$}) {
                my $suffix = $1 // '';
                return $to . $suffix;
            }
        }
    }

    return $path;
}

async sub _send_redirect {
    my ($self, $send, $location) = @_;

    my $status = $self->{redirect_code};
    my $body = "Redirecting to $location";

    await $send->({
        type    => 'http.response.start',
        status  => $status,
        headers => [
            ['Content-Type', 'text/plain'],
            ['Content-Length', length($body)],
            ['Location', $location],
        ],
    });
    await $send->({
        type => 'http.response.body',
        body => $body,
        more => 0,
    });
}

1;

__END__

=head1 REWRITE PATTERNS

Regex patterns can use capture groups:

    { from => qr{^/blog/(\d{4})/(\d{2})}, to => '/archive/$1-$2' }

This would rewrite C</blog/2024/01> to C</archive/2024-01>.

=head1 SEE ALSO

L<PAGI::Middleware> - Base class for middleware

L<PAGI::Middleware::HTTPSRedirect> - Force HTTPS redirects

=cut
