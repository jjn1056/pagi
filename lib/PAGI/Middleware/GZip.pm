package PAGI::Middleware::GZip;

use strict;
use warnings;
use parent 'PAGI::Middleware';
use Future::AsyncAwait;
use IO::Compress::Gzip qw(gzip $GzipError);

=head1 NAME

PAGI::Middleware::GZip - Response compression middleware

=head1 SYNOPSIS

    use PAGI::Middleware::Builder;

    my $app = builder {
        enable 'GZip',
            min_size => 1024,
            mime_types => ['text/*', 'application/json'];
        $my_app;
    };

=head1 DESCRIPTION

PAGI::Middleware::GZip compresses response bodies using gzip when the
client supports it (Accept-Encoding: gzip).

=head1 CONFIGURATION

=over 4

=item * min_size (default: 1024)

Minimum response size to compress (bytes).

=item * mime_types (default: text/*, application/json, application/javascript)

MIME types to compress.

=back

=cut

sub _init {
    my ($self, $config) = @_;

    $self->{min_size} = $config->{min_size} // 1024;
    $self->{mime_types} = $config->{mime_types} // [
        'text/html', 'text/plain', 'text/css', 'text/javascript',
        'application/json', 'application/javascript', 'application/xml',
    ];
}

sub wrap {
    my ($self, $app) = @_;

    return async sub  {
        my ($scope, $receive, $send) = @_;
        if ($scope->{type} ne 'http') {
            await $app->($scope, $receive, $send);
            return;
        }

        # Check if client accepts gzip
        my $accept_encoding = $self->_get_header($scope, 'accept-encoding') // '';
        my $accepts_gzip = $accept_encoding =~ /\bgzip\b/i;

        unless ($accepts_gzip) {
            await $app->($scope, $receive, $send);
            return;
        }

        # Buffer response to compress
        my @body_parts;
        my $response_started = 0;
        my $content_type = '';
        my $original_headers;

        my $wrapped_send = async sub  {
        my ($event) = @_;
            if ($event->{type} eq 'http.response.start') {
                $original_headers = $event->{headers};
                # Get content type
                for my $h (@{$event->{headers} // []}) {
                    if (lc($h->[0]) eq 'content-type') {
                        $content_type = $h->[1];
                        last;
                    }
                }
                $response_started = 1;
                # Don't send yet - buffer to compress
            }
            elsif ($event->{type} eq 'http.response.body') {
                push @body_parts, $event->{body} // '';

                # If streaming (more => 1), pass through without compression
                if ($event->{more}) {
                    if (!$self->{_headers_sent}) {
                        await $send->({
                            type    => 'http.response.start',
                            status  => 200,
                            headers => $original_headers,
                        });
                        $self->{_headers_sent} = 1;
                    }
                    await $send->($event);
                }
            }
            else {
                await $send->($event);
            }
        };

        await $app->($scope, $receive, $wrapped_send);

        # If headers already sent (streaming), we're done
        return if $self->{_headers_sent};

        # Combine body
        my $body = join('', @body_parts);

        # Decide whether to compress
        my $should_compress = $self->_should_compress($content_type, length($body));

        if ($should_compress && length($body) > 0) {
            my $compressed;
            gzip(\$body, \$compressed) or die "gzip failed: $GzipError";

            # Update headers
            my @new_headers;
            for my $h (@{$original_headers // []}) {
                next if lc($h->[0]) eq 'content-length';
                push @new_headers, $h;
            }
            push @new_headers, ['Content-Encoding', 'gzip'];
            push @new_headers, ['Content-Length', length($compressed)];
            push @new_headers, ['Vary', 'Accept-Encoding'];

            await $send->({
                type    => 'http.response.start',
                status  => 200,
                headers => \@new_headers,
            });
            await $send->({
                type => 'http.response.body',
                body => $compressed,
                more => 0,
            });
        }
        else {
            await $send->({
                type    => 'http.response.start',
                status  => 200,
                headers => $original_headers,
            });
            await $send->({
                type => 'http.response.body',
                body => $body,
                more => 0,
            });
        }
    };
}

sub _should_compress {
    my ($self, $content_type, $size) = @_;

    return 0 if $size < $self->{min_size};

    $content_type =~ s/;.*//;  # Remove charset etc.
    $content_type = lc($content_type);

    for my $type (@{$self->{mime_types}}) {
        return 1 if $content_type eq lc($type);
        if ($type =~ /\*$/) {
            my $prefix = substr($type, 0, -1);
            return 1 if index($content_type, lc($prefix)) == 0;
        }
    }
    return 0;
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

=head1 SEE ALSO

L<PAGI::Middleware> - Base class for middleware

=cut
