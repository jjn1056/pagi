package PAGI::Context;

use strict;
use warnings;

=head1 NAME

PAGI::Context - Per-request context with protocol-specific subclasses

=head1 SYNOPSIS

    use PAGI::Context;

    # Factory returns the right subclass based on scope type
    my $ctx = PAGI::Context->new($scope, $receive, $send);

    # Shared methods (all protocol types)
    my $type = $ctx->type;        # 'http', 'websocket', 'sse'
    my $path = $ctx->path;
    my $stash = $ctx->stash;      # PAGI::Stash
    my $session = $ctx->session;  # PAGI::Session

    # Protocol-specific (only on the appropriate subclass)
    my $req = $ctx->request;      # HTTP only
    my $res = $ctx->response;     # HTTP only
    my $ws  = $ctx->websocket;    # WebSocket only
    my $sse = $ctx->sse;          # SSE only

=head1 DESCRIPTION

PAGI::Context is a factory and base class that provides a unified entry
point for per-request context. Calling C<< PAGI::Context->new(...) >>
inspects C<< $scope->{type} >> and returns the appropriate subclass:
L<PAGI::Context::HTTP>, L<PAGI::Context::WebSocket>, or
L<PAGI::Context::SSE>.

Shared methods (scope accessors, stash, session, connection state) live
on the base class. Protocol-specific methods (request/response, websocket,
sse) live on subclasses and simply do not exist on other protocol types.

=head1 EXTENSIBILITY

Override C<_type_map> to add or replace protocol types:

    package MyApp::Context;
    our @ISA = ('PAGI::Context');

    sub _type_map {
        my ($class) = @_;
        return {
            %{ $class->SUPER::_type_map },
            grpc => 'MyApp::Context::GRPC',
        };
    }

Override C<_resolve_class> for custom resolution logic beyond the type map.

=head1 CONSTRUCTOR

=head2 new

    my $ctx = PAGI::Context->new($scope, $receive, $send);

Factory constructor. Returns a subclass instance based on
C<< $scope->{type} >>. Defaults to HTTP if type is missing or unknown.

=cut

sub new {
    my ($class, $scope, $receive, $send) = @_;
    my $subclass = $class->_resolve_class($scope);
    return bless {
        scope   => $scope,
        receive => $receive,
        send    => $send,
    }, $subclass;
}

=head1 CLASS METHODS

=head2 _type_map

    my $map = PAGI::Context->_type_map;

Returns a hashref mapping scope type strings to subclass package names.
Override in a subclass to add or replace protocol types.

=cut

sub _type_map {
    return {
        http      => 'PAGI::Context::HTTP',
        websocket => 'PAGI::Context::WebSocket',
        sse       => 'PAGI::Context::SSE',
    };
}

=head2 _resolve_class

    my $class = PAGI::Context->_resolve_class($scope);

Resolves the scope to a subclass package name. Looks up
C<< $scope->{type} >> in C<_type_map>; defaults to the C<http> mapping
if the type is missing or unknown. Override for custom resolution logic.

=cut

sub _resolve_class {
    my ($class, $scope) = @_;
    my $type = $scope->{type} // 'http';
    return $class->_type_map->{$type} // $class->_type_map->{http};
}

=head1 METHODS

=head2 Scope Accessors

    $ctx->scope;          # raw $scope hashref
    $ctx->type;           # $scope->{type}
    $ctx->path;           # $scope->{path}
    $ctx->raw_path;       # $scope->{raw_path} // $scope->{path}
    $ctx->query_string;   # $scope->{query_string} // ''
    $ctx->scheme;         # $scope->{scheme} // 'http'
    $ctx->client;         # $scope->{client}
    $ctx->server;         # $scope->{server}
    $ctx->headers;        # $scope->{headers} arrayref of [name, value]

=cut

