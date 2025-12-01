package PAGI::Runner;

use strict;
use warnings;
use experimental 'signatures';
use Getopt::Long qw(GetOptionsFromArray :config pass_through no_auto_abbrev);
use Pod::Usage;
use File::Spec;
use IO::Async::Loop;

use PAGI::Server;

our $VERSION = '0.001';

=head1 NAME

PAGI::Runner - PAGI application loader and server runner

=head1 SYNOPSIS

    # Command line usage via pagi-server
    pagi-server PAGI::App::Directory root=/var/www
    pagi-server ./app.pl -p 8080
    pagi-server                        # serves current directory

    # Programmatic usage
    use PAGI::Runner;

    my $runner = PAGI::Runner->new;
    $runner->parse_options(@ARGV);
    $runner->run;

    # Or all-in-one
    PAGI::Runner->new->run(@ARGV);

    # For testing
    my $runner = PAGI::Runner->new(port => 0, quiet => 1);
    $runner->load_app('PAGI::App::Directory', root => '.');
    my $server = $runner->prepare_server;

=head1 DESCRIPTION

PAGI::Runner is a loader and runner for PAGI applications, similar to
L<Plack::Runner> for PSGI. It handles CLI argument parsing, app loading
(from files or modules), and server orchestration.

=head1 APP LOADING

The runner supports three ways to specify an application:

=head2 Module Name

If the app specifier contains C<::>, it's treated as a module name:

    pagi-server PAGI::App::Directory root=/var/www show_hidden=1

The module is loaded, instantiated with the provided key=value arguments,
and C<to_app> is called to get the PAGI app coderef.

=head2 File Path

If the app specifier contains C</> or ends with C<.pl> or C<.psgi>,
it's treated as a file path:

    pagi-server ./app.pl
    pagi-server /path/to/myapp.psgi

The file is loaded via C<do> and must return a coderef.

=head2 Default

If no app is specified, defaults to serving the current directory:

    pagi-server                        # same as: PAGI::App::Directory root=.

=head1 CONSTRUCTOR ARGUMENTS

Arguments after the app specifier are parsed as C<key=value> pairs
and passed to the module constructor:

    pagi-server PAGI::App::Directory root=/var/www show_hidden=1

Becomes:

    PAGI::App::Directory->new(root => '/var/www', show_hidden => 1)->to_app

=head1 METHODS

=head2 new

    my $runner = PAGI::Runner->new(%options);

Creates a new runner instance. Options:

=over 4

=item host => $host

Bind address. Default: '127.0.0.1'

=item port => $port

Bind port. Default: 5000

=item workers => $num

Number of worker processes. Default: 1

=item quiet => $bool

Suppress startup messages. Default: 0

=item loop => $loop_type

Event loop backend (EV, Epoll, UV, Poll). Default: auto-detect

=item ssl_cert => $path

Path to SSL certificate file.

=item ssl_key => $path

Path to SSL private key file.

=item access_log => $path

Path to access log file. Default: STDERR

=back

=cut

sub new ($class, %args) {
    return bless {
        host       => $args{host}       // '127.0.0.1',
        port       => $args{port}       // 5000,
        workers    => $args{workers}    // 1,
        quiet      => $args{quiet}      // 0,
        loop       => $args{loop}       // undef,
        ssl_cert   => $args{ssl_cert}   // undef,
        ssl_key    => $args{ssl_key}    // undef,
        access_log => $args{access_log} // undef,
        app        => undef,
        app_spec   => undef,
        app_args   => {},
    }, $class;
}

=head2 parse_options

    my @remaining = $runner->parse_options(@args);

Parses CLI options from the argument list. Known options are extracted
and stored in the runner object. Returns remaining arguments (app specifier
and constructor args).

Supported options:

    -a, --app       App file path (legacy, for backward compatibility)
    -h, --host      Bind address
    -p, --port      Bind port
    -w, --workers   Number of workers
    -l, --loop      Event loop backend
    --ssl-cert      SSL certificate path
    --ssl-key       SSL key path
    --access-log    Access log path
    -q, --quiet     Suppress output
    --help          Show help

=cut

