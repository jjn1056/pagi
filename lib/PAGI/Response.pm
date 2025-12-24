package PAGI::Response;

use strict;
use warnings;

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

    # Basic usage in a raw PAGI app
    async sub app ($scope, $receive, $send) {
        my $res = PAGI::Response->new($send);

        # Fluent chaining - set status, headers, then send
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

    # Streaming large responses
    await $res->stream(async sub ($writer) {
        await $writer->write("chunk1");
        await $writer->write("chunk2");
        await $writer->close();
    });

    # File downloads
    await $res->send_file('/path/to/file.pdf', filename => 'doc.pdf');

=head1 DESCRIPTION

PAGI::Response provides a fluent interface for building HTTP responses in
raw PAGI applications. It wraps the low-level C<$send> callback and provides
convenient methods for common response types.

B<Chainable methods> (C<status>, C<header>, C<content_type>, C<cookie>)
return C<$self> for fluent chaining.

B<Finisher methods> (C<text>, C<html>, C<json>, C<redirect>, etc.) return
Futures and actually send the response. Once a finisher is called, the
response is sent and cannot be modified.

B<Important:> Each PAGI::Response instance can only send one response.
Attempting to call a finisher method twice will throw an error.

=head1 CONSTRUCTOR

=head2 new

    my $res = PAGI::Response->new($send);
    my $res = PAGI::Response->new($send, $scope);

Creates a new response builder. The C<$send> parameter must be a coderef
(the PAGI send callback). The optional C<$scope> parameter is the PAGI
scope hashref, needed for route parameter access.

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

=head2 path_param

    my $id = $res->path_param('id');

Returns a path parameter by name. Path parameters are captured from the URL
path by a router and stored in C<< $scope->{path_params} >>. Returns C<undef>
if the parameter is not found or if no scope was provided.

=head2 path_params

    my $params = $res->path_params;

Returns hashref of all path parameters from scope. Returns an empty hashref
if no path parameters exist or if no scope was provided.

=head2 stash

    my $user = $res->stash->{user};

Returns the per-request stash hashref. This is the same stash accessible via
C<< $req->stash >>, C<< $ws->stash >>, and C<< $sse->stash >> - it lives in
C<< $scope->{'pagi.stash'} >> and is shared across all objects in the request
chain.

This allows handlers to read values set by middleware:

    async sub handler {
        my ($self, $req, $res) = @_;
        my $user = $res->stash->{user};  # Set by auth middleware
        await $res->json({ greeting => "Hello, $user->{name}" });
    }

See L<PAGI::Request/stash> for detailed documentation on how stash works.

=head2 cors

    # Allow all origins (simplest case)
    $res->cors->json({ data => 'value' });

    # Allow specific origin
    $res->cors(origin => 'https://example.com')->json($data);

    # Full configuration
    $res->cors(
        origin      => 'https://example.com',
        methods     => [qw(GET POST PUT DELETE)],
        headers     => [qw(Content-Type Authorization)],
        expose      => [qw(X-Request-Id X-RateLimit-Remaining)],
        credentials => 1,
        max_age     => 86400,
        preflight   => 0,
    )->json($data);

Add CORS (Cross-Origin Resource Sharing) headers to the response.
Returns C<$self> for chaining.

B<Options:>

=over 4

=item * C<origin> - Allowed origin. Default: C<'*'> (all origins).
Can be a specific origin like C<'https://example.com'> or C<'*'> for any.

=item * C<methods> - Arrayref of allowed HTTP methods for preflight.
Default: C<[qw(GET POST PUT DELETE PATCH OPTIONS)]>.

=item * C<headers> - Arrayref of allowed request headers for preflight.
Default: C<[qw(Content-Type Authorization X-Requested-With)]>.

=item * C<expose> - Arrayref of response headers to expose to the client.
By default, only simple headers (Cache-Control, Content-Language, etc.)
are accessible. Use this to expose custom headers.

=item * C<credentials> - Boolean. If true, sets
C<Access-Control-Allow-Credentials: true>, allowing cookies and
Authorization headers. Default: C<0>.

=item * C<max_age> - How long (in seconds) browsers should cache preflight
results. Default: C<86400> (24 hours).

=item * C<preflight> - Boolean. If true, includes preflight response headers
(Allow-Methods, Allow-Headers, Max-Age). Set this when handling OPTIONS
requests. Default: C<0>.

=item * C<request_origin> - The Origin header value from the request.
Required when C<credentials> is true and C<origin> is C<'*'>, because
the CORS spec forbids using C<'*'> with credentials. Pass the actual
request origin to echo it back.

=back

B<Important CORS Notes:>

=over 4

=item * When C<credentials> is true, you cannot use C<origin => '*'>.
Either specify an exact origin, or pass C<request_origin> with the
client's actual Origin header.

=item * The C<Vary: Origin> header is always set to ensure proper caching
when origin-specific responses are used.

=item * For preflight (OPTIONS) requests, set C<preflight => 1> and
typically respond with C<< $res->status(204)->empty() >>.

=back

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

    # Partial file (for range requests)
    await $res->send_file('/path/to/video.mp4',
        offset => 1024,       # Start from byte 1024
        length => 65536,      # Send 64KB
    );

Send a file as the response. This method uses the PAGI protocol's C<file>
key, enabling efficient server-side streaming via C<sendfile()> or similar
zero-copy mechanisms. The file is B<not> read into memory.

B<Options:>

=over 4

=item * C<filename> - Set Content-Disposition attachment filename

=item * C<inline> - Use Content-Disposition: inline instead of attachment

=item * C<offset> - Start position in bytes (default: 0). For range requests.

=item * C<length> - Number of bytes to send. Defaults to file size minus offset.

=back

B<Range Request Example:>

    # Manual range request handling
    async sub handle_video ($req, $send) {
        my $res = PAGI::Response->new($send);
        my $path = '/videos/movie.mp4';
        my $size = -s $path;

        my $range = $req->header('Range');
        if ($range && $range =~ /bytes=(\d+)-(\d*)/) {
            my $start = $1;
            my $end = $2 || ($size - 1);
            my $length = $end - $start + 1;

            return await $res->status(206)
                ->header('Content-Range' => "bytes $start-$end/$size")
                ->header('Accept-Ranges' => 'bytes')
                ->send_file($path, offset => $start, length => $length);
        }

        return await $res->header('Accept-Ranges' => 'bytes')
                         ->send_file($path);
    }

B<Note:> For production file serving with full features (ETag caching,
automatic range request handling, conditional GETs, directory indexes),
use L<PAGI::App::File> instead:

    use PAGI::App::File;
    my $files = PAGI::App::File->new(root => '/var/www/static');
    my $app = $files->to_app;

=head1 EXAMPLES

=head2 Complete Raw PAGI Application

    use Future::AsyncAwait;
    use PAGI::Request;
    use PAGI::Response;

    my $app = async sub ($scope, $receive, $send) {
        return await handle_lifespan($scope, $receive, $send)
            if $scope->{type} eq 'lifespan';

        my $req = PAGI::Request->new($scope, $receive);
        my $res = PAGI::Response->new($send);

        if ($req->method eq 'GET' && $req->path eq '/') {
            return await $res->html('<h1>Welcome</h1>');
        }

        if ($req->method eq 'POST' && $req->path eq '/api/users') {
            my $data = await $req->json;
            # ... create user ...
            return await $res->status(201)
                             ->header('Location' => '/api/users/123')
                             ->json({ id => 123, name => $data->{name} });
        }

        return await $res->status(404)->json({ error => 'Not Found' });
    };

=head2 Form Validation with Error Response

    async sub handle_contact ($req, $send) {
        my $res = PAGI::Response->new($send);
        my $form = await $req->form;

        my @errors;
        my $email = $form->get('email') // '';
        my $message = $form->get('message') // '';

        push @errors, 'Email required' unless $email;
        push @errors, 'Invalid email' unless $email =~ /@/;
        push @errors, 'Message required' unless $message;

        if (@errors) {
            return await $res->error(422, 'Validation failed', {
                errors => \@errors
            });
        }

        # Process valid form...
        return await $res->json({ success => 1 });
    }

=head2 Authentication with Cookies

    async sub handle_login ($req, $send) {
        my $res = PAGI::Response->new($send);
        my $data = await $req->json;

        my $user = authenticate($data->{email}, $data->{password});

        unless ($user) {
            return await $res->error(401, 'Invalid credentials');
        }

        my $session_id = create_session($user);

        return await $res->cookie('session' => $session_id,
                path     => '/',
                httponly => 1,
                secure   => 1,
                samesite => 'Strict',
                max_age  => 86400,  # 24 hours
            )
            ->json({ user => { id => $user->{id}, name => $user->{name} } });
    }

    async sub handle_logout ($req, $send) {
        my $res = PAGI::Response->new($send);

        return await $res->delete_cookie('session', path => '/')
                         ->json({ logged_out => 1 });
    }

=head2 File Download

    async sub handle_download ($req, $send) {
        my $res = PAGI::Response->new($send);
        my $file_id = $req->path_param('id');

        my $file = get_file($file_id); # Be sure to clean $file
        unless ($file && -f $file->{path}) {
            return await $res->error(404, 'File not found');
        }

        return await $res->send_file($file->{path},
            filename => $file->{original_name},
        );
    }

=head2 Streaming Large Data

    async sub handle_export ($req, $send) {
        my $res = PAGI::Response->new($send);

        await $res->content_type('text/csv')
                  ->header('Content-Disposition' => 'attachment; filename="export.csv"')
                  ->stream(async sub ($writer) {
                      # Write CSV header
                      await $writer->write("id,name,email\n");

                      # Stream rows from database
                      my $cursor = get_all_users_cursor();
                      while (my $user = $cursor->next) {
                          await $writer->write("$user->{id},$user->{name},$user->{email}\n");
                      }
                  });
    }

=head2 Server-Sent Events Style Streaming

    async sub handle_events ($req, $send) {
        my $res = PAGI::Response->new($send);

        await $res->content_type('text/event-stream')
                  ->header('Cache-Control' => 'no-cache')
                  ->stream(async sub ($writer) {
                      for my $i (1..10) {
                          await $writer->write("data: Event $i\n\n");
                          await some_delay(1);  # Wait 1 second
                      }
                  });
    }

=head2 Conditional Responses

    async sub handle_resource ($req, $send) {
        my $res = PAGI::Response->new($send);
        my $etag = '"abc123"';

        # Check If-None-Match for caching
        my $if_none_match = $req->header('If-None-Match') // '';
        if ($if_none_match eq $etag) {
            return await $res->status(304)->empty();
        }

        return await $res->header('ETag' => $etag)
                         ->header('Cache-Control' => 'max-age=3600')
                         ->json({ data => 'expensive computation result' });
    }

=head2 CORS API Endpoint

    # Simple CORS - allow all origins
    async sub handle_api ($scope, $receive, $send) {
        my $res = PAGI::Response->new($send);

        return await $res->cors->json({ status => 'ok' });
    }

    # CORS with credentials (e.g., cookies, auth headers)
    async sub handle_api_with_auth ($scope, $receive, $send) {
        my $req = PAGI::Request->new($scope, $receive);
        my $res = PAGI::Response->new($send);

        # Get the Origin header from request
        my $origin = $req->header('Origin');

        return await $res->cors(
            origin         => 'https://myapp.com',  # Or use request_origin
            credentials    => 1,
            expose         => [qw(X-Request-Id)],
        )->json({ user => 'authenticated' });
    }

=head2 CORS Preflight Handler

    # Handle OPTIONS preflight requests
    async sub app ($scope, $receive, $send) {
        my $req = PAGI::Request->new($scope, $receive);
        my $res = PAGI::Response->new($send);

        # Handle preflight
        if ($req->method eq 'OPTIONS') {
            return await $res->cors(
                origin      => 'https://myapp.com',
                methods     => [qw(GET POST PUT DELETE)],
                headers     => [qw(Content-Type Authorization X-Custom-Header)],
                credentials => 1,
                max_age     => 86400,
                preflight   => 1,  # Include preflight headers
            )->status(204)->empty();
        }

        # Handle actual request
        return await $res->cors(
            origin      => 'https://myapp.com',
            credentials => 1,
        )->json({ data => 'response' });
    }

=head2 Dynamic CORS Origin

    # Allow multiple origins dynamically
    my %ALLOWED_ORIGINS = map { $_ => 1 } qw(
        https://app1.example.com
        https://app2.example.com
        https://localhost:3000
    );

    async sub handle_api ($scope, $receive, $send) {
        my $req = PAGI::Request->new($scope, $receive);
        my $res = PAGI::Response->new($send);

        my $request_origin = $req->header('Origin') // '';

        # Check if origin is allowed
        if ($ALLOWED_ORIGINS{$request_origin}) {
            return await $res->cors(
                origin      => $request_origin,  # Echo back the allowed origin
                credentials => 1,
            )->json({ data => 'allowed' });
        }

        # Origin not allowed - respond without CORS headers
        return await $res->status(403)->json({ error => 'Origin not allowed' });
    }

=head1 WRITER OBJECT

The C<stream()> method passes a writer object to its callback with these methods:

=over 4

=item * C<write($chunk)> - Write a chunk (returns Future)

=item * C<close()> - Close the stream (returns Future)

=item * C<bytes_written()> - Get total bytes written so far

=back

The writer automatically closes when the callback completes, but calling
C<close()> explicitly is recommended for clarity.

=head1 ERROR HANDLING

All finisher methods return Futures. Errors in encoding (e.g., invalid UTF-8
when C<strict> mode would be enabled) will cause the Future to fail.

    use Syntax::Keyword::Try;

    try {
        await $res->json($data);
    }
    catch ($e) {
        warn "Failed to send response: $e";
    }

=head1 RECIPES

=head2 Background Tasks

Run tasks after the response is sent. There are three patterns depending
on what kind of work you're doing:

=head3 Pattern 1: Fire-and-Forget Async I/O (Non-Blocking)

For async operations (HTTP calls, database queries using async drivers),
call them without C<await> and use C<< ->retain() >> to prevent the
"lost future" warning:

    await $res->json({ status => 'queued' });

    # Fire-and-forget: retain() prevents GC warning
    send_async_email($user)->retain();
    log_to_analytics($event)->retain();

=head3 Pattern 2: Blocking/CPU Work (IO::Async::Function)

For blocking operations (sync libraries, CPU-intensive work), use
L<IO::Async::Function> to run in a subprocess:

    use IO::Async::Function;

    my $worker = IO::Async::Function->new(
        code => sub {
            my ($data) = @_;
            # This runs in a CHILD PROCESS - can block safely
            sleep 5;  # Won't block event loop
            return process($data);
        },
    );
    $res->loop->add($worker);

    await $res->json({ status => 'processing' });

    # Fire-and-forget in subprocess
    my $f = $worker->call(args => [$data]);
    $f->on_done(sub { warn "Done: @_\n" });
    $f->on_fail(sub { warn "Error: @_\n" });
    $f->retain();

=head3 Pattern 3: Quick Sync Work (loop->later)

For very fast sync operations (logging, incrementing counters):

    await $res->json({ status => 'ok' });

    $res->loop->later(sub {
        log_request();  # Must be FAST (<10ms)
    });

B<WARNING:> Any blocking code in C<loop-E<gt>later> blocks the entire
event loop. No other requests can be processed. Use IO::Async::Function
for anything that might take time.

See also: C<examples/background-tasks/app.pl>

=head1 SEE ALSO

L<PAGI>, L<PAGI::Request>, L<PAGI::Server>

=head1 AUTHOR

PAGI Contributors

=cut

sub new {
    my ($class, $send, $scope) = @_;
    croak("send is required") unless $send;
    croak("send must be a coderef") unless ref($send) eq 'CODE';

    my $self = bless {
        send    => $send,
        scope   => $scope,
        _status => 200,
        _headers => [],
        _sent   => 0,
    }, $class;

    return $self;
}

sub loop {
    my ($self) = @_;
    require IO::Async::Loop;
    return IO::Async::Loop->new;
}

sub status {
    my ($self, $code) = @_;
    croak("Status must be a number between 100-599")
        unless defined $code && $code =~ /^\d+$/ && $code >= 100 && $code <= 599;
    $self->{_status} = $code;
    return $self;
}

sub header {
    my ($self, $name, $value) = @_;
    push @{$self->{_headers}}, [$name, $value];
    return $self;
}

sub content_type {
    my ($self, $type) = @_;
    # Remove existing content-type headers
    $self->{_headers} = [grep { lc($_->[0]) ne 'content-type' } @{$self->{_headers}}];
    push @{$self->{_headers}}, ['content-type', $type];
    return $self;
}

# Path parameters - captured from URL path by router
# Stored in scope->{path_params} for router-agnostic access
sub path_params {
    my ($self) = @_;
    return {} unless $self->{scope};
    return $self->{scope}{path_params} // {};
}

sub path_param {
    my ($self, $name) = @_;
    return undef unless $self->{scope};
    my $params = $self->{scope}{path_params} // {};
    return $params->{$name};
}

# Per-request storage - lives in scope, shared across Request/Response/WebSocket/SSE
#
# DESIGN NOTE: Stash is intentionally scope-based, not object-based. When middleware
# creates a shallow copy of scope ({ %$scope, key => val }), the inner 'pagi.stash'
# hashref is preserved by reference. This means:
#   1. All Request/Response objects created from the same scope chain share stash
#   2. Middleware modifications to stash are visible to downstream handlers
#   3. The stash "transcends" the middleware chain via scope, not via object identity
#
# This addresses a potential concern about Request objects being ephemeral - stash
# works correctly because it lives in scope, which IS shared across the chain.
sub stash {
    my ($self) = @_;
    return {} unless $self->{scope};
    return $self->{scope}{'pagi.stash'} //= {};
}

async sub send {
    my ($self, $body) = @_;
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

async sub send_utf8 {
    my ($self, $body, %opts) = @_;
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

async sub text {
    my ($self, $body) = @_;
    $self->content_type('text/plain; charset=utf-8');
    await $self->send_utf8($body);
}

async sub html {
    my ($self, $body) = @_;
    $self->content_type('text/html; charset=utf-8');
    await $self->send_utf8($body);
}

async sub json {
    my ($self, $data) = @_;
    $self->content_type('application/json; charset=utf-8');
    my $body = JSON::MaybeXS->new(utf8 => 1, canonical => 1)->encode($data);
    await $self->send($body);
}

async sub redirect {
    my ($self, $url, $status) = @_;
    $status //= 302;
    $self->{_status} = $status;
    $self->header('location', $url);
    await $self->send('');
}

async sub empty {
    my ($self) = @_;
    # Use 204 if status hasn't been explicitly set to something other than 200
    if ($self->{_status} == 200) {
        $self->{_status} = 204;
    }
    await $self->send(undef);
}

sub cookie {
    my ($self, $name, $value, %opts) = @_;
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

sub delete_cookie {
    my ($self, $name, %opts) = @_;
    return $self->cookie($name, '',
        max_age => 0,
        path    => $opts{path},
        domain  => $opts{domain},
    );
}

sub cors {
    my ($self, %opts) = @_;
    my $origin      = $opts{origin} // '*';
    my $credentials = $opts{credentials} // 0;
    my $methods     = $opts{methods} // [qw(GET POST PUT DELETE PATCH OPTIONS)];
    my $headers     = $opts{headers} // [qw(Content-Type Authorization X-Requested-With)];
    my $expose      = $opts{expose} // [];
    my $max_age     = $opts{max_age} // 86400;
    my $preflight   = $opts{preflight} // 0;

    # Determine the origin to send back
    my $allow_origin;
    if ($origin eq '*' && $credentials) {
        # With credentials, can't use wildcard - use request_origin if provided
        $allow_origin = $opts{request_origin} // '*';
    } else {
        $allow_origin = $origin;
    }

    # Core CORS headers (always set)
    $self->header('Access-Control-Allow-Origin', $allow_origin);
    $self->header('Vary', 'Origin');

    if ($credentials) {
        $self->header('Access-Control-Allow-Credentials', 'true');
    }

    if (@$expose) {
        $self->header('Access-Control-Expose-Headers', join(', ', @$expose));
    }

    # Preflight headers (for OPTIONS responses or when explicitly requested)
    if ($preflight) {
        $self->header('Access-Control-Allow-Methods', join(', ', @$methods));
        $self->header('Access-Control-Allow-Headers', join(', ', @$headers));
        $self->header('Access-Control-Max-Age', $max_age);
    }

    return $self;
}

# Writer class for streaming
package PAGI::Response::Writer {
    use strict;
    use warnings;
    use Future::AsyncAwait;
    use Carp qw(croak);

    sub new {
        my ($class, $send) = @_;
        return bless {
            send => $send,
            bytes_written => 0,
            closed => 0,
        }, $class;
    }

    async sub write {
        my ($self, $chunk) = @_;
        croak("Writer already closed") if $self->{closed};
        $self->{bytes_written} += length($chunk // '');
        await $self->{send}->({
            type => 'http.response.body',
            body => $chunk,
            more => 1,
        });
    }

    async sub close {
        my ($self) = @_;
        return if $self->{closed};
        $self->{closed} = 1;
        await $self->{send}->({
            type => 'http.response.body',
            body => '',
            more => 0,
        });
    }

    sub bytes_written {
        my ($self) = @_;
        return $self->{bytes_written};
    }
}

package PAGI::Response;

async sub stream {
    my ($self, $callback) = @_;
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

async sub error {
    my ($self, $status, $message, $extra) = @_;
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

sub _mime_type {
    my ($path) = @_;
    my ($ext) = $path =~ /(\.[^.]+)$/;
    return $MIME_TYPES{lc($ext // '')} // 'application/octet-stream';
}

async sub send_file {
    my ($self, $path, %opts) = @_;
    croak("File not found: $path") unless -f $path;
    croak("Cannot read file: $path") unless -r $path;

    # Get file size
    my $file_size = -s $path;

    # Handle offset and length for range requests
    my $offset = $opts{offset} // 0;
    my $length = $opts{length};

    # Validate offset
    croak("offset must be non-negative") if $offset < 0;
    croak("offset exceeds file size") if $offset > $file_size;

    # Calculate actual length to send
    my $max_length = $file_size - $offset;
    if (defined $length) {
        croak("length must be non-negative") if $length < 0;
        $length = $max_length if $length > $max_length;
    } else {
        $length = $max_length;
    }

    # Set content-type if not already set
    my $has_ct = grep { lc($_->[0]) eq 'content-type' } @{$self->{_headers}};
    unless ($has_ct) {
        $self->content_type(_mime_type($path));
    }

    # Set content-length based on actual bytes to send
    $self->header('content-length', $length);

    # Set content-disposition
    my $disposition;
    if ($opts{inline}) {
        $disposition = 'inline';
    } elsif ($opts{filename}) {
        # Sanitize filename for header
        my $safe_filename = $opts{filename};
        $safe_filename =~ s/["\r\n]//g;
        $disposition = "attachment; filename=\"$safe_filename\"";
    }
    $self->header('content-disposition', $disposition) if $disposition;

    croak("Response already sent") if $self->{_sent};
    $self->{_sent} = 1;

    # Send response start
    await $self->{send}->({
        type    => 'http.response.start',
        status  => $self->{_status},
        headers => $self->{_headers},
    });

    # Use PAGI file protocol for efficient server-side streaming
    # Server will use sendfile() or similar zero-copy mechanism
    my $body_event = {
        type => 'http.response.body',
        file => $path,
    };

    # Add offset/length only if not reading from start or not full file
    $body_event->{offset} = $offset if $offset > 0;
    $body_event->{length} = $length if $length < $max_length;

    await $self->{send}->($body_event);
}

1;
