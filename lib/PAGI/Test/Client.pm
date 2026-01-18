package PAGI::Test::Client;

use strict;
use warnings;
use Future::AsyncAwait;
use Carp qw(croak);

use PAGI::Test::Response;


sub new {
    my ($class, %args) = @_;

    # Validate: need either app (direct mode) or base_url/socket (server mode)
    my $has_app = exists $args{app};
    my $has_server = exists $args{base_url} || exists $args{socket};

    croak "Must provide either 'app' (direct mode) or 'base_url'/'socket' (server mode)"
        unless $has_app || $has_server;
    croak "Cannot provide both 'app' and 'base_url'/'socket'"
        if $has_app && $has_server;

    my $self = bless {
        app                  => $args{app},
        base_url             => $args{base_url},
        socket               => $args{socket},
        headers              => $args{headers} // {},
        cookies              => {},
        lifespan             => $args{lifespan} // 0,
        raise_app_exceptions => $args{raise_app_exceptions} // 0,
        started              => 0,
    }, $class;

    # Parse base_url if provided
    if ($self->{base_url}) {
        if ($self->{base_url} =~ m{^(https?)://([^:/]+)(?::(\d+))?(.*)$}) {
            $self->{_scheme} = $1;
            $self->{_host}   = $2;
            $self->{_port}   = $3 // ($1 eq 'https' ? 443 : 80);
            $self->{_path_prefix} = $4 || '';
        } else {
            croak "Invalid base_url: $self->{base_url}";
        }
    }

    return $self;
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
        _set_header(\$opts{headers}, 'Content-Type', 'application/json', 0);
        _set_header(\$opts{headers}, 'Content-Length', length($opts{body}), 1);
    }
    # Handle form option (supports multi-value)
    elsif (exists $opts{form}) {
        my $pairs = _normalize_pairs($opts{form});
        my @encoded;
        for my $pair (@$pairs) {
            my $key = _url_encode($pair->[0]);
            my $val = _url_encode($pair->[1] // '');
            push @encoded, "$key=$val";
        }
        $opts{body} = join('&', @encoded);
        _set_header(\$opts{headers}, 'Content-Type', 'application/x-www-form-urlencoded', 0);
        _set_header(\$opts{headers}, 'Content-Length', length($opts{body}), 1);
    }
    # Add Content-Length for raw body if not already set
    elsif (defined $opts{body}) {
        _set_header(\$opts{headers}, 'Content-Length', length($opts{body}), 0);
    }

    # Dispatch to server mode if configured
    return $self->_server_request($method, $path, \%opts)
        if $self->{base_url} || $self->{socket};

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

    # Call app (with exception handling like real server)
    my $exception;
    eval {
        $self->{app}->($scope, $receive, $send)->get;
    };
    if ($@) {
        $exception = $@;
        if ($self->{raise_app_exceptions}) {
            die $exception;
        }
        # Mimic server behavior: return 500 response
        return PAGI::Test::Response->new(
            status    => 500,
            headers   => [['content-type', 'text/plain']],
            body      => 'Internal Server Error',
            exception => $exception,
        );
    }

    # Check for incomplete response (common async mistake)
    my $has_response_start = grep { $_->{type} eq 'http.response.start' } @events;
    unless ($has_response_start) {
        die "App returned without sending response. "
          . "Did you forget to 'await' your \$send calls? "
          . "See PAGI::Tutorial section on async patterns.\n";
    }

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

    # Add query params if provided (appended to path query string)
    if ($opts->{query}) {
        my $pairs = _normalize_pairs($opts->{query});
        my @encoded;
        for my $pair (@$pairs) {
            my $key = _url_encode($pair->[0]);
            my $val = _url_encode($pair->[1] // '');
            push @encoded, "$key=$val";
        }
        my $new_params = join('&', @encoded);
        $query_string = $query_string ? "$query_string&$new_params" : $new_params;
    }

    # Build headers using helper
    my $headers = $self->_build_headers($opts->{headers});

    my $scope = {
        type         => 'http',
        pagi         => { version => '0.2', spec_version => '0.2' },
        http_version => '1.1',
        method       => $method,
        scheme       => 'http',
        path         => $path,
        query_string => $query_string,
        root_path    => '',
        headers      => $headers,
        client       => ['127.0.0.1', 12345],
        server       => ['testserver', 80],
    };

    # Add state if lifespan is enabled
    $scope->{state} = $self->{state} if $self->{state};

    return $scope;
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

# Server mode: make real HTTP request over TCP or Unix socket
sub _server_request {
    my ($self, $method, $path, $opts) = @_;

    # Build full path with prefix and query string
    my $full_path = ($self->{_path_prefix} // '') . $path;

    # Handle query params
    my $query_string = '';
    if ($full_path =~ s/\?(.*)$//) {
        $query_string = $1;
    }
    if ($opts->{query}) {
        my $pairs = _normalize_pairs($opts->{query});
        my @encoded;
        for my $pair (@$pairs) {
            my $key = _url_encode($pair->[0]);
            my $val = _url_encode($pair->[1] // '');
            push @encoded, "$key=$val";
        }
        my $new_params = join('&', @encoded);
        $query_string = $query_string ? "$query_string&$new_params" : $new_params;
    }
    $full_path .= "?$query_string" if $query_string;

    # Build headers
    my @headers;
    my $host = $self->{_host} // 'localhost';

    # Add Host header
    push @headers, "Host: $host";

    # Add default headers
    my $default_pairs = _normalize_pairs($self->{headers});
    my $request_pairs = _normalize_pairs($opts->{headers});
    my %replace_keys = map { lc($_->[0]) => 1 } @$request_pairs;

    for my $pair (@$default_pairs) {
        push @headers, "$pair->[0]: $pair->[1]"
            unless $replace_keys{lc($pair->[0])};
    }
    for my $pair (@$request_pairs) {
        push @headers, "$pair->[0]: $pair->[1]";
    }

    # Add cookies
    if (keys %{$self->{cookies}}) {
        my $cookie = join('; ', map { "$_=$self->{cookies}{$_}" } sort keys %{$self->{cookies}});
        push @headers, "Cookie: $cookie";
    }

    # Add Content-Length if body present
    my $body = $opts->{body} // '';
    push @headers, "Content-Length: " . length($body) if length($body);

    # Build HTTP request
    my $request = "$method $full_path HTTP/1.1\r\n";
    $request .= join("\r\n", @headers) . "\r\n" if @headers;
    $request .= "\r\n";
    $request .= $body;

    # Connect and send
    my $sock = $self->_connect_socket;
    print $sock $request;

    # Read response
    my $response = $self->_read_http_response($sock);
    close $sock;

    return $response;
}

sub _connect_socket {
    my ($self) = @_;

    if ($self->{socket}) {
        require IO::Socket::UNIX;
        my $sock = IO::Socket::UNIX->new(
            Peer => $self->{socket},
            Type => IO::Socket::UNIX::SOCK_STREAM(),
        ) or croak "Cannot connect to Unix socket $self->{socket}: $!";
        return $sock;
    }
    else {
        require IO::Socket::INET;
        my $sock = IO::Socket::INET->new(
            PeerAddr => $self->{_host},
            PeerPort => $self->{_port},
            Proto    => 'tcp',
        ) or croak "Cannot connect to $self->{_host}:$self->{_port}: $!";
        return $sock;
    }
}

sub _read_http_response {
    my ($self, $sock) = @_;

    # Read status line
    my $status_line = <$sock>;
    croak "No response from server" unless defined $status_line;
    $status_line =~ s/\r?\n$//;

    my ($version, $status, $reason) = split(' ', $status_line, 3);
    $status //= 500;

    # Read headers
    my @headers;
    my %header_lc;
    while (my $line = <$sock>) {
        $line =~ s/\r?\n$//;
        last if $line eq '';

        if ($line =~ /^([^:]+):\s*(.*)$/) {
            my ($name, $value) = ($1, $2);
            push @headers, [lc($name), $value];
            $header_lc{lc($name)} = $value;
        }
    }

    # Read body based on Content-Length or chunked
    my $body = '';
    my $content_length = $header_lc{'content-length'};
    my $transfer_encoding = $header_lc{'transfer-encoding'} // '';

    if ($transfer_encoding =~ /chunked/i) {
        # Chunked transfer encoding
        while (1) {
            my $chunk_header = <$sock>;
            last unless defined $chunk_header;
            $chunk_header =~ s/\r?\n$//;
            my $chunk_size = hex($chunk_header);
            last if $chunk_size == 0;

            my $chunk = '';
            while (length($chunk) < $chunk_size) {
                my $remaining = $chunk_size - length($chunk);
                my $bytes_read = read($sock, my $buf, $remaining);
                last unless $bytes_read;
                $chunk .= $buf;
            }
            $body .= $chunk;
            <$sock>;  # Read trailing \r\n
        }
        <$sock>;  # Read final \r\n after 0-length chunk
    }
    elsif (defined $content_length && $content_length > 0) {
        while (length($body) < $content_length) {
            my $remaining = $content_length - length($body);
            my $bytes_read = read($sock, my $buf, $remaining);
            last unless $bytes_read;
            $body .= $buf;
        }
    }

    # Extract Set-Cookie headers and store cookies
    for my $h (@headers) {
        if ($h->[0] eq 'set-cookie') {
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

sub websocket {
    my ($self, $path, @rest) = @_;

    require PAGI::Test::WebSocket;

    # Handle both: websocket($path, $callback) and websocket($path, %opts)
    # and websocket($path, %opts, $callback)
    my ($callback, %opts);
    if (@rest == 1 && ref($rest[0]) eq 'CODE') {
        $callback = $rest[0];
    } elsif (@rest % 2 == 0) {
        %opts = @rest;
    } elsif (@rest % 2 == 1 && ref($rest[-1]) eq 'CODE') {
        $callback = pop @rest;
        %opts = @rest;
    }

    $path //= '/';

    # Parse query string from path
    my $query_string = '';
    if ($path =~ s/\?(.*)$//) {
        $query_string = $1;
    }

    # Build headers
    my @headers = (['host', 'testserver']);

    # Add client default headers (normalized)
    my $default_pairs = _normalize_pairs($self->{headers});
    for my $pair (@$default_pairs) {
        push @headers, [lc($pair->[0]), $pair->[1]];
    }

    # Add request-specific headers (normalized, replace by key)
    if ($opts{headers}) {
        my $request_pairs = _normalize_pairs($opts{headers});
        my %replace_keys = map { lc($_->[0]) => 1 } @$request_pairs;

        # Filter out replaced headers from existing
        @headers = grep { !$replace_keys{$_->[0]} } @headers;

        # Add request headers
        for my $pair (@$request_pairs) {
            push @headers, [lc($pair->[0]), $pair->[1]];
        }
    }

    # Add cookies
    if (keys %{$self->{cookies}}) {
        my $cookie = join('; ', map { "$_=$self->{cookies}{$_}" } sort keys %{$self->{cookies}});
        push @headers, ['cookie', $cookie];
    }

    my $scope = {
        type         => 'websocket',
        pagi         => { version => '0.2', spec_version => '0.2' },
        http_version => '1.1',
        scheme       => 'ws',
        path         => $path,
        query_string => $query_string,
        root_path    => '',
        headers      => \@headers,
        client       => ['127.0.0.1', 12345],
        server       => ['testserver', 80],
        subprotocols => $opts{subprotocols} // [],
    };

    $scope->{state} = $self->{state} if $self->{state};

    my $ws = PAGI::Test::WebSocket->new(app => $self->{app}, scope => $scope);
    $ws->_start;

    if ($callback) {
        eval { $callback->($ws) };
        my $err = $@;
        $ws->close unless $ws->is_closed;
        die $err if $err;
        return;
    }

    return $ws;
}

sub sse {
    my ($self, $path, @rest) = @_;

    require PAGI::Test::SSE;

    # Handle both: sse($path, $callback) and sse($path, %opts)
    # and sse($path, %opts, $callback)
    my ($callback, %opts);
    if (@rest == 1 && ref($rest[0]) eq 'CODE') {
        $callback = $rest[0];
    } elsif (@rest % 2 == 0) {
        %opts = @rest;
    } elsif (@rest % 2 == 1 && ref($rest[-1]) eq 'CODE') {
        $callback = pop @rest;
        %opts = @rest;
    }

    $path //= '/';

    # Parse query string from path
    my $query_string = '';
    if ($path =~ s/\?(.*)$//) {
        $query_string = $1;
    }

    # Build headers (SSE requires Accept: text/event-stream)
    my @headers = (
        ['host', 'testserver'],
        ['accept', 'text/event-stream'],
    );

    # Add client default headers (normalized)
    my $default_pairs = _normalize_pairs($self->{headers});
    for my $pair (@$default_pairs) {
        push @headers, [lc($pair->[0]), $pair->[1]];
    }

    # Add request-specific headers (normalized, replace by key)
    if ($opts{headers}) {
        my $request_pairs = _normalize_pairs($opts{headers});
        my %replace_keys = map { lc($_->[0]) => 1 } @$request_pairs;

        # Filter out replaced headers from existing
        @headers = grep { !$replace_keys{$_->[0]} } @headers;

        # Add request headers
        for my $pair (@$request_pairs) {
            push @headers, [lc($pair->[0]), $pair->[1]];
        }
    }

    # Add cookies
    if (keys %{$self->{cookies}}) {
        my $cookie = join('; ', map { "$_=$self->{cookies}{$_}" } sort keys %{$self->{cookies}});
        push @headers, ['cookie', $cookie];
    }

    # SSE supports all HTTP methods (GET is default, but POST/PUT work with
    # modern libraries like fetch-event-source used by htmx4, datastar, etc.)
    my $method = uc($opts{method} // 'GET');

    my $scope = {
        type         => 'sse',
        pagi         => { version => '0.2', spec_version => '0.2' },
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

    $scope->{state} = $self->{state} if $self->{state};

    my $sse = PAGI::Test::SSE->new(app => $self->{app}, scope => $scope);
    $sse->_start;

    if ($callback) {
        eval { $callback->($sse) };
        my $err = $@;
        $sse->close unless $sse->is_closed;
        die $err if $err;
        return;
    }

    return $sse;
}

sub start {
    my ($self) = @_;
    return $self if $self->{started};
    return $self unless $self->{lifespan};

    $self->{state} = {};

    my $scope = {
        type          => 'lifespan',
        pagi          => { version => '0.2', spec_version => '0.2' },
        state  => $self->{state},
    };

    my $phase = 'startup';
    my $pending_future;

    my $receive = async sub {
        if ($phase eq 'startup') {
            $phase = 'running';
            return { type => 'lifespan.startup' };
        }
        # Wait for shutdown
        $pending_future = Future->new;
        return await $pending_future;
    };

    my $startup_complete = 0;
    my $send = async sub {
        my ($event) = @_;
        if ($event->{type} eq 'lifespan.startup.complete') {
            $startup_complete = 1;
        }
        elsif ($event->{type} eq 'lifespan.shutdown.complete') {
            # Done
        }
    };

    $self->{lifespan_pending} = \$pending_future;
    $self->{lifespan_future} = $self->{app}->($scope, $receive, $send);

    # Pump until startup complete
    my $deadline = time + 5;
    while (!$startup_complete && time < $deadline) {
        # Just yield - the async code runs synchronously in our setup
    }

    $self->{started} = 1;
    return $self;
}

sub stop {
    my ($self) = @_;
    return $self unless $self->{started};
    return $self unless $self->{lifespan};

    # Resolve the pending future with shutdown event
    if ($self->{lifespan_pending} && ${$self->{lifespan_pending}}) {
        ${$self->{lifespan_pending}}->done({ type => 'lifespan.shutdown' });
    }

    $self->{started} = 0;
    return $self;
}

sub state { shift->{state} // {} }

sub run {
    my ($class, $app, $callback) = @_;

    my $client = $class->new(app => $app, lifespan => 1);
    $client->start;

    eval { $callback->($client) };
    my $err = $@;

    $client->stop;
    die $err if $err;
}

sub _url_encode {
    my ($str) = @_;
    $str =~ s/([^A-Za-z0-9_\-.])/sprintf("%%%02X", ord($1))/eg;
    return $str;
}

# Normalize various input formats to arrayref of [key, value] pairs.
# Supports:
#   - Hash with scalar values: { key => 'value' }
# Set a header on a headers structure (hashref or arrayref of pairs).
# If $replace is true, replaces existing value. Otherwise only sets if not present.
sub _set_header {
    my ($headers_ref, $name, $value, $replace) = @_;
    $replace //= 0;

    if (!defined $$headers_ref) {
        $$headers_ref = { $name => $value };
        return;
    }

    if (ref($$headers_ref) eq 'HASH') {
        if ($replace) {
            $$headers_ref->{$name} = $value;
        } else {
            $$headers_ref->{$name} //= $value;
        }
    } elsif (ref($$headers_ref) eq 'ARRAY') {
        # Check if header already exists (case-insensitive)
        my $found_idx;
        for my $i (0 .. $#{$$headers_ref}) {
            if (lc($$headers_ref->[$i][0]) eq lc($name)) {
                $found_idx = $i;
                last;
            }
        }
        if (defined $found_idx) {
            $$headers_ref->[$found_idx][1] = $value if $replace;
        } else {
            push @{$$headers_ref}, [$name, $value];
        }
    }
}

#   - Hash with arrayref values: { key => ['v1', 'v2'] }
#   - Arrayref of pairs: [['key', 'v1'], ['key', 'v2']]
# Returns arrayref of [key, value] pairs.
sub _normalize_pairs {
    my ($input) = @_;
    return [] unless defined $input;

    # Arrayref of pairs: [['key', 'val'], ['key', 'val2']]
    if (ref($input) eq 'ARRAY') {
        # Validate it looks like pairs
        for my $pair (@$input) {
            croak "Expected arrayref of [key, value] pairs"
                unless ref($pair) eq 'ARRAY' && @$pair == 2;
        }
        return $input;
    }

    # Hash (with scalar or arrayref values)
    if (ref($input) eq 'HASH') {
        my @pairs;
        for my $key (sort keys %$input) {
            my $val = $input->{$key};
            if (ref($val) eq 'ARRAY') {
                # Multiple values for this key
                push @pairs, [$key, $_] for @$val;
            } else {
                # Single value
                push @pairs, [$key, $val // ''];
            }
        }
        return \@pairs;
    }

    croak "Expected hashref or arrayref of pairs, got " . ref($input);
}

# Build headers array, merging defaults with request-specific headers.
# Request headers replace client defaults by key (case-insensitive).
sub _build_headers {
    my ($self, $request_headers) = @_;

    my @headers;

    # Default headers
    push @headers, ['host', 'testserver'];

    # Normalize client default headers
    my $default_pairs = _normalize_pairs($self->{headers});

    # Normalize request-specific headers
    my $request_pairs = _normalize_pairs($request_headers);

    # Build set of keys to replace (lowercase)
    my %replace_keys;
    for my $pair (@$request_pairs) {
        $replace_keys{lc($pair->[0])} = 1;
    }

    # Add client defaults (skip if being replaced)
    for my $pair (@$default_pairs) {
        push @headers, [lc($pair->[0]), $pair->[1]]
            unless $replace_keys{lc($pair->[0])};
    }

    # Add request-specific headers
    for my $pair (@$request_pairs) {
        push @headers, [lc($pair->[0]), $pair->[1]];
    }

    # Add cookies
    if (keys %{$self->{cookies}}) {
        my $cookie = join('; ', map { "$_=$self->{cookies}{$_}" } sort keys %{$self->{cookies}});
        push @headers, ['cookie', $cookie];
    }

    return \@headers;
}

1;

__END__

=head1 NAME

PAGI::Test::Client - Test client for PAGI applications

=head1 SYNOPSIS

    use PAGI::Test::Client;

    # Direct mode: test app without starting a server (fast unit tests)
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

    # Multiple values for same header/query/form field
    my $res = $client->get('/search',
        query   => { tag => ['perl', 'async'] },       # ?tag=perl&tag=async
        headers => { Accept => ['text/html', 'application/json'] },
    );

    # Arrayref of pairs for explicit ordering
    my $res = $client->get('/api',
        headers => [['X-Custom', 'first'], ['X-Custom', 'second']],
    );

    # Multi-value form (checkboxes, multi-select)
    my $res = $client->post('/survey',
        form => { colors => ['red', 'blue', 'green'] },
    );

    # Session cookies persist across requests
    $client->post('/login', form => { user => 'admin', pass => 'secret' });
    my $res = $client->get('/dashboard');  # authenticated!

    # Server mode: connect to a real running server (integration tests)
    my $client = PAGI::Test::Client->new(base_url => 'http://127.0.0.1:5000');
    my $res = $client->get('/api/status');

    # Unix socket mode: connect via Unix domain socket
    my $client = PAGI::Test::Client->new(socket => '/tmp/pagi.sock');
    my $res = $client->get('/api/status');

=head1 DESCRIPTION

PAGI::Test::Client provides two modes of operation:

=head2 Direct Mode (Unit Testing)

When you provide an C<app> coderef, the client invokes your app directly
by constructing PAGI protocol messages ($scope, $receive, $send). This
makes tests fast and simple - no network overhead, no server startup.

=head2 Server Mode (Integration Testing)

When you provide a C<base_url> or C<socket>, the client makes real HTTP
requests over TCP or Unix domain sockets. Use this to test the full stack
including PAGI::Server, or to connect to external services.

This is inspired by Starlette's TestClient but adapted for Perl and PAGI's
specific features like first-class SSE support.

=head1 CONSTRUCTOR

=head2 new

    # Direct mode (unit testing)
    my $client = PAGI::Test::Client->new(
        app      => $app,           # PAGI app coderef
        headers  => { ... },        # Optional: default headers
        lifespan => 1,              # Optional: enable lifespan (default: 0)
    );

    # Server mode via TCP (integration testing)
    my $client = PAGI::Test::Client->new(
        base_url => 'http://127.0.0.1:5000',
        headers  => { ... },        # Optional: default headers
    );

    # Server mode via Unix socket
    my $client = PAGI::Test::Client->new(
        socket  => '/tmp/pagi.sock',
        headers => { ... },         # Optional: default headers
    );

You must provide exactly one of: C<app>, C<base_url>, or C<socket>.

=head3 Options

=over 4

=item app

The PAGI application coderef to test. Use this for direct mode (unit testing).

=item base_url

URL of a running HTTP server to connect to. Use this for server mode
(integration testing) over TCP. Examples:

    base_url => 'http://127.0.0.1:5000'
    base_url => 'http://localhost:8080/api'  # with path prefix

=item socket

Path to a Unix domain socket to connect to. Use this for server mode
when the server is listening on a Unix socket (common for nginx proxying
or benchmark scenarios).

    socket => '/tmp/pagi.sock'
    socket => '/run/myapp/app.sock'

=item headers

Default headers to include in every request. Supports multiple formats:

    # Simple hash (single values)
    headers => { 'X-API-Key' => 'secret' }

    # Hash with arrayref values (multiple values per header)
    headers => { Accept => ['application/json', 'text/html'] }

    # Arrayref of pairs (explicit ordering)
    headers => [['Accept', 'application/json'], ['Accept', 'text/html']]

Request-specific headers with the same name will B<replace> (not append to)
these default headers.

=item lifespan

If true, the client will send lifespan.startup when started and
lifespan.shutdown when stopped. Default is false (most tests don't need it).

=item raise_app_exceptions

Controls how application exceptions are handled. Default is B<false>.

When B<false> (default): Exceptions are trapped and converted to a 500 response,
mimicking how a real server behaves. The exception is available via
C<< $response->exception >>:

    my $res = $client->get('/broken');
    is $res->status, 500;
    like $res->exception, qr/Can't call method/;

When B<true>: Exceptions propagate to the test, useful for debugging:

    my $client = PAGI::Test::Client->new(
        app => $app,
        raise_app_exceptions => 1,
    );
    # This will die with the actual exception
    my $res = $client->get('/broken');

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

=item headers => { ... } or [ [...], [...] ]

Additional headers for this request. Supports multiple formats:

    # Simple hash
    headers => { Authorization => 'Bearer xyz' }

    # Multiple values (arrayref in hash)
    headers => { Accept => ['application/json', 'text/html'] }

    # Arrayref of pairs (preserves order)
    headers => [['X-Custom', 'first'], ['X-Custom', 'second']]

Request headers with the same name as client default headers will B<replace>
the defaults (not append).

=item query => { ... } or [ [...], [...] ]

Query string parameters. Supports multiple formats:

    # Simple hash
    query => { q => 'perl' }

    # Multiple values
    query => { tag => ['perl', 'async'] }  # ?tag=perl&tag=async

    # Arrayref of pairs
    query => [['tag', 'perl'], ['tag', 'async']]

B<Note:> Query params are B<appended> to any existing query string in the path.
To avoid duplicates, put all params either in the path or in the query option,
not both with the same key.

=item json => { ... }

JSON request body. Automatically sets Content-Type to application/json.

=item form => { ... } or [ [...], [...] ]

Form-encoded request body. Sets Content-Type to application/x-www-form-urlencoded.
Supports multiple formats:

    # Simple hash
    form => { user => 'admin', pass => 'secret' }

    # Multiple values (checkboxes, multi-select)
    form => { colors => ['red', 'blue', 'green'] }

    # Arrayref of pairs
    form => [['color', 'red'], ['color', 'blue']]

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

    # With options
    my $ws = $client->websocket('/ws',
        headers      => { Authorization => 'Bearer xyz' },
        subprotocols => ['chat', 'json'],
    );

    # Options with callback
    $client->websocket('/ws', headers => { 'X-Token' => 'abc' }, sub {
        my ($ws) = @_;
        # ...
    });

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

    # With headers (e.g., for reconnection)
    my $sse = $client->sse('/events',
        headers => { 'Last-Event-ID' => '42' },
    );

    # Options with callback
    $client->sse('/events', headers => { Authorization => 'Bearer xyz' }, sub {
        my ($sse) = @_;
        # ...
    });

See L<PAGI::Test::SSE> for the SSE connection API.

=head1 LIFESPAN

=head2 start

    $client->start;

Triggers lifespan.startup. Only needed if C<< lifespan => 1 >> was passed
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