sub parse_options ($self, @args) {
    my %opts;
    my $help;

    # Use pass_through to leave unknown options for the app
    GetOptionsFromArray(
        \@args,
        'app|a=s'       => \$opts{app},
        'host|h=s'      => \$opts{host},
        'port|p=i'      => \$opts{port},
        'workers|w=i'   => \$opts{workers},
        'loop|l=s'      => \$opts{loop},
        'ssl-cert=s'    => \$opts{ssl_cert},
        'ssl-key=s'     => \$opts{ssl_key},
        'access-log=s'  => \$opts{access_log},
        'quiet|q'       => \$opts{quiet},
        'help'          => \$help,
    ) or die "Error parsing options\n";

    if ($help) {
        $self->{show_help} = 1;
        return @args;
    }

    # Apply parsed options
    $self->{host}       = $opts{host}       if defined $opts{host};
    $self->{port}       = $opts{port}       if defined $opts{port};
    $self->{workers}    = $opts{workers}    if defined $opts{workers};
    $self->{loop}       = $opts{loop}       if defined $opts{loop};
    $self->{ssl_cert}   = $opts{ssl_cert}   if defined $opts{ssl_cert};
    $self->{ssl_key}    = $opts{ssl_key}    if defined $opts{ssl_key};
    $self->{access_log} = $opts{access_log} if defined $opts{access_log};
    $self->{quiet}      = $opts{quiet}      if $opts{quiet};

    # Legacy --app flag takes precedence
    if (defined $opts{app}) {
        $self->{app_spec} = $opts{app};
    }

    return @args;
}

=head2 load_app

    my $app = $runner->load_app();
    my $app = $runner->load_app($app_spec);
    my $app = $runner->load_app($app_spec, %constructor_args);

Loads a PAGI application. If no app_spec is provided and one was set
via C<parse_options>, uses that. If still no app_spec, defaults to
C<PAGI::App::Directory> with C<root> set to current directory.

Returns the loaded app coderef and stores it in the runner.

=cut

sub load_app ($self, $app_spec = undef, %args) {
    # Use provided spec, or fall back to one from parse_options, or default
    $app_spec //= $self->{app_spec};

    # Default: serve current directory
    if (!defined $app_spec) {
        $app_spec = 'PAGI::App::Directory';
        %args = (root => '.') unless %args;
    }

    $self->{app_spec} = $app_spec;
    $self->{app_args} = \%args;

    my $app;
    if ($self->_is_module_name($app_spec)) {
        $app = $self->_load_module($app_spec, %args);
    }
    elsif ($self->_is_file_path($app_spec)) {
        $app = $self->_load_file($app_spec);
    }
    else {
        # Ambiguous - try as file first, then module
        if (-f $app_spec) {
            $app = $self->_load_file($app_spec);
        }
        else {
            $app = $self->_load_module($app_spec, %args);
        }
    }

    $self->{app} = $app;
    return $app;
}

=head2 prepare_server

    my $server = $runner->prepare_server;

Creates and configures a L<PAGI::Server> instance based on the runner's
settings. The app must be loaded first via C<load_app>.

Returns the server instance (not yet started).

=cut

sub prepare_server ($self) {
    die "No app loaded. Call load_app first.\n" unless $self->{app};

    # Validate SSL options
    if ($self->{ssl_cert} || $self->{ssl_key}) {
        die "--ssl-cert and --ssl-key must be specified together\n"
            unless $self->{ssl_cert} && $self->{ssl_key};
        die "SSL cert not found: $self->{ssl_cert}\n" unless -f $self->{ssl_cert};
        die "SSL key not found: $self->{ssl_key}\n" unless -f $self->{ssl_key};
    }

    # Build server options
    my %server_opts = (
        app     => $self->{app},
        host    => $self->{host},
        port    => $self->{port},
        quiet   => $self->{quiet} ? 1 : 0,
        workers => $self->{workers} > 1 ? $self->{workers} : 0,
    );

    # Add SSL config if provided
    if ($self->{ssl_cert} && $self->{ssl_key}) {
        $server_opts{ssl} = {
            cert_file => $self->{ssl_cert},
            key_file  => $self->{ssl_key},
        };
    }

    # Add access log if provided
    if ($self->{access_log}) {
        open my $log_fh, '>>', $self->{access_log}
            or die "Cannot open access log $self->{access_log}: $!\n";
        $server_opts{access_log} = $log_fh;
    }

    return PAGI::Server->new(%server_opts);
}

=head2 run

    $runner->run(@args);

Convenience method that parses options, loads the app, creates the server,
and runs the event loop. This is the main entry point for CLI usage.

=cut

