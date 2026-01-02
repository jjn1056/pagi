package PAGI::Middleware::JSONBody;

use strict;
use warnings;
use parent 'PAGI::Middleware';
use Future::AsyncAwait;
use JSON::MaybeXS ();

=head1 NAME

PAGI::Middleware::JSONBody - JSON request body parsing middleware

=head1 SYNOPSIS

    use PAGI::Middleware::Builder;

    my $app = builder {
        enable 'JSONBody';
        $my_app;
    };

    # In your app:
    async sub app {
        my ($scope, $receive, $send) = @_;

        my $json_data = $scope->{pagi.parsed_body};
        # $json_data is a hashref/arrayref from JSON
    }

=head1 DESCRIPTION

PAGI::Middleware::JSONBody parses JSON request bodies and makes the
parsed data available in C<< $scope->{'pagi.parsed_body'} >>.

=head1 CONFIGURATION

=over 4

=item * max_size (default: 1MB)

Maximum body size to parse (in bytes).

=item * content_types (default: application/json)

Content-Type patterns to parse.

=back

=cut

sub _init {
    my ($self, $config) = @_;

    $self->{max_size} = $config->{max_size} // 1024 * 1024;  # 1MB
    $self->{content_types} = $config->{content_types} // [
        'application/json',
        'application/json; charset=utf-8',
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

        # Check content type
        my $content_type = $self->_get_header($scope, 'content-type') // '';
        my $is_json = $self->_is_json_content_type($content_type);

        unless ($is_json) {
            await $app->($scope, $receive, $send);
            return;
        }

        # Read and parse body
        my $body = '';
        my $too_large = 0;

        while (1) {
            my $event = await $receive->();
            last unless $event && $event->{type};

            if ($event->{type} eq 'http.request') {
                $body .= $event->{body} // '';
                if (length($body) > $self->{max_size}) {
                    $too_large = 1;
                    last;
                }
                last unless $event->{more};
            }
            elsif ($event->{type} eq 'http.disconnect') {
                last;
            }
        }

        if ($too_large) {
            await $self->_send_error($send, 413, 'Request body too large');
            return;
        }

        # Parse JSON
        my $parsed;
        eval {
            $parsed = JSON::MaybeXS::decode_json($body);
        };
        if ($@) {
            await $self->_send_error($send, 400, 'Invalid JSON: ' . $@);
            return;
        }

        # Create modified scope with parsed body
        my $new_scope = {
            %$scope,
            'pagi.parsed_body' => $parsed,
            'pagi.raw_body'    => $body,
        };

        # Create a receive that returns empty (body already consumed)
        my $empty_receive = async sub {
            return { type => 'http.request', body => '', more => 0 };
        };

        await $app->($new_scope, $empty_receive, $send);
    };
}

sub _is_json_content_type {
    my ($self, $content_type) = @_;

    $content_type = lc($content_type);
    $content_type =~ s/\s+//g;  # Remove whitespace

    for my $pattern (@{$self->{content_types}}) {
        my $lc_pattern = lc($pattern);
        $lc_pattern =~ s/\s+//g;
        return 1 if index($content_type, $lc_pattern) == 0;
    }

    # Also match any application/XXX+json
    return 1 if $content_type =~ m{^application/[^;]+\+json};

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

async sub _send_error {
    my ($self, $send, $status, $message) = @_;

    my $body = JSON::MaybeXS::encode_json({ error => $message });

    await $send->({
        type    => 'http.response.start',
        status  => $status,
        headers => [
            ['Content-Type', 'application/json'],
            ['Content-Length', length($body)],
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

=head1 SCOPE EXTENSIONS

This middleware adds the following to $scope:

=over 4

=item * pagi.parsed_body

The parsed JSON data (hashref or arrayref).

=item * pagi.raw_body

The raw request body string.

=back

=head1 SEE ALSO

L<PAGI::Middleware> - Base class for middleware

L<PAGI::Middleware::FormBody> - Form body parsing

=cut

