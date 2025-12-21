package PAGI::Middleware::ContentNegotiation;

use strict;
use warnings;
use parent 'PAGI::Middleware';
use Future::AsyncAwait;

=head1 NAME

PAGI::Middleware::ContentNegotiation - HTTP content negotiation middleware

=head1 SYNOPSIS

    use PAGI::Middleware::Builder;

    my $app = builder {
        enable 'ContentNegotiation',
            supported_types => ['application/json', 'text/html', 'text/plain'],
            default_type => 'application/json';
        $my_app;
    };

    # In your app:
    async sub app {
        my ($scope, $receive, $send) = @_;
    
        my $preferred = $scope->{'pagi.preferred_content_type'};
        if ($preferred eq 'application/json') {
            # Return JSON
        } else {
            # Return HTML
        }
    }

=head1 DESCRIPTION

PAGI::Middleware::ContentNegotiation parses the Accept header and determines
the best content type to return. It adds the preferred type to the scope
for the application to use.

=head1 CONFIGURATION

=over 4

=item * supported_types (required)

Array of MIME types the application supports.

=item * default_type (optional)

Default type when no Accept header or no match. Defaults to first supported type.

=item * strict (default: 0)

If true, return 406 Not Acceptable when no supported type matches.

=back

=cut

sub _init {
    my ($self, $config) = @_;

    $self->{supported_types} = $config->{supported_types}
        // die "ContentNegotiation requires 'supported_types' option";
    $self->{default_type} = $config->{default_type}
        // $self->{supported_types}[0];
    $self->{strict} = $config->{strict} // 0;
}

sub wrap {
    my ($self, $app) = @_;

    return async sub  {
        my ($scope, $receive, $send) = @_;
        if ($scope->{type} ne 'http') {
            await $app->($scope, $receive, $send);
            return;
        }

        # Parse Accept header
        my $accept = $self->_get_header($scope, 'accept') // '*/*';
        my $preferred = $self->_negotiate($accept);

        if (!$preferred && $self->{strict}) {
            await $self->_send_not_acceptable($send);
            return;
        }

        $preferred //= $self->{default_type};

        # Add preferred type to scope
        my @accepted = $self->_parse_accept($accept);
        my $new_scope = {
            %$scope,
            'pagi.preferred_content_type' => $preferred,
            'pagi.accepted_types' => \@accepted,
        };

        await $app->($new_scope, $receive, $send);
    };
}

sub _negotiate {
    my ($self, $accept) = @_;

    my @accepted = $self->_parse_accept($accept);
    return unless @accepted;

    for my $item (@accepted) {
        my $type = $item->{type};

        # Check for exact match
        for my $supported (@{$self->{supported_types}}) {
            return $supported if lc($type) eq lc($supported);
        }

        # Check for wildcard matches
        if ($type eq '*/*') {
            return $self->{supported_types}[0];
        }

        if ($type =~ m{^([^/]+)/\*$}) {
            my $major = lc($1);
            for my $supported (@{$self->{supported_types}}) {
                return $supported if $supported =~ m{^$major/}i;
            }
        }
    }

    return;
}

sub _parse_accept {
    my ($self, $accept) = @_;

    my @items;

    for my $part (split /\s*,\s*/, $accept) {
        my ($type, @params) = split /\s*;\s*/, $part;
        next unless $type;

        my $q = 1.0;
        for my $param (@params) {
            if ($param =~ /^q\s*=\s*([0-9.]+)$/i) {
                $q = $1 + 0;
                last;
            }
        }

        push @items, { type => $type, q => $q };
    }

    # Sort by quality value, descending
    @items = sort { $b->{q} <=> $a->{q} } @items;

    return @items;
}

sub _get_header {
    my ($self, $scope, $name) = @_;

    $name = lc($name);
    for my $h (@{$scope->{headers} // []}) {
        return $h->[1] if lc($h->[0]) eq $name;
    }
    return;
}

async sub _send_not_acceptable {
    my ($self, $send) = @_;

    my $supported = join(', ', @{$self->{supported_types}});
    my $body = "Not Acceptable. Supported types: $supported";

    await $send->({
        type    => 'http.response.start',
        status  => 406,
        headers => [
            ['Content-Type', 'text/plain'],
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

=item * pagi.preferred_content_type

The best matching MIME type from the supported types.

=item * pagi.accepted_types

Array of parsed Accept header entries, sorted by quality value.

=back

=head1 ACCEPT HEADER PARSING

The Accept header is parsed according to RFC 7231:

    Accept: text/html, application/json;q=0.9, */*;q=0.1

Higher quality values (q) indicate higher preference. The default is q=1.0.

=head1 SEE ALSO

L<PAGI::Middleware> - Base class for middleware

=cut
