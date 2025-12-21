package PAGI::Middleware::ConditionalGet;

use strict;
use warnings;
use parent 'PAGI::Middleware';
use Future::AsyncAwait;

=head1 NAME

PAGI::Middleware::ConditionalGet - Conditional GET/HEAD request handling

=head1 SYNOPSIS

    use PAGI::Middleware::Builder;

    my $app = builder {
        enable 'ETag';           # Generate ETags
        enable 'ConditionalGet'; # Handle If-None-Match
        $my_app;
    };

=head1 DESCRIPTION

PAGI::Middleware::ConditionalGet returns 304 Not Modified for GET/HEAD
requests when the client's conditional headers match. Supports:

- If-None-Match: Compare against ETag header
- If-Modified-Since: Compare against Last-Modified header

=cut

sub wrap {
    my ($self, $app) = @_;

    return async sub  {
        my ($scope, $receive, $send) = @_;
        if ($scope->{type} ne 'http') {
            await $app->($scope, $receive, $send);
            return;
        }

        # Only handle GET and HEAD requests
        my $method = uc($scope->{method} // '');
        unless ($method eq 'GET' || $method eq 'HEAD') {
            await $app->($scope, $receive, $send);
            return;
        }

        # Get conditional request headers
        my $if_none_match = $self->_get_header($scope, 'if-none-match');
        my $if_modified_since = $self->_get_header($scope, 'if-modified-since');

        # No conditional headers? Pass through
        unless (defined $if_none_match || defined $if_modified_since) {
            await $app->($scope, $receive, $send);
            return;
        }

        # Capture response headers
        my $response_status;
        my $response_headers;
        my $sent_304 = 0;

        my $wrapped_send = async sub  {
        my ($event) = @_;
            if ($event->{type} eq 'http.response.start') {
                $response_status = $event->{status};
                $response_headers = $event->{headers};

                # Only handle 2xx responses
                if ($response_status >= 200 && $response_status < 300) {
                    my $etag = $self->_get_response_header($response_headers, 'etag');
                    my $last_modified = $self->_get_response_header($response_headers, 'last-modified');

                    my $not_modified = 0;

                    # Check If-None-Match
                    if (defined $if_none_match && defined $etag) {
                        $not_modified = $self->_etag_matches($if_none_match, $etag);
                    }
                    # Check If-Modified-Since (only if no If-None-Match)
                    elsif (defined $if_modified_since && defined $last_modified) {
                        $not_modified = $self->_not_modified_since($if_modified_since, $last_modified);
                    }

                    if ($not_modified) {
                        # Send 304 response
                        my @headers_304 = $self->_filter_headers_for_304($response_headers);
                        await $send->({
                            type    => 'http.response.start',
                            status  => 304,
                            headers => \@headers_304,
                        });
                        await $send->({
                            type => 'http.response.body',
                            body => '',
                            more => 0,
                        });
                        $sent_304 = 1;
                        return;
                    }
                }

                await $send->($event);
            }
            elsif ($event->{type} eq 'http.response.body') {
                return if $sent_304;  # Skip body if we sent 304
                await $send->($event);
            }
            else {
                await $send->($event);
            }
        };

        await $app->($scope, $receive, $wrapped_send);
    };
}

sub _get_header {
    my ($self, $scope, $name) = @_;

    $name = lc($name);
    for my $h (@{$scope->{headers} // []}) {
        return $h->[1] if lc($h->[0]) eq $name;
    }
    return;
}

sub _get_response_header {
    my ($self, $headers, $name) = @_;

    $name = lc($name);
    for my $h (@{$headers // []}) {
        return $h->[1] if lc($h->[0]) eq $name;
    }
    return;
}

sub _etag_matches {
    my ($self, $if_none_match, $etag) = @_;

    # Parse If-None-Match which can be comma-separated
    # ETags can be weak (W/"...") or strong ("...")

    # Handle * wildcard
    return 1 if $if_none_match eq '*';

    # Normalize ETags for comparison (weak comparison)
    my $normalize = sub  {
        my ($tag) = @_;
        $tag =~ s/^\s+//;
        $tag =~ s/\s+$//;
        $tag =~ s/^W\///i;  # Remove weak prefix for comparison
        return $tag;
    };

    my $normalized_etag = $normalize->($etag);

    for my $tag (split /\s*,\s*/, $if_none_match) {
        my $normalized_tag = $normalize->($tag);
        return 1 if $normalized_tag eq $normalized_etag;
    }
    return 0;
}

sub _not_modified_since {
    my ($self, $if_modified_since, $last_modified) = @_;

    # Parse HTTP dates and compare
    # This is a simplified comparison - both should be HTTP-date format

    my $parse_date = sub  {
        my ($date_str) = @_;
        # Try to parse common HTTP date formats
        # RFC 1123: Sun, 06 Nov 1994 08:49:37 GMT
        # RFC 850:  Sunday, 06-Nov-94 08:49:37 GMT
        # asctime:  Sun Nov  6 08:49:37 1994

        require HTTP::Date;
        return HTTP::Date::str2time($date_str);
    };

    my $client_time = eval { $parse_date->($if_modified_since) };
    my $server_time = eval { $parse_date->($last_modified) };

    return 0 unless defined $client_time && defined $server_time;
    return $server_time <= $client_time;
}

sub _filter_headers_for_304 {
    my ($self, $headers) = @_;

    # RFC 7232: 304 response MUST include certain headers
    my @allowed = qw(
        cache-control content-location date etag expires
        last-modified vary
    );
    my %allowed = map { $_ => 1 } @allowed;

    my @filtered;
    for my $h (@{$headers // []}) {
        push @filtered, $h if $allowed{lc($h->[0])};
    }
    return @filtered;
}

1;

__END__

=head1 SEE ALSO

L<PAGI::Middleware> - Base class for middleware

L<PAGI::Middleware::ETag> - Generate ETag headers

=cut
