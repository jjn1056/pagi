package PAGI::Middleware::ReverseProxy;

use strict;
use warnings;
use parent 'PAGI::Middleware';
use Future::AsyncAwait;

=head1 NAME

PAGI::Middleware::ReverseProxy - Handle X-Forwarded-* headers from reverse proxies

=head1 SYNOPSIS

    use PAGI::Middleware::Builder;

    my $app = builder {
        enable 'ReverseProxy',
            trusted_proxies => ['127.0.0.1', '10.0.0.0/8'];
        $my_app;
    };

=head1 DESCRIPTION

PAGI::Middleware::ReverseProxy processes X-Forwarded-* headers from trusted
reverse proxies and updates the scope with the original client information.

=head1 CONFIGURATION

=over 4

=item * trusted_proxies (default: ['127.0.0.1', '::1'])

Arrayref of trusted proxy IP addresses or CIDR ranges.

=item * trust_all (default: 0)

If true, trust X-Forwarded headers from any source. Use with caution!

=back

=head1 HEADERS PROCESSED

=over 4

=item * X-Forwarded-For - Original client IP

=item * X-Forwarded-Proto - Original protocol (http/https)

=item * X-Forwarded-Host - Original Host header

=item * X-Forwarded-Port - Original port

=item * X-Real-IP - Alternative to X-Forwarded-For (nginx)

=back

=cut

sub _init {
    my ($self, $config) = @_;

    $self->{trusted_proxies} = $config->{trusted_proxies} // ['127.0.0.1', '::1'];
    $self->{trust_all} = $config->{trust_all} // 0;
}

sub wrap {
    my ($self, $app) = @_;

    return async sub  {
        my ($scope, $receive, $send) = @_;
        if ($scope->{type} ne 'http') {
            await $app->($scope, $receive, $send);
            return;
        }

        # Check if request is from trusted proxy
        my $client_ip = $scope->{client}[0] // '';
        unless ($self->{trust_all} || $self->_is_trusted($client_ip)) {
            await $app->($scope, $receive, $send);
            return;
        }

        # Build modified scope
        my %new_scope = %$scope;

        # X-Forwarded-For or X-Real-IP
        my $forwarded_for = $self->_get_header($scope, 'x-forwarded-for');
        my $real_ip = $self->_get_header($scope, 'x-real-ip');

        if ($forwarded_for) {
            # Take the leftmost IP (original client)
            my ($original_ip) = split /\s*,\s*/, $forwarded_for;
            $original_ip =~ s/^\s+//;
            $original_ip =~ s/\s+$//;
            $new_scope{client} = [$original_ip, $scope->{client}[1]];
            $new_scope{original_client} = $scope->{client};
        } elsif ($real_ip) {
            $new_scope{client} = [$real_ip, $scope->{client}[1]];
            $new_scope{original_client} = $scope->{client};
        }

        # X-Forwarded-Proto
        my $forwarded_proto = $self->_get_header($scope, 'x-forwarded-proto');
        if ($forwarded_proto) {
            $forwarded_proto = lc($forwarded_proto);
            $new_scope{scheme} = $forwarded_proto if $forwarded_proto =~ /^https?$/;
        }

        # X-Forwarded-Host
        my $forwarded_host = $self->_get_header($scope, 'x-forwarded-host');
        if ($forwarded_host) {
            # Update headers with new Host
            my @new_headers;
            for my $h (@{$scope->{headers} // []}) {
                if (lc($h->[0]) eq 'host') {
                    push @new_headers, ['host', $forwarded_host];
                } else {
                    push @new_headers, $h;
                }
            }
            $new_scope{headers} = \@new_headers;
        }

        # X-Forwarded-Port
        my $forwarded_port = $self->_get_header($scope, 'x-forwarded-port');
        if ($forwarded_port && $forwarded_port =~ /^\d+$/) {
            $new_scope{server} = [$scope->{server}[0], int($forwarded_port)];
        }

        await $app->(\%new_scope, $receive, $send);
    };
}

sub _is_trusted {
    my ($self, $ip) = @_;

    for my $trusted (@{$self->{trusted_proxies}}) {
        if ($trusted =~ m{/}) {
            # CIDR notation
            return 1 if $self->_ip_in_cidr($ip, $trusted);
        } else {
            # Exact match
            return 1 if $ip eq $trusted;
        }
    }
    return 0;
}

sub _ip_in_cidr {
    my ($self, $ip, $cidr) = @_;

    my ($network, $bits) = split m{/}, $cidr;

    # Simple IPv4 check
    return 0 unless $ip =~ /^[\d.]+$/ && $network =~ /^[\d.]+$/;

    my $ip_num = $self->_ip_to_num($ip);
    my $net_num = $self->_ip_to_num($network);

    return 0 unless defined $ip_num && defined $net_num;

    my $mask = ~((1 << (32 - $bits)) - 1) & 0xFFFFFFFF;
    return ($ip_num & $mask) == ($net_num & $mask);
}

sub _ip_to_num {
    my ($self, $ip) = @_;

    my @octets = split /\./, $ip;
    return unless @octets == 4;
    return unless _all(sub { /^\d+$/ && $_ >= 0 && $_ <= 255 }, @octets);

    return ($octets[0] << 24) + ($octets[1] << 16) + ($octets[2] << 8) + $octets[3];
}

sub _all {
    my ($code, @list) = @_;
    for (@list) {
        return 0 unless $code->();
    }
    return 1;
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

=head1 SCOPE MODIFICATIONS

When headers are processed from a trusted proxy:

=over 4

=item * client - Updated to original client [IP, port]

=item * original_client - The proxy's [IP, port]

=item * scheme - Updated to 'https' if X-Forwarded-Proto indicates

=item * headers - Host header updated if X-Forwarded-Host present

=item * server - Port updated if X-Forwarded-Port present

=back

=head1 SECURITY

Only trust X-Forwarded headers from known reverse proxies.
Never enable C<trust_all> in production unless you fully understand
the security implications.

=head1 SEE ALSO

L<PAGI::Middleware> - Base class for middleware

L<PAGI::Middleware::HTTPSRedirect> - HTTPS redirect

=cut
