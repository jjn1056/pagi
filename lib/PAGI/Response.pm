package PAGI::Response;

use strict;
use warnings;
use v5.32;
use feature 'signatures';
no warnings 'experimental::signatures';

use Future::AsyncAwait;
use Carp qw(croak);
use Encode qw(encode FB_CROAK);
use JSON::MaybeXS ();

our $VERSION = '0.01';

=head1 NAME

PAGI::Response - Fluent response builder for PAGI applications

=head1 SYNOPSIS

    use PAGI::Response;
    use Future::AsyncAwait;

    async sub app ($scope, $receive, $send) {
        my $res = PAGI::Response->new($send);

        # Fluent chaining
        await $res->status(200)
                  ->header('X-Custom' => 'value')
                  ->json({ message => 'Hello' });
    }

    # Various response types
    await $res->text("Hello World");
    await $res->html("<h1>Hello</h1>");
    await $res->json({ data => 'value' });
    await $res->redirect('/login');
    await $res->error(400, "Bad Request");

    # Streaming
    await $res->stream(async sub ($writer) {
        await $writer->write("chunk1");
        await $writer->write("chunk2");
        await $writer->close();
    });

    # File download
    await $res->send_file('/path/to/file.pdf', filename => 'doc.pdf');

=head1 DESCRIPTION

PAGI::Response provides a fluent interface for building HTTP responses in
raw PAGI applications. It wraps the low-level C<$send> callback and provides
convenient methods for common response types.

All chainable methods (C<status>, C<header>, C<content_type>, C<cookie>)
return C<$self> for fluent chaining. Finisher methods (C<text>, C<html>,
C<json>, C<redirect>, etc.) return Futures and send the response.

=head1 CONSTRUCTOR

=head2 new

    my $res = PAGI::Response->new($send);

Creates a new response builder. The C<$send> parameter must be a coderef
(the PAGI send callback).

=head1 CHAINABLE METHODS

These methods return C<$self> for fluent chaining.

=head2 status

    $res->status(404);

Set the HTTP status code (100-599).

=head2 header

    $res->header('X-Custom' => 'value');

Add a response header. Can be called multiple times to add multiple headers.

=head2 content_type

    $res->content_type('text/html; charset=utf-8');

Set the Content-Type header, replacing any existing one.

=head2 cookie

    $res->cookie('session' => 'abc123',
        max_age  => 3600,
        path     => '/',
        domain   => 'example.com',
        secure   => 1,
        httponly => 1,
        samesite => 'Strict',
    );

Set a response cookie. Options: max_age, expires, path, domain, secure,
httponly, samesite.

=head2 delete_cookie

    $res->delete_cookie('session');

Delete a cookie by setting it with Max-Age=0.

=head1 FINISHER METHODS

These methods return Futures and send the response.

=head2 text

    await $res->text("Hello World");

Send a plain text response with Content-Type: text/plain; charset=utf-8.

=head2 html

    await $res->html("<h1>Hello</h1>");

Send an HTML response with Content-Type: text/html; charset=utf-8.

=head2 json

    await $res->json({ message => 'Hello' });

Send a JSON response with Content-Type: application/json; charset=utf-8.

=head2 redirect

    await $res->redirect('/login');
    await $res->redirect('/new-url', 301);

Send a redirect response. Default status is 302.

=head2 empty

    await $res->empty();

Send an empty response with status 204 No Content (or custom status if set).

=head2 error

    await $res->error(400, "Bad Request");
    await $res->error(422, "Validation Failed", {
        errors => [{ field => 'email', message => 'Invalid' }]
    });

Send a JSON error response with status and error message.

=head2 send

    await $res->send($bytes);

Send raw bytes as the response body.

=head2 send_utf8

    await $res->send_utf8($text);
    await $res->send_utf8($text, charset => 'iso-8859-1');

Send UTF-8 encoded text. Adds charset to Content-Type if not present.

=head2 stream

    await $res->stream(async sub ($writer) {
        await $writer->write("chunk1");
        await $writer->write("chunk2");
        await $writer->close();
    });

