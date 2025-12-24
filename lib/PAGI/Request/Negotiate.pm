package PAGI::Request::Negotiate;
use strict;
use warnings;

our $VERSION = '0.01';

=head1 NAME

PAGI::Request::Negotiate - Content negotiation utilities for PAGI

=head1 SYNOPSIS

    use PAGI::Request::Negotiate;

    # Parse Accept header
    my @types = PAGI::Request::Negotiate->parse_accept(
        'text/html, application/json;q=0.9, */*;q=0.1'
    );
    # Returns: (['text/html', 1], ['application/json', 0.9], ['*/*', 0.1])

    # Find best match
    my $best = PAGI::Request::Negotiate->best_match(
        ['application/json', 'text/html'],
        'text/html, application/json;q=0.9'
    );
    # Returns: 'text/html'

    # Check if type is acceptable
    my $accepts = PAGI::Request::Negotiate->accepts_type(
        'text/html, application/json',
        'json'
    );

    # Get quality value for type
    my $quality = PAGI::Request::Negotiate->quality_for_type(
        'application/json;q=0.9',
        'json'
    );

=head1 DESCRIPTION

PAGI::Request::Negotiate provides utilities for HTTP content negotiation,
including parsing Accept headers and finding the best matching content type.

This module supports quality values, wildcards (*/*, type/*), and common
MIME type shortcuts (json, html, xml, etc.).

=head1 CLASS METHODS

=cut

# Common MIME type shortcuts
my %TYPE_SHORTCUTS = (
    html => 'text/html',
    text => 'text/plain',
    txt  => 'text/plain',
    json => 'application/json',
    xml  => 'application/xml',
    atom => 'application/atom+xml',
    rss  => 'application/rss+xml',
    css  => 'text/css',
    js   => 'application/javascript',
    png  => 'image/png',
    jpg  => 'image/jpeg',
    jpeg => 'image/jpeg',
    gif  => 'image/gif',
    svg  => 'image/svg+xml',
    pdf  => 'application/pdf',
    zip  => 'application/zip',
    form => 'application/x-www-form-urlencoded',
);

=head2 parse_accept

    my @types = PAGI::Request::Negotiate->parse_accept($header);

Parse an Accept header and return a list of arrayrefs containing
C<[media_type, quality]> sorted by preference (quality descending,
then specificity descending).

If no Accept header is provided, returns a single entry for C<*/*> with
quality 1.

Quality values are clamped to the range [0, 1].

Specificity ordering: exact types > type/* > */*

=cut

sub parse_accept {
    my ($class, $header) = @_;
    # No Accept header means accept everything
    return (['*/*', 1]) unless defined $header && length $header;

    my @types;

    for my $part (split /\s*,\s*/, $header) {
        # Parse: type/subtype;param=value;q=0.9;ext=value
        my ($type, @params) = split /\s*;\s*/, $part;
        next unless defined $type && length $type;

        # Normalize type
        $type = lc($type);
        $type =~ s/^\s+//;
        $type =~ s/\s+$//;

        # Extract quality value (default 1)
        my $quality = 1;
        for my $param (@params) {
            if ($param =~ /^q\s*=\s*(-?[0-9.]+)$/i) {
                $quality = $1 + 0;  # Convert to number
                $quality = 1 if $quality > 1;
                $quality = 0 if $quality < 0;
                last;
            }
        }

        push @types, [$type, $quality];
    }

    # Sort by quality (highest first), then by specificity
    @types = sort {
        # Primary: quality (descending)
        my $cmp = $b->[1] <=> $a->[1];
        return $cmp if $cmp;

        # Secondary: specificity (more specific first)
        # */* < type/* < type/subtype
        my $spec_a = _specificity($a->[0]);
        my $spec_b = _specificity($b->[0]);
        return $spec_b <=> $spec_a;
    } @types;

    return @types;
}

# Calculate specificity score for sorting
# Returns: 0 for */*, 1 for type/*, 2 for type/subtype
sub _specificity {
    my ($type) = @_;
    return 0 if $type eq '*/*';
    return 1 if $type =~ m{^[^/]+/\*$};
    return 2;
}

=head2 best_match

    my $type = PAGI::Request::Negotiate->best_match(\@supported, $accept_header);

Find the best matching content type from C<@supported> based on the
Accept header. Returns the best match or undef if none acceptable.

C<@supported> can contain full MIME types or shortcuts (html, json, xml, etc.)

The returned value is from the C<@supported> array (preserves shortcuts).

=cut

sub best_match {
    my ($class, $supported, $accept_header) = @_;
    return unless $supported && @$supported;

    # Parse Accept header
    my @accepted = $class->parse_accept($accept_header);

    # Normalize supported types (expand shortcuts)
    my @normalized = map { $class->normalize_type($_) } @$supported;

    # Find best match
    for my $accepted (@accepted) {
        my ($type, $quality) = @$accepted;
        next if $quality == 0;  # Explicitly rejected

        for my $i (0 .. $#normalized) {
            if ($class->type_matches($normalized[$i], $type)) {
                # Return original (possibly shortcut) type
                return $supported->[$i];
            }
        }
    }

    return;
}

=head2 type_matches

    my $bool = PAGI::Request::Negotiate->type_matches($type, $pattern);

Check if a media type matches a pattern. Patterns can include wildcards
like C<*/*> or C<text/*>.

Both type and pattern are compared case-insensitively.

=cut

sub type_matches {
    my ($class, $type, $pattern) = @_;
    $type = lc($type);
    $pattern = lc($pattern);

    # Exact match
    return 1 if $type eq $pattern;

    # Wildcard match
    return 1 if $pattern eq '*/*';

    # Type wildcard (e.g., text/*)
    if ($pattern =~ m{^([^/]+)/\*$}) {
        my $major = $1;
        return 1 if $type =~ m{^\Q$major\E/};
    }

    return 0;
}

