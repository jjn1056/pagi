package PAGI::Test::Client;

use strict;
use warnings;
use Future::AsyncAwait;
use Carp qw(croak);

use PAGI::Test::Response;

our $VERSION = '0.01';

sub new {
    my ($class, %args) = @_;

    croak "app is required" unless $args{app};

    return bless {
        app      => $args{app},
        headers  => $args{headers} // {},
        cookies  => {},
        lifespan => $args{lifespan} // 0,
        started  => 0,
    }, $class;
}

sub get     { shift->_request('GET', @_) }
sub head    { shift->_request('HEAD', @_) }
sub delete  { shift->_request('DELETE', @_) }
sub post    { shift->_request('POST', @_) }
sub put     { shift->_request('PUT', @_) }
sub patch   { shift->_request('PATCH', @_) }
sub options { shift->_request('OPTIONS', @_) }

# Cookie management
sub cookies {
    my ($self) = @_;
    return $self->{cookies};
}

sub cookie {
    my ($self, $name) = @_;
    return $self->{cookies}{$name};
}

sub set_cookie {
    my ($self, $name, $value) = @_;
    $self->{cookies}{$name} = $value;
    return $self;
}

sub clear_cookies {
    my ($self) = @_;
    $self->{cookies} = {};
    return $self;
}