Stream response chunks via callback. The callback receives a writer object
with C<write($chunk)>, C<close()>, and C<bytes_written()> methods.

=head2 send_file

    await $res->send_file('/path/to/file.pdf');
    await $res->send_file('/path/to/file.pdf',
        filename => 'download.pdf',
        inline   => 1,
    );

Send a file as the response. Options:

=over 4

=item * filename - Set Content-Disposition attachment filename

=item * inline - Use Content-Disposition: inline instead of attachment

=back

=head1 SEE ALSO

L<PAGI>, L<PAGI::Request>

=head1 AUTHOR

PAGI Contributors

=cut

sub new ($class, $send = undef) {
    croak("send is required") unless $send;
    croak("send must be a coderef") unless ref($send) eq 'CODE';

    my $self = bless {
        send    => $send,
        _status => 200,
        _headers => [],
        _sent   => 0,
    }, $class;

    return $self;
}

sub status ($self, $code) {
    croak("Status must be a number between 100-599")
        unless defined $code && $code =~ /^\d+$/ && $code >= 100 && $code <= 599;
    $self->{_status} = $code;
    return $self;
}

sub header ($self, $name, $value) {
    push @{$self->{_headers}}, [$name, $value];
    return $self;
}

sub content_type ($self, $type) {
    # Remove existing content-type headers
    $self->{_headers} = [grep { lc($_->[0]) ne 'content-type' } @{$self->{_headers}}];
    push @{$self->{_headers}}, ['content-type', $type];
    return $self;
}

async sub send ($self, $body = undef) {
    croak("Response already sent") if $self->{_sent};
    $self->{_sent} = 1;

    # Send start
    await $self->{send}->({
        type    => 'http.response.start',
        status  => $self->{_status},
        headers => $self->{_headers},
    });

    # Send body
    await $self->{send}->({
        type => 'http.response.body',
        body => $body,
        more => 0,
    });
}