sub run ($self, @args) {
    # Parse CLI options
    @args = $self->parse_options(@args);

    # Handle --help
    if ($self->{show_help}) {
        $self->_show_help;
        return;
    }

    # Process remaining args: first is app spec (if not set via --app),
    # rest are constructor args
    if (@args && !$self->{app_spec}) {
        my $first = $args[0];
        # Check if first arg looks like an app spec (not a key=value)
        if ($first !~ /=/) {
            $self->{app_spec} = shift @args;
        }
    }

    # Parse constructor args (key=value pairs)
    my %app_args = $self->_parse_app_args(@args);

    # Load the app
    $self->load_app($self->{app_spec}, %app_args);

    # Create and configure server
    my $server = $self->prepare_server;

    # Create event loop
    my $loop = $self->_create_loop;

    $loop->add($server);

    # Start listening with proper error handling
    eval {
        $server->listen->get;
    };
    if ($@) {
        my $error = $@;
        if ($error =~ /Cannot bind\(\).*Address already in use/i) {
            die "Error: Port $self->{port} is already in use\n";
        }
        elsif ($error =~ /Cannot bind\(\).*Permission denied/i) {
            die "Error: Permission denied to bind to port $self->{port}\n";
        }
        elsif ($error =~ /Cannot bind\(\)/) {
            $error =~ s/\s+at\s+\S+\s+line\s+\d+.*//s;
            die "Error: $error\n";
        }
        die "Error starting server: $error\n";
    }

    # Run the event loop
    $loop->run;
}

# Internal methods

sub _is_module_name ($self, $spec) {
    return $spec =~ /::/;
}

sub _is_file_path ($self, $spec) {
    return $spec =~ m{/} || $spec =~ /\.(?:pl|psgi)$/i;
}

sub _load_module ($self, $module, %args) {
    # Validate module name (basic security check)
    die "Invalid module name: $module\n" unless $module =~ /^[A-Za-z_][A-Za-z0-9_]*(?:::[A-Za-z_][A-Za-z0-9_]*)*$/;

    # Try to load the module
    my $file = $module;
    $file =~ s{::}{/}g;
    $file .= '.pm';

    eval { require $file };
    if ($@) {
        die "Cannot find module '$module': $@\n";
    }

    # Check for to_app method
    unless ($module->can('new') && $module->can('to_app')) {
        die "Module '$module' does not have new() and to_app() methods\n";
    }

    # Instantiate and get app
    my $instance = $module->new(%args);
    my $app = $instance->to_app;

    unless (ref $app eq 'CODE') {
        die "Module '$module' to_app() did not return a coderef\n";
    }

    return $app;
}

sub _load_file ($self, $file) {
    # Convert to absolute path
    $file = File::Spec->rel2abs($file);

    die "App file not found: $file\n" unless -f $file;

    my $app = do $file;

    if ($@) {
        die "Error loading $file: $@\n";
    }
    if (!defined $app && $!) {
        die "Error reading $file: $!\n";
    }
    unless (ref $app eq 'CODE') {
        my $type = ref($app) || 'non-reference';
        die "App file must return a coderef, got: $type\n";
    }

    return $app;
}

sub _parse_app_args ($self, @args) {
    my %result;
    for my $arg (@args) {
        if ($arg =~ /^([^=]+)=(.*)$/) {
            $result{$1} = $2;
        }
        else {
            warn "Ignoring argument without '=': $arg\n";
        }
    }
    return %result;
}

sub _create_loop ($self) {
    if ($self->{loop}) {
        my $loop_class = "IO::Async::Loop::$self->{loop}";
        eval "require $loop_class" or die "Error: Cannot load loop backend '$self->{loop}': $@\n" .
            "Install it with: cpanm $loop_class\n";
        return $loop_class->new;
    }
    return IO::Async::Loop->new;
}

sub _show_help ($self) {
    print <<'HELP';
Usage: pagi-server [options] [app] [key=value ...]

Options:
    -a, --app FILE      Load app from file (legacy option)
    -h, --host HOST     Bind address (default: 127.0.0.1)
    -p, --port PORT     Bind port (default: 5000)
    -w, --workers NUM   Number of worker processes (default: 1)
    -l, --loop BACKEND  Event loop backend (EV, Epoll, UV, Poll)
    --ssl-cert FILE     SSL certificate file
    --ssl-key FILE      SSL private key file
    --access-log FILE   Access log file (default: STDERR)
    -q, --quiet         Suppress startup messages
    --help              Show this help

App can be:
    Module name:    pagi-server PAGI::App::Directory root=/var/www
    File path:      pagi-server ./app.pl
    Default:        pagi-server                (serves current directory)

Examples:
    pagi-server                                    # Serve current directory
    pagi-server PAGI::App::Directory root=/tmp    # Serve /tmp
    pagi-server -p 8080 ./myapp.pl                # Run app on port 8080
    pagi-server -w 4 PAGI::App::Proxy target=http://backend:3000

HELP
}

1;

__END__

=head1 SEE ALSO

L<PAGI::Server>, L<Plack::Runner>

=head1 AUTHOR

John Napiorkowski E<lt>jjnapiork@cpan.orgE<gt>

=head1 LICENSE

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