sub _request {
    my ($self, $method, $path, %opts) = @_;

    $path //= '/';

    # Handle json option
    if (exists $opts{json}) {
        require JSON::MaybeXS;
        $opts{body} = JSON::MaybeXS::encode_json($opts{json});
        $opts{headers} //= {};
        $opts{headers}{'Content-Type'} //= 'application/json';
        $opts{headers}{'Content-Length'} = length($opts{body});
    }
    # Handle form option
    elsif (exists $opts{form}) {
        my @pairs;
        for my $k (sort keys %{$opts{form}}) {
            my $key = _url_encode($k);
            my $val = _url_encode($opts{form}{$k} // '');
            push @pairs, "$key=$val";
        }
        $opts{body} = join('&', @pairs);
        $opts{headers} //= {};
        $opts{headers}{'Content-Type'} //= 'application/x-www-form-urlencoded';
        $opts{headers}{'Content-Length'} = length($opts{body});
    }
    # Add Content-Length for raw body if not already set
    elsif (defined $opts{body}) {
        $opts{headers} //= {};
        $opts{headers}{'Content-Length'} //= length($opts{body});
    }

    # Build scope
    my $scope = $self->_build_scope($method, $path, \%opts);

    # Build receive (returns request body)
    my $body = $opts{body} // '';
    my $receive_called = 0;
    my $receive = async sub {
        if (!$receive_called) {
            $receive_called = 1;
            return { type => 'http.request', body => $body, more => 0 };
        }
        return { type => 'http.disconnect' };
    };

    # Build send (captures response)
    my @events;
    my $send = async sub {
        my ($event) = @_;
        push @events, $event;
    };

    # Call app
    $self->{app}->($scope, $receive, $send)->get;

    # Parse response from captured events
    return $self->_build_response(\@events);
}

sub _build_scope {
    my ($self, $method, $path, $opts) = @_;

    # Parse query string from path
    my $query_string = '';
    if ($path =~ s/\?(.*)$//) {
        $query_string = $1;
    }

    # Add query params if provided
    if ($opts->{query}) {
        my @pairs;
        for my $k (sort keys %{$opts->{query}}) {
            my $key = _url_encode($k);
            my $val = _url_encode($opts->{query}{$k} // '');
            push @pairs, "$key=$val";
        }
        my $new_params = join('&', @pairs);
        $query_string = $query_string ? "$query_string&$new_params" : $new_params;
    }

    # Build headers
    my @headers;

    # Default headers
    push @headers, ['host', 'testserver'];

    # Merge in default client headers
    for my $name (keys %{$self->{headers}}) {
        push @headers, [lc($name), $self->{headers}{$name}];
    }

    # Merge in request-specific headers
    if ($opts->{headers}) {
        for my $name (keys %{$opts->{headers}}) {
            push @headers, [lc($name), $opts->{headers}{$name}];
        }
    }

    # Add cookies
    if (keys %{$self->{cookies}}) {
        my $cookie = join('; ', map { "$_=$self->{cookies}{$_}" } keys %{$self->{cookies}});
        push @headers, ['cookie', $cookie];
    }

    return {
        type         => 'http',
        pagi         => { version => '0.1', spec_version => '0.1' },
        http_version => '1.1',
        method       => $method,
        scheme       => 'http',
        path         => $path,
        query_string => $query_string,
        root_path    => '',
        headers      => \@headers,
        client       => ['127.0.0.1', 12345],
        server       => ['testserver', 80],
    };
}

sub _build_response {
    my ($self, $events) = @_;

    my $status = 200;
    my @headers;
    my $body = '';

    for my $event (@$events) {
        my $type = $event->{type} // '';

        if ($type eq 'http.response.start') {
            $status = $event->{status} // 200;
            @headers = @{$event->{headers} // []};
        }
        elsif ($type eq 'http.response.body') {
            $body .= $event->{body} // '';
        }
    }

    # Extract Set-Cookie headers and store cookies
    for my $h (@headers) {
        if (lc($h->[0]) eq 'set-cookie') {
            if ($h->[1] =~ /^([^=]+)=([^;]*)/) {
                $self->{cookies}{$1} = $2;
            }
        }
    }

    return PAGI::Test::Response->new(
        status  => $status,
        headers => \@headers,
        body    => $body,
    );
}

sub _url_encode {
    my ($str) = @_;
    $str =~ s/([^A-Za-z0-9_\-.])/sprintf("%%%02X", ord($1))/eg;
    return $str;
}

1;

__END__

=head1 NAME

PAGI::Test::Client - Test client for PAGI applications

=head1 SYNOPSIS

    use PAGI::Test::Client;

    my $client = PAGI::Test::Client->new(app => $app);

    # Simple GET
    my $res = $client->get('/');
    is $res->status, 200;
    is $res->text, 'Hello World';

    # GET with query parameters
    my $res = $client->get('/search', query => { q => 'perl' });

    # POST with JSON body
    my $res = $client->post('/api/users', json => { name => 'John' });

    # POST with form data
    my $res = $client->post('/login', form => { user => 'admin' });

    # Custom headers
    my $res = $client->get('/api', headers => { Authorization => 'Bearer xyz' });

    # Session cookies persist across requests
    $client->post('/login', form => { user => 'admin', pass => 'secret' });
    my $res = $client->get('/dashboard');  # authenticated!

=head1 DESCRIPTION

PAGI::Test::Client allows you to test PAGI applications without starting
a real server. It invokes your app directly by constructing the PAGI
protocol messages ($scope, $receive, $send), making tests fast and simple.

This is inspired by Starlette's TestClient but adapted for Perl and PAGI's
specific features like first-class SSE support.

=head1 CONSTRUCTOR

=head2 new

    my $client = PAGI::Test::Client->new(
        app      => $app,           # Required: PAGI app coderef
        headers  => { ... },        # Optional: default headers
        lifespan => 1,              # Optional: enable lifespan (default: 0)
    );

=head3 Options

=over 4

=item app (required)

The PAGI application coderef to test.

=item headers

Default headers to include in every request. Request-specific headers
override these.

=item lifespan

If true, the client will send lifespan.startup when started and
lifespan.shutdown when stopped. Default is false (most tests don't need it).

=back

=head1 HTTP METHODS

All HTTP methods return a L<PAGI::Test::Response> object.

=head2 get

    my $res = $client->get($path, %options);

=head2 post

    my $res = $client->post($path, %options);

=head2 put

    my $res = $client->put($path, %options);

=head2 patch

    my $res = $client->patch($path, %options);

=head2 delete

    my $res = $client->delete($path, %options);

=head2 head

    my $res = $client->head($path, %options);

=head2 options

    my $res = $client->options($path, %options);

=head3 Request Options

=over 4

=item headers => { ... }

Additional headers for this request.

=item query => { ... }

Query string parameters. Appended to the path.

=item json => { ... }

JSON request body. Automatically sets Content-Type to application/json.

=item form => { ... }

Form-encoded request body. Sets Content-Type to application/x-www-form-urlencoded.

=item body => $bytes

Raw request body bytes.

=back

=head1 SESSION METHODS

=head2 cookies

    my $hashref = $client->cookies;

Returns all current session cookies.

=head2 cookie

    my $value = $client->cookie('session_id');

Returns a specific cookie value.

=head2 set_cookie

    $client->set_cookie('theme', 'dark');

Manually sets a cookie.

=head2 clear_cookies

    $client->clear_cookies;

Clears all session cookies.

=head1 WEBSOCKET

=head2 websocket

    # Callback style (auto-close)
    $client->websocket('/ws', sub {
        my ($ws) = @_;
        $ws->send_text('hello');
        is $ws->receive_text, 'echo: hello';
    });

    # Explicit style
    my $ws = $client->websocket('/ws');
    $ws->send_text('hello');
    is $ws->receive_text, 'echo: hello';
    $ws->close;

See L<PAGI::Test::WebSocket> for the WebSocket connection API.

=head1 SSE (Server-Sent Events)

=head2 sse

    # Callback style (auto-close)
    $client->sse('/events', sub {
        my ($sse) = @_;
        my $event = $sse->receive_event;
        is $event->{data}, 'connected';
    });

    # Explicit style
    my $sse = $client->sse('/events');
    my $event = $sse->receive_event;
    $sse->close;

See L<PAGI::Test::SSE> for the SSE connection API.

=head1 LIFESPAN

=head2 start

    $client->start;

Triggers lifespan.startup. Only needed if C<lifespan => 1> was passed
to the constructor.

=head2 stop

    $client->stop;

Triggers lifespan.shutdown.

=head2 state

    my $state = $client->state;

Returns the shared state hashref from lifespan.

=head2 run

    PAGI::Test::Client->run($app, sub {
        my ($client) = @_;
        # ... tests ...
    });

Class method that creates a client with lifespan enabled, calls start,
runs your callback, then calls stop. Exceptions propagate.

=head1 SEE ALSO

L<PAGI::Test::Response>, L<PAGI::Test::WebSocket>, L<PAGI::Test::SSE>

=cut
