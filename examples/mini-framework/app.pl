use strict;
use warnings;
use Future::AsyncAwait;
use Future::IO;

# ===========================================================================
# Nano -- a web framework built on PAGI, in about fifty lines of plain Perl.
#
# Everything in the `Nano` package below IS the framework: route registration,
# path parameters, async dispatch, and response building. It is a thin layer
# over the only three things a PAGI application is ever handed -- the
# connection `$scope`, and the `$receive` / `$send` coderefs. No magic, no XS,
# nothing tied to a particular event loop, and no syntax newer than Perl 5.18.
#
# Run it (from the PAGI root, with pagi-server from the PAGI-Server dist):
#
#     pagi-server --app examples/mini-framework/app.pl --port 5000
#
#     curl localhost:5000/
#     curl localhost:5000/hello/ada
#     curl localhost:5000/slow/2
# ===========================================================================

package Nano {
    use Scalar::Util qw(blessed);
    use Encode qw(encode);

    sub new {
        my ($class) = @_;
        return bless { routes => [] }, $class;
    }

    # Define get()/post()/put()/patch()/delete() in one shot. Each registers a
    # route, compiling "/users/:id" into a regex that captures the :params.
    for my $http_method (qw(GET POST PUT PATCH DELETE)) {
        no strict 'refs';
        *{ lc $http_method } = sub {
            my ($self, $path, $handler) = @_;
            my @params;
            (my $pattern = $path) =~ s{:(\w+)}{ push @params, $1; '([^/]+)' }ge;
            push @{ $self->{routes} }, {
                method  => $http_method,
                regex   => qr{\A$pattern\z},
                params  => \@params,
                handler => $handler,
            };
            return $self;   # allow chaining
        };
    }

    # Compile the route table into a single PAGI application coderef.
    sub to_app {
        my ($self) = @_;
        return async sub {
            my ($scope, $receive, $send) = @_;
            die "Unsupported scope type: $scope->{type}" if $scope->{type} ne 'http';

            for my $route (@{ $self->{routes} }) {
                next unless $route->{method} eq $scope->{method};
                next unless my @values = $scope->{path} =~ $route->{regex};

                my %params;
                @params{ @{ $route->{params} } } = @values;

                # Handlers may be plain subs (return a string) or async subs
                # (return a Future) -- either way we wait for the result.
                my $reply = $route->{handler}->({ scope => $scope, params => \%params });
                $reply = await $reply if blessed($reply) && $reply->isa('Future');

                return await _reply($send, 200, $reply);
            }

            return await _reply($send, 404, "Not Found\n");
        };
    }

    async sub _reply {
        my ($send, $status, $body) = @_;
        $body = encode('UTF-8', $body);
        await $send->({
            type    => 'http.response.start',
            status  => $status,
            headers => [
                [ 'content-type',   'text/plain; charset=utf-8' ],
                [ 'content-length', length $body ],
            ],
        });
        await $send->({ type => 'http.response.body', body => $body, more => 0 });
    }
}

# ===========================================================================
# An application written against the framework above. A user of Nano never
# touches the PAGI protocol -- they declare routes and return strings.
# ===========================================================================

my $app = Nano->new;

$app->get('/' => sub {
    "Hello from a web framework built on PAGI!\n";
});

$app->get('/hello/:name' => sub {
    my ($req) = @_;
    "Hello, $req->{params}{name}!\n";
});

# An async handler: it can `await` slow work (a database call, an outbound HTTP
# request, a timer) and the server keeps serving everyone else in the meantime.
$app->get('/slow/:secs' => async sub {
    my ($req) = @_;
    await Future::IO->sleep( $req->{params}{secs} );
    "Waited $req->{params}{secs}s without blocking another request.\n";
});

$app->to_app;   # Return the PAGI app coderef (the server loads this file via do)
