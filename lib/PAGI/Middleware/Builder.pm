package PAGI::Middleware::Builder;

use strict;
use warnings;
use Future::AsyncAwait;
use Carp 'croak';

# Note: We use traditional Perl subs because prototypes don't work with signatures.

=head1 NAME

PAGI::Middleware::Builder - DSL for composing PAGI middleware

=head1 SYNOPSIS

    use PAGI::Middleware::Builder;

    # Functional DSL
    my $app = builder {
        enable 'ContentLength';
        enable 'CORS', origins => ['*'];
        enable_if { $_[0]->{path} =~ m{^/api/} } 'RateLimit', limit => 100;
        mount '/static' => $static_app;
        $my_app;
    };

    # Object-oriented interface
    my $builder = PAGI::Middleware::Builder->new;
    $builder->enable('ContentLength');
    $builder->enable('CORS', origins => ['*']);
    $builder->mount('/admin', $admin_app);
    my $app = $builder->to_app($my_app);

=head1 DESCRIPTION

PAGI::Middleware::Builder provides a DSL for composing middleware into
a PAGI application. It supports:

=over 4

=item * Enabling middleware with configuration

=item * Conditional middleware application

=item * Path-based routing (mount)

=item * Middleware ordering

=back

=head1 EXPORTS

=cut

use Exporter 'import';
our @EXPORT = qw(builder enable enable_if mount);

# Current builder context for DSL
our $_current_builder;

=head2 builder

    my $app = builder { ... };

Create a composed application using the DSL. The block should
call enable(), enable_if(), mount(), and return the final app.

=cut

sub builder (&) {
    my ($block) = @_;
    local $_current_builder = PAGI::Middleware::Builder->new;
    my $app = $block->();
    return $_current_builder->to_app($app);
}

=head2 enable

    enable 'MiddlewareName', %config;
    enable 'PAGI::Middleware::Custom', %config;

Enable a middleware. If the name doesn't contain '::', it's prefixed
with 'PAGI::Middleware::'.

=cut

sub enable {
    my ($name, %config) = @_;
    croak "enable() must be called inside builder {}" unless $_current_builder;
    $_current_builder->add_middleware($name, %config);
}

=head2 enable_if

    enable_if { $condition } 'MiddlewareName', %config;

Conditionally enable middleware. The condition block receives
the scope and returns true/false.

=cut

sub enable_if (&$;@) {
    my ($condition, $name, %config) = @_;
    croak "enable_if() must be called inside builder {}" unless $_current_builder;
    $_current_builder->add_middleware_if($condition, $name, %config);
}

=head2 mount

    mount '/path' => $app;

Mount an application at a path prefix. Requests matching the
prefix are routed to the mounted app with adjusted paths.

=cut

sub mount {
    my ($path, $app) = @_;
    croak "mount() must be called inside builder {}" unless $_current_builder;
    $_current_builder->add_mount($path, $app);
}

=head1 METHODS

=head2 new

    my $builder = PAGI::Middleware::Builder->new;

Create a new builder instance.

=cut

sub new {
    my ($class) = @_;
    return bless {
        middleware => [],
        mounts     => [],
    }, $class;
}

=head2 enable

    $builder->enable('MiddlewareName', %config);

Add middleware to the stack (OO interface).

=cut

sub add_middleware {
    my ($self, $name, %config) = @_;
    my $class = $self->_resolve_middleware($name);
    push @{$self->{middleware}}, {
        class     => $class,
        config    => \%config,
        condition => undef,
    };
    return $self;
}

=head2 enable_if

    $builder->enable_if(\&condition, 'MiddlewareName', %config);

Add conditional middleware to the stack (OO interface).

=cut

sub add_middleware_if {
    my ($self, $condition, $name, %config) = @_;
    my $class = $self->_resolve_middleware($name);
    push @{$self->{middleware}}, {
        class     => $class,
        config    => \%config,
        condition => $condition,
    };
    return $self;
}

=head2 mount

    $builder->mount('/path', $app);

Add a path-based mount point (OO interface).

=cut

sub add_mount {
    my ($self, $path, $app) = @_;
    # Normalize path (remove trailing slash, ensure leading slash)
    $path =~ s{/$}{};
    $path = "/$path" unless $path =~ m{^/};

    push @{$self->{mounts}}, {
        path => $path,
        app  => $app,
    };
    return $self;
}

=head2 to_app

    my $app = $builder->to_app($inner_app);

Build the composed application.

=cut

sub to_app {
    my ($self, $app) = @_;

    # Apply mounts first (innermost)
    if (@{$self->{mounts}}) {
        $app = $self->_build_mount_app($app);
    }

    # Apply middleware in reverse order (outermost first in execution)
    for my $mw (reverse @{$self->{middleware}}) {
        $app = $self->_wrap_middleware($mw, $app);
    }

    return $app;
}

# Private: resolve middleware class name
sub _resolve_middleware {
    my ($self, $name) = @_;
    my $class = $name;

    # Prepend PAGI::Middleware:: if no ::
    unless ($class =~ /::/) {
        $class = "PAGI::Middleware::$class";
    }

    # Load the module
    my $file = $class;
    $file =~ s{::}{/}g;
    $file .= '.pm';

    eval { require $file };
    if ($@) {
        # If loading fails, the error will surface when instantiating
        # This allows for forward declarations
        warn "Warning: Could not load $class: $@" if $ENV{PAGI_DEBUG};
    }

    return $class;
}

# Private: wrap a middleware around an app
sub _wrap_middleware {
    my ($self, $mw, $app) = @_;
    my $class     = $mw->{class};
    my $config    = $mw->{config};
    my $condition = $mw->{condition};

    if ($condition) {
        # Conditional middleware
        return async sub {
            my ($scope, $receive, $send) = @_;
            if ($condition->($scope)) {
                my $instance = $class->new(%$config);
                my $wrapped  = $instance->wrap($app);
                await $wrapped->($scope, $receive, $send);
            } else {
                await $app->($scope, $receive, $send);
            }
        };
    } else {
        # Unconditional middleware
        my $instance = $class->new(%$config);
        return $instance->wrap($app);
    }
}

# Private: build mount routing app
sub _build_mount_app {
    my ($self, $fallback_app) = @_;
    my @mounts = sort { length($b->{path}) <=> length($a->{path}) } @{$self->{mounts}};

    return async sub {
        my ($scope, $receive, $send) = @_;
        my $path = $scope->{path};

        for my $mount (@mounts) {
            my $prefix = $mount->{path};

            # Check if path matches mount point
            if ($path eq $prefix || $path =~ m{^\Q$prefix\E/}) {
                # Adjust path and root_path for mounted app
                my $new_path = $path;
                $new_path =~ s{^\Q$prefix\E}{};
                $new_path = '/' if $new_path eq '';

                my $new_root = ($scope->{root_path} // '') . $prefix;

                my $mounted_scope = {
                    %$scope,
                    path      => $new_path,
                    root_path => $new_root,
                };

                await $mount->{app}->($mounted_scope, $receive, $send);
                return;
            }
        }

        # No mount matched, use fallback
        await $fallback_app->($scope, $receive, $send);
    };
}

1;

__END__

=head1 MIDDLEWARE ORDERING

Middleware is applied in the order specified, with the first middleware
being the outermost wrapper. This means:

    builder {
        enable 'A';
        enable 'B';
        enable 'C';
        $app;
    };

Results in: A wraps B wraps C wraps $app

Request flow: A -> B -> C -> app -> C -> B -> A

=head1 SEE ALSO

L<PAGI::Middleware> - Base class for middleware

=cut