=head2 normalize_type

    my $mime = PAGI::Request::Negotiate->normalize_type($type);

Convert a type shortcut to its full MIME type. Known shortcuts include:

    html   => text/html
    json   => application/json
    xml    => application/xml
    atom   => application/atom+xml
    rss    => application/rss+xml
    text   => text/plain
    txt    => text/plain
    css    => text/css
    js     => application/javascript
    png    => image/png
    jpg    => image/jpeg
    jpeg   => image/jpeg
    gif    => image/gif
    svg    => image/svg+xml
    pdf    => application/pdf
    zip    => application/zip
    form   => application/x-www-form-urlencoded

If the type is already a MIME type (contains '/'), it's returned as-is.

Unknown shortcuts are prefixed with 'application/'.

=cut

sub normalize_type {
    my ($class, $type) = @_;
    return $type if $type =~ m{/};
    return $TYPE_SHORTCUTS{lc($type)} // "application/$type";
}

=head2 accepts_type

    my $bool = PAGI::Request::Negotiate->accepts_type($accept_header, $type);

Check if a specific content type is acceptable based on the Accept header.

The type can be a full MIME type or a shortcut.

Returns false if the type has quality=0 (explicitly rejected).

=cut

sub accepts_type {
    my ($class, $accept_header, $type) = @_;
    $type = $class->normalize_type($type);

    my @accepted = $class->parse_accept($accept_header);

    for my $accepted (@accepted) {
        my ($pattern, $quality) = @$accepted;
        next if $quality == 0;

        # Check both directions: type matches pattern OR pattern matches type
        # This allows accepts('text/*') to return true if client accepts 'text/html'
        return 1 if $class->type_matches($type, $pattern);
        return 1 if $class->type_matches($pattern, $type);
    }

    return 0;
}

=head2 quality_for_type

    my $q = PAGI::Request::Negotiate->quality_for_type($accept_header, $type);

Get the quality value for a specific type. Returns 0 if not acceptable.

When multiple patterns match (e.g., both text/* and text/html), returns
the quality of the most specific match.

The type can be a full MIME type or a shortcut.

=cut

sub quality_for_type {
    my ($class, $accept_header, $type) = @_;
    $type = $class->normalize_type($type);

    my @accepted = $class->parse_accept($accept_header);

    my $best_quality = 0;
    my $best_specificity = -1;

    for my $accepted (@accepted) {
        my ($pattern, $quality) = @$accepted;

        if ($class->type_matches($type, $pattern)) {
            my $spec = _specificity($pattern);
            if ($spec > $best_specificity ||
                ($spec == $best_specificity && $quality > $best_quality)) {
                $best_quality = $quality;
                $best_specificity = $spec;
            }
        }
    }

    return $best_quality;
}

=head1 EXAMPLES

=head2 Content Negotiation in a PAGI App

    use PAGI::Request::Negotiate;

    async sub app ($scope, $receive, $send) {
        my $accept = $scope->{headers}{accept} // '*/*';

        my $format = PAGI::Request::Negotiate->best_match(
            ['json', 'html', 'xml'],
            $accept
        );

        my ($body, $content_type);
        if ($format eq 'json') {
            $body = '{"message":"Hello"}';
            $content_type = 'application/json';
        } elsif ($format eq 'html') {
            $body = '<h1>Hello</h1>';
            $content_type = 'text/html';
        } else {
            $body = '<message>Hello</message>';
            $content_type = 'application/xml';
        }

        await $send->({
            type => 'http.response.start',
            status => 200,
            headers => [['content-type', $content_type]],
        });

        await $send->({
            type => 'http.response.body',
            body => $body,
        });
    }

=head1 SEE ALSO

L<PAGI::Request>, L<PAGI>

RFC 7231 Section 5.3 - Content Negotiation

=head1 AUTHOR

PAGI Contributors

=cut

1;
