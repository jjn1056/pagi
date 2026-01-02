package PAGI::Middleware::FormBody;

use strict;
use warnings;
use parent 'PAGI::Middleware';
use Future::AsyncAwait;

=head1 NAME

PAGI::Middleware::FormBody - Form request body parsing middleware

=head1 SYNOPSIS

    use PAGI::Middleware::Builder;

    my $app = builder {
        enable 'FormBody';
        $my_app;
    };

    # In your app:
    async sub app {
        my ($scope, $receive, $send) = @_;

        my $form_data = $scope->{pagi.parsed_body};
        # $form_data is a hashref like { name => 'value', ... }
    }

=head1 DESCRIPTION

PAGI::Middleware::FormBody parses URL-encoded form request bodies and
makes the parsed data available in C<< $scope->{'pagi.parsed_body'} >>.

=head1 CONFIGURATION

=over 4

=item * max_size (default: 1MB)

Maximum body size to parse (in bytes).

=back

=cut

sub _init {
    my ($self, $config) = @_;

    $self->{max_size} = $config->{max_size} // 1024 * 1024;  # 1MB
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
        my $is_form = $content_type =~ m{^application/x-www-form-urlencoded}i;

        unless ($is_form) {
            await $app->($scope, $receive, $send);
            return;
        }

        # Read body
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

        # Parse form data
        my $parsed = $self->_parse_urlencoded($body);

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

sub _parse_urlencoded {
    my ($self, $body) = @_;

    my %result;

    for my $pair (split /&/, $body) {
        my ($key, $value) = split /=/, $pair, 2;
        next unless defined $key;

        $key   = $self->_url_decode($key);
        $value = defined $value ? $self->_url_decode($value) : '';

        # Handle multiple values for same key
        if (exists $result{$key}) {
            if (ref $result{$key} eq 'ARRAY') {
                push @{$result{$key}}, $value;
            } else {
                $result{$key} = [$result{$key}, $value];
            }
        } else {
            $result{$key} = $value;
        }
    }

    return \%result;
}

sub _url_decode {
    my ($self, $str) = @_;

    $str =~ s/\+/ /g;
    $str =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/eg;
    return $str;
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

    await $send->({
        type    => 'http.response.start',
        status  => $status,
        headers => [
            ['Content-Type', 'text/plain'],
            ['Content-Length', length($message)],
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

=head1 SCOPE EXTENSIONS

This middleware adds the following to $scope:

=over 4

=item * pagi.parsed_body

The parsed form data as a hashref. Multiple values for the same key
are returned as an arrayref.

=item * pagi.raw_body

The raw request body string.

=back

=head1 MULTIPART FORMS

This middleware only handles C<application/x-www-form-urlencoded> bodies.
For multipart form data (file uploads), use L<PAGI::Request> which has built-in
multipart parsing via L<PAGI::Request::MultiPartHandler>.

=head1 SEE ALSO

L<PAGI::Middleware> - Base class for middleware

L<PAGI::Middleware::JSONBody> - JSON body parsing

=cut

