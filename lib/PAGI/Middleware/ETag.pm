package PAGI::Middleware::ETag;

use strict;
use warnings;
use experimental 'signatures';
use parent 'PAGI::Middleware';
use Future::AsyncAwait;
use Digest::MD5 qw(md5_hex);

=head1 NAME

PAGI::Middleware::ETag - ETag generation middleware

=head1 SYNOPSIS

    use PAGI::Middleware::Builder;

    my $app = builder {
        enable 'ETag';
        $my_app;
    };

=head1 DESCRIPTION

PAGI::Middleware::ETag generates ETag headers for responses based on
the response body content. Works best with buffered (non-streaming) responses.

=head1 CONFIGURATION

=over 4

=item * weak (default: 0)

If true, generate weak ETags (W/"...").

=back

=cut

sub _init ($self, $config) {
    $self->{weak} = $config->{weak} // 0;
}

sub wrap ($self, $app) {
    return async sub ($scope, $receive, $send) {
        if ($scope->{type} ne 'http') {
            await $app->($scope, $receive, $send);
            return;
        }

        my @body_parts;
        my $original_headers;
        my $status;
        my $is_streaming = 0;

        my $wrapped_send = async sub ($event) {
            if ($event->{type} eq 'http.response.start') {
                $status = $event->{status};
                $original_headers = $event->{headers};
                # Check if already has ETag
                for my $h (@{$original_headers // []}) {
                    if (lc($h->[0]) eq 'etag') {
                        # Already has ETag, pass through
                        await $send->($event);
                        $is_streaming = 1;  # Flag to pass through body
                        return;
                    }
                }
            }
            elsif ($event->{type} eq 'http.response.body') {
                if ($is_streaming) {
                    await $send->($event);
                    return;
                }

                push @body_parts, $event->{body} // '';

                # If streaming, can't generate ETag
                if ($event->{more}) {
                    $is_streaming = 1;
                    await $send->({
                        type    => 'http.response.start',
                        status  => $status,
                        headers => $original_headers,
                    });
                    for my $part (@body_parts) {
                        await $send->({
                            type => 'http.response.body',
                            body => $part,
                            more => 1,
                        });
                    }
                    @body_parts = ();
                }
            }
            else {
                await $send->($event);
            }
        };

        await $app->($scope, $receive, $wrapped_send);

        return if $is_streaming;

        # Generate ETag from body
        my $body = join('', @body_parts);
        my $etag = $self->_generate_etag($body);

        # Add ETag to headers
        my @new_headers = @{$original_headers // []};
        push @new_headers, ['ETag', $etag];

        await $send->({
            type    => 'http.response.start',
            status  => $status,
            headers => \@new_headers,
        });
        await $send->({
            type => 'http.response.body',
            body => $body,
            more => 0,
        });
    };
}

sub _generate_etag ($self, $body) {
    my $hash = md5_hex($body);
    if ($self->{weak}) {
        return qq{W/"$hash"};
    }
    return qq{"$hash"};
}

1;

__END__

=head1 SEE ALSO

L<PAGI::Middleware> - Base class for middleware

L<PAGI::Middleware::ConditionalGet> - Use with ETag for 304 responses

=cut