async sub send_utf8 ($self, $body, %opts) {
    my $charset = $opts{charset} // 'utf-8';

    # Ensure content-type has charset
    my $has_ct = 0;
    for my $h (@{$self->{_headers}}) {
        if (lc($h->[0]) eq 'content-type') {
            $has_ct = 1;
            unless ($h->[1] =~ /charset=/i) {
                $h->[1] .= "; charset=$charset";
            }
            last;
        }
    }
    unless ($has_ct) {
        push @{$self->{_headers}}, ['content-type', "text/plain; charset=$charset"];
    }

    # Encode body
    my $encoded = encode($charset, $body // '', FB_CROAK);

    await $self->send($encoded);
}

async sub text ($self, $body) {
    $self->content_type('text/plain; charset=utf-8');
    await $self->send_utf8($body);
}

async sub html ($self, $body) {
    $self->content_type('text/html; charset=utf-8');
    await $self->send_utf8($body);
}

async sub json ($self, $data) {
    $self->content_type('application/json; charset=utf-8');
    my $body = JSON::MaybeXS->new(utf8 => 1, canonical => 1)->encode($data);
    await $self->send($body);
}

async sub redirect ($self, $url, $status = 302) {
    $self->{_status} = $status;
    $self->header('location', $url);
    await $self->send('');
}

async sub empty ($self) {
    # Use 204 if status hasn't been explicitly set to something other than 200
    if ($self->{_status} == 200) {
        $self->{_status} = 204;
    }
    await $self->send(undef);
}

sub cookie ($self, $name, $value, %opts) {
    my @parts = ("$name=$value");

    push @parts, "Max-Age=$opts{max_age}" if defined $opts{max_age};
    push @parts, "Expires=$opts{expires}" if defined $opts{expires};
    push @parts, "Path=$opts{path}" if defined $opts{path};
    push @parts, "Domain=$opts{domain}" if defined $opts{domain};
    push @parts, "Secure" if $opts{secure};
    push @parts, "HttpOnly" if $opts{httponly};
    push @parts, "SameSite=$opts{samesite}" if defined $opts{samesite};

    my $cookie_str = join('; ', @parts);
    push @{$self->{_headers}}, ['set-cookie', $cookie_str];

    return $self;
}

sub delete_cookie ($self, $name, %opts) {
    return $self->cookie($name, '',
        max_age => 0,
        path    => $opts{path},
        domain  => $opts{domain},
    );
}

# Writer class for streaming
package PAGI::Response::Writer {
    use strict;
    use warnings;
    use v5.32;
    use feature 'signatures';
    no warnings 'experimental::signatures';
    use Future::AsyncAwait;
    use Carp qw(croak);

    sub new ($class, $send) {
        return bless {
            send => $send,
            bytes_written => 0,
            closed => 0,
        }, $class;
    }

    async sub write ($self, $chunk) {
        croak("Writer already closed") if $self->{closed};
        $self->{bytes_written} += length($chunk // '');
        await $self->{send}->({
            type => 'http.response.body',
            body => $chunk,
            more => 1,
        });
    }

    async sub close ($self) {
        return if $self->{closed};
        $self->{closed} = 1;
        await $self->{send}->({
            type => 'http.response.body',
            body => '',
            more => 0,
        });
    }

    sub bytes_written ($self) {
        return $self->{bytes_written};
    }
}

package PAGI::Response;

async sub stream ($self, $callback) {
    croak("Response already sent") if $self->{_sent};
    $self->{_sent} = 1;

    # Send start
    await $self->{send}->({
        type    => 'http.response.start',
        status  => $self->{_status},
        headers => $self->{_headers},
    });

    # Create writer and call callback
    my $writer = PAGI::Response::Writer->new($self->{send});
    await $callback->($writer);

    # Ensure closed
    await $writer->close() unless $writer->{closed};
}

async sub error ($self, $status, $message, $extra = undef) {
    $self->{_status} = $status;

    my $body = {
        status => $status,
        error  => $message,
    };

    # Merge extra data if provided
    if ($extra && ref($extra) eq 'HASH') {
        for my $key (keys %$extra) {
            $body->{$key} = $extra->{$key};
        }
    }

    await $self->json($body);
}

# Simple MIME type mapping
my %MIME_TYPES = (
    '.html' => 'text/html',
    '.htm'  => 'text/html',
    '.txt'  => 'text/plain',
    '.css'  => 'text/css',
    '.js'   => 'application/javascript',
    '.json' => 'application/json',
    '.xml'  => 'application/xml',
    '.pdf'  => 'application/pdf',
    '.zip'  => 'application/zip',
    '.png'  => 'image/png',
    '.jpg'  => 'image/jpeg',
    '.jpeg' => 'image/jpeg',
    '.gif'  => 'image/gif',
    '.svg'  => 'image/svg+xml',
    '.ico'  => 'image/x-icon',
    '.woff' => 'font/woff',
    '.woff2'=> 'font/woff2',
);

sub _mime_type ($path) {
    my ($ext) = $path =~ /(\.[^.]+)$/;
    return $MIME_TYPES{lc($ext // '')} // 'application/octet-stream';
}

async sub send_file ($self, $path, %opts) {
    croak("File not found: $path") unless -f $path;

    # Read file
    open my $fh, '<:raw', $path or croak("Cannot open $path: $!");
    my $content = do { local $/; <$fh> };
    close $fh;

    # Set content-type if not already set
    my $has_ct = grep { lc($_->[0]) eq 'content-type' } @{$self->{_headers}};
    unless ($has_ct) {
        $self->content_type(_mime_type($path));
    }

    # Set content-length
    $self->header('content-length', length($content));

    # Set content-disposition
    my $disposition;
    if ($opts{inline}) {
        $disposition = 'inline';
    } elsif ($opts{filename}) {
        $disposition = "attachment; filename=\"$opts{filename}\"";
    }
    $self->header('content-disposition', $disposition) if $disposition;

    await $self->send($content);
}

1;