sub scope        { shift->{scope} }
sub type         { shift->{scope}{type} }
sub path         { shift->{scope}{path} }
sub raw_path     { my $s = shift; $s->{scope}{raw_path} // $s->{scope}{path} }
sub query_string { shift->{scope}{query_string} // '' }
sub scheme       { shift->{scope}{scheme} // 'http' }
sub client       { shift->{scope}{client} }
sub server       { shift->{scope}{server} }
sub headers      { shift->{scope}{headers} }

=head2 Path Parameters

    my $params = $ctx->path_params;           # hashref
    my $id     = $ctx->path_param('id');      # strict: dies if missing
    my $id     = $ctx->path_param('id', strict => 0);  # returns undef

C<path_params> returns the C<< $scope->{path_params} >> hashref (set by
the router), defaulting to C<{}> if not present.

C<path_param> returns a single parameter by name. By default it dies if
the key is not found (strict mode). Pass C<< strict => 0 >> to return
C<undef> for missing keys instead.

=cut

sub path_params {
    my ($self) = @_;
    return $self->{scope}{path_params} // {};
}

sub path_param {
    my ($self, $name, %opts) = @_;
    my $strict = exists $opts{strict} ? $opts{strict} : 1;
    my $params = $self->path_params;

    if ($strict && !exists $params->{$name}) {
        my @available = sort keys %$params;
        die "path_param '$name' not found. "
            . (@available ? "Available: " . join(', ', @available) : "No path params set")
            . "\n";
    }

    return $params->{$name};
}

=head2 Protocol Introspection

    $ctx->is_http;        # true if type eq 'http'
    $ctx->is_websocket;   # true if type eq 'websocket'
    $ctx->is_sse;         # true if type eq 'sse'

=cut

sub is_http      { (shift->{scope}{type} // '') eq 'http' }
sub is_websocket { (shift->{scope}{type} // '') eq 'websocket' }
sub is_sse       { (shift->{scope}{type} // '') eq 'sse' }

=head2 header

    my $value = $ctx->header('Content-Type');

Returns the last value for the named header (case-insensitive), or
C<undef> if not found.

=cut

sub header {
    my ($self, $name) = @_;
    $name = lc($name);
    my $value;
    for my $pair (@{$self->{scope}{headers} // []}) {
        if (lc($pair->[0]) eq $name) {
            $value = $pair->[1];
        }
    }
    return $value;
}

=head2 receive

    my $receive = $ctx->receive;

Returns the raw C<$receive> coderef. Calling it returns a L<Future> that
resolves to the next protocol event hashref from the client.

    # Read an HTTP request body event
    my $event = await $ctx->receive->();
    # $event = { type => 'http.request', body => '...' }

    # Read a WebSocket message
    my $msg = await $ctx->receive->();
    # $msg = { type => 'websocket.receive', text => 'hello' }

Most users should prefer the protocol helpers (C<< $ctx->request >>,
C<< $ctx->websocket >>, C<< $ctx->sse >>) which handle the event
protocol internally. Use C<receive> only for raw protocol access.

=head2 send

    my $send = $ctx->send;

Returns the raw C<$send> coderef. Calling it with an event hashref
returns a L<Future> that resolves when the event has been sent.

    # Send an HTTP response (two events: start + body)
    await $ctx->send->({ type => 'http.response.start', status => 200,
                         headers => [['content-type', 'text/plain']] });
    await $ctx->send->({ type => 'http.response.body', body => 'Hello' });

    # Accept a WebSocket connection
    await $ctx->send->({ type => 'websocket.accept' });

Most users should prefer the protocol helpers (C<< $ctx->response >>,
C<< $ctx->websocket >>, C<< $ctx->sse >>) which build and send events
for you. Use C<send> only for raw protocol access.

=cut

sub receive { shift->{receive} }
sub send    { shift->{send} }

=head2 stash

    my $stash = $ctx->stash;   # PAGI::Stash instance

Returns a L<PAGI::Stash> wrapping C<< $scope->{'pagi.stash'} >>.
Lazy-constructed and cached.

=head2 session

    my $session = $ctx->session;   # PAGI::Session instance

Returns a L<PAGI::Session> wrapping C<< $scope->{'pagi.session'} >>.
Lazy-constructed and cached. Dies if session middleware has not run.
Use C<has_session> to check availability first.

=head2 has_session

    if ($ctx->has_session) {
        my $user_id = $ctx->session->get('user_id');
    }

Returns true if session middleware has populated C<< $scope->{'pagi.session'} >>.

=head2 state

    my $state = $ctx->state;   # hashref

Returns C<< $scope->{state} >> — the app/endpoint-level shared state.

=cut

sub stash {
    my ($self) = @_;
    return $self->{_stash} //= do {
        require PAGI::Stash;
        PAGI::Stash->new($self->{scope});
    };
}

sub session {
    my ($self) = @_;
    return $self->{_session} //= do {
        require PAGI::Session;
        PAGI::Session->new($self->{scope});
    };
}

sub has_session {
    my ($self) = @_;
    return exists $self->{scope}{'pagi.session'} ? 1 : 0;
}

sub state {
    my ($self) = @_;
    return $self->{scope}{state} // {};
}

=head2 Connection State

    $ctx->connection;           # PAGI::Server::ConnectionState object
    $ctx->is_connected;         # boolean
    $ctx->is_disconnected;      # boolean
    $ctx->disconnect_reason;    # string or undef
    $ctx->on_disconnect($cb);   # register callback

Delegates to C<< $scope->{'pagi.connection'} >>.

=cut

sub connection {
    my ($self) = @_;
    return $self->{scope}{'pagi.connection'};
}

sub is_connected {
    my ($self) = @_;
    my $conn = $self->connection;
    return 0 unless $conn;
    return $conn->is_connected;
}

sub is_disconnected {
    my ($self) = @_;
    return !$self->is_connected;
}

sub disconnect_reason {
    my ($self) = @_;
    my $conn = $self->connection;
    return undef unless $conn;
    return $conn->disconnect_reason;
}

sub on_disconnect {
    my ($self, $cb) = @_;
    my $conn = $self->connection;
    return unless $conn;
    $conn->on_disconnect($cb);
}

# Load subclasses
require PAGI::Context::HTTP;
require PAGI::Context::WebSocket;
require PAGI::Context::SSE;

1;

__END__

=head1 SEE ALSO

L<PAGI::Context::HTTP>, L<PAGI::Context::WebSocket>, L<PAGI::Context::SSE>,
L<PAGI::Stash>, L<PAGI::Session>

=cut
