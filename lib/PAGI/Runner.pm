package PAGI::Runner;

use strict;
use warnings;
use Getopt::Long qw(GetOptionsFromArray :config pass_through no_auto_abbrev no_ignore_case);
use Pod::Usage;
use File::Spec;
use POSIX qw(setsid);
use FindBin ();

use PAGI;


=head1 NAME

PAGI::Runner - PAGI application loader and server runner

=head1 SYNOPSIS

    # Command line usage via pagi-server
    pagi-server PAGI::App::Directory root=/var/www
    pagi-server ./app.pl -p 8080
    pagi-server                        # serves current directory

    # With environment modes
    pagi-server -E development app.pl  # enable Lint middleware
    pagi-server -E production app.pl   # no auto-middleware
    PAGI_ENV=production pagi-server app.pl

    # Programmatic usage
    use PAGI::Runner;

    PAGI::Runner->run(@ARGV);

=head1 DESCRIPTION

PAGI::Runner is a loader and runner for PAGI applications, similar to
L<Plack::Runner> for PSGI. It handles CLI argument parsing, app loading
(from files or modules), environment modes, and server orchestration.

The runner is designed to be server-agnostic. Common options like host,
port, and daemonize are handled by the runner, while server-specific
options are passed through to the server backend.

=head1 ENVIRONMENT MODES

PAGI::Runner supports environment modes similar to Plack's C<-E> flag:

=over 4

=item development

Auto-enables L<PAGI::Middleware::Lint> with strict mode to catch
specification violations early. This is the default when running
interactively (TTY detected).

=item production

No middleware is auto-enabled. This is the default when running
non-interactively (no TTY, e.g., systemd, docker, cron).

=item none

Explicit opt-out of all auto-middleware, regardless of TTY detection.

=back

Mode is determined by (in order of precedence):

    1. -E / --env command line flag
    2. PAGI_ENV environment variable
    3. Auto-detection: TTY = development, no TTY = production

After determining the mode, the runner sets C<PAGI_ENV> to the resolved
value. This allows your application to check C<$ENV{PAGI_ENV}> to know
what mode it's running in, similar to Plack's C<PLACK_ENV>.

Use C<--no-default-middleware> to disable auto-middleware while keeping
the mode for other purposes.

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

For compatibility with Plack's C<plackup>, the runner localizes C<$0> to the
app file before loading it. This ensures C<FindBin::Bin> resolves to the app
file directory inside the app. If C<FindBin> was already loaded, the runner
also calls C<FindBin::again()> to refresh its cached path.

=head2 Default

If no app is specified, defaults to serving the current directory:

    pagi-server                        # same as: PAGI::App::Directory root=.

=head1 METHODS

=head2 run

    PAGI::Runner->run(@ARGV);

Class method that creates a runner, parses options, loads the app,
and runs the server. This is the main entry point for CLI usage.

=head2 new

    my $runner = PAGI::Runner->new(%options);

Creates a new runner instance. Most users should use C<run()> instead.

=cut

sub new {
    my ($class, %args) = @_;

    return bless {
        # Runner options (common to all servers)
        host              => $args{host},
        port              => $args{port},
        server            => $args{server},
        env               => $args{env},
        quiet             => $args{quiet}             // 0,
        loop              => $args{loop},
        access_log        => $args{access_log},
        no_access_log     => $args{no_access_log}     // 0,
        daemonize         => $args{daemonize}         // 0,
        pid_file          => $args{pid_file},
        user              => $args{user},
        group             => $args{group},
        libs              => $args{libs}              // [],
        modules           => $args{modules}           // [],
        eval              => $args{eval},
        default_middleware => $args{default_middleware},

        # Internal state
        app               => undef,
        app_spec          => undef,
        app_args          => {},
        server_options    => [],
        argv              => [],
    }, $class;
}

=head2 parse_options

    $runner->parse_options(@args);

Parses CLI options from the argument list. Common options are stored
in the runner object. Server-specific options (those not recognized)
are collected for pass-through to the server.

=head3 Common Options (handled by Runner)

    -a, --app FILE      Load app from file (legacy option)
    -e CODE             Inline app code (like perl -e)
    -M MODULE           Load MODULE before -e (repeatable, like perl -M)
    -o, --host HOST     Bind address (default: 127.0.0.1)
    -p, --port PORT     Bind port (default: 5000)
    -s, --server CLASS  Server class (default: PAGI::Server)
    -E, --env MODE      Environment mode (development, production, none)
    -I, --lib PATH      Add PATH to @INC (repeatable)
    -l, --loop BACKEND  Event loop backend (EV, Epoll, UV, Poll)
    -D, --daemonize     Run as background daemon
    --access-log FILE   Access log file (default: STDERR)
    --no-access-log     Disable access logging
    --pid FILE          Write PID to file
    --user USER         Run as specified user (after binding)
    --group GROUP       Run as specified group (after binding)
    -q, --quiet         Suppress startup messages
    --default-middleware  Toggle mode middleware (default: on)
    -v, --version       Show version info
    --help              Show help

Example with C<-e> and C<-M>:

    pagi-server -MPAGI::App::File -e 'PAGI::App::File->new(root => ".")->to_app'

=head3 Server-Specific Options (passed through)

All unrecognized options starting with C<-> are passed to the server.
For PAGI::Server, these include:

    -w, --workers       Number of worker processes
    --reuseport         Enable SO_REUSEPORT mode
    --ssl-cert, --ssl-key  TLS configuration
    --max-requests, --max-connections, --max-body-size
    --timeout, --log-level, etc.

See L<PAGI::Server> for the full list of server-specific options.

=cut

sub parse_options {
    my ($self, @args) = @_;

    # Pre-process cuddled options like -MModule or -e"code" → -M Module, -e "code"
    # This matches Plack::Runner behavior for perl-like flags
    @args = map { /^(-[IMMe])(.+)/ ? ($1, $2) : $_ } @args;

    my %opts;
    my @libs;
    my @modules;

    # Parse runner options, pass through unknown for server
    GetOptionsFromArray(
        \@args,
        # App loading
        'a|app=s'             => \$opts{app},
        'e=s'                 => \$opts{eval},
        'I|lib=s'             => \@libs,
        'M=s'                 => \@modules,

        # Network
        'o|host=s'            => \$opts{host},
        'p|port=i'            => \$opts{port},

        # Server selection (future: pluggable servers)
        's|server=s'          => \$opts{server},

        # Environment/mode
        'E|env=s'             => \$opts{env},

        # Event loop
        'l|loop=s'            => \$opts{loop},

        # Logging
        'access-log=s'        => \$opts{access_log},
        'no-access-log'       => \$opts{no_access_log},

        # Daemon/process
        'D|daemonize'         => \$opts{daemonize},
        'pid=s'               => \$opts{pid_file},
        'user=s'              => \$opts{user},
        'group=s'             => \$opts{group},

        # Output
        'q|quiet'             => \$opts{quiet},
        'default-middleware!' => \$opts{default_middleware},

        # Help/version
        'help'                => \$opts{help},
        'v|version'           => \$opts{version},
    ) or die "Error parsing options\n";

    # Handle help/version flags
    if ($opts{version}) {
        $self->{show_version} = 1;
        return;
    }
    if ($opts{help}) {
        $self->{show_help} = 1;
        return;
    }

    # Apply parsed options
    $self->{host}       = $opts{host}       if defined $opts{host};
    $self->{port}       = $opts{port}       if defined $opts{port};
    $self->{server}     = $opts{server}     if defined $opts{server};
    $self->{env}        = $opts{env}        if defined $opts{env};
    $self->{loop}       = $opts{loop}       if defined $opts{loop};
    $self->{access_log} = $opts{access_log} if defined $opts{access_log};
    $self->{no_access_log} = $opts{no_access_log} if $opts{no_access_log};
    $self->{daemonize}  = $opts{daemonize}  if $opts{daemonize};
    $self->{pid_file}   = $opts{pid_file}   if defined $opts{pid_file};
    $self->{user}       = $opts{user}       if defined $opts{user};
    $self->{group}      = $opts{group}      if defined $opts{group};
    $self->{quiet}      = $opts{quiet}      if $opts{quiet};
    $self->{default_middleware} = $opts{default_middleware}
        if defined $opts{default_middleware};

    # Add library paths
    push @{$self->{libs}}, @libs if @libs;

    # Store -M modules for loading
    push @{$self->{modules}}, @modules if @modules;

    # Store -e eval code
    $self->{eval} = $opts{eval} if defined $opts{eval};

    # Legacy --app flag
    if (defined $opts{app}) {
        $self->{app_spec} = $opts{app};
    }

    # Separate remaining args: options for server vs app spec/args
    # Need to keep option values with their options
    my $i = 0;
    while ($i < @args) {
        my $arg = $args[$i];
        if ($arg =~ /^-/) {
            push @{$self->{server_options}}, $arg;
            # If next arg is a value (doesn't start with - and isn't =), keep it with the option
            if ($i + 1 < @args && $args[$i + 1] !~ /^-/ && $arg !~ /=/) {
                push @{$self->{server_options}}, $args[++$i];
            }
        } else {
            push @{$self->{argv}}, $arg;
        }
        $i++;
    }
}

=head2 mode

    my $mode = $runner->mode;

Returns the current environment mode. Determines mode by checking
(in order): explicit C<-E> flag, C<PAGI_ENV> environment variable,
or auto-detection based on TTY.

=cut

sub mode {
    my ($self) = @_;

    return $self->{env} if defined $self->{env};
    return $ENV{PAGI_ENV} if defined $ENV{PAGI_ENV};
    return -t STDIN ? 'development' : 'production';
}

=head2 load_app

    my $app = $runner->load_app;

Loads the PAGI application based on the app specifier from command
line arguments. Returns the app coderef.

=cut

sub load_app {
    my ($self) = @_;

    # Add library paths to @INC before loading
    if (@{$self->{libs}}) {
        unshift @INC, @{$self->{libs}};
    }

    # Load -M modules before evaluating -e code
    for my $module (@{$self->{modules}}) {
        # Handle Module=import,args syntax like perl -M
        my ($mod, $imports) = split /=/, $module, 2;
        eval "require $mod";
        die "Cannot load module $mod: $@\n" if $@;
        if (defined $imports) {
            my @imports = split /,/, $imports;
            $mod->import(@imports);
        } else {
            $mod->import;
        }
    }

    # Handle -e inline code
    if (defined $self->{eval}) {
        my $code = $self->{eval};
        my $app = eval $code;
        die "Error evaluating -e code: $@\n" if $@;
        die "-e code must return a coderef, got " . (ref($app) || 'non-reference') . "\n"
            unless ref $app eq 'CODE';
        $self->{app_spec} = '-e';
        $self->{app} = $app;
        return $app;
    }

    # Get app spec from argv if not set via --app
    my @argv = @{$self->{argv}};
    if (!$self->{app_spec} && @argv) {
        my $first = $argv[0];
        # Check if first arg looks like an app spec (not a key=value)
        if ($first !~ /=/) {
            $self->{app_spec} = shift @argv;
            $self->{argv} = \@argv;
        }
    }

    my $app_spec = $self->{app_spec};

    # Default: serve current directory
    my %app_args;
    if (!defined $app_spec) {
        $app_spec = 'PAGI::App::Directory';
        %app_args = (root => '.');
    } else {
        # Parse constructor args (key=value pairs) from remaining argv
        %app_args = $self->_parse_app_args(@{$self->{argv}});
    }

    $self->{app_spec} = $app_spec;
    $self->{app_args} = \%app_args;

    my $app;
    if ($self->_is_module_name($app_spec)) {
        $app = $self->_load_module($app_spec, %app_args);
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
            $app = $self->_load_module($app_spec, %app_args);
        }
    }

    $self->{app} = $app;
    return $app;
}

=head2 prepare_app

    my $app = $runner->prepare_app;

Loads the app and wraps it with mode-appropriate middleware.
In development mode (with default_middleware enabled), wraps
with L<PAGI::Middleware::Lint>.

=cut

sub prepare_app {
    my ($self) = @_;

    my $app = $self->load_app;

    # Wrap with mode middleware unless disabled
    my $use_middleware = $self->{default_middleware} // 1;

    if ($use_middleware && $self->mode eq 'development') {
        require PAGI::Middleware::Lint;
        $app = PAGI::Middleware::Lint->new(strict => 1)->wrap($app);

        warn "PAGI development mode - Lint middleware enabled\n"
            unless $self->{quiet};
    }

    $self->{app} = $app;
    return $app;
}

=head2 load_server

    my $server = $runner->load_server;

Creates the server instance with the prepared app and configuration.
Parses server-specific options and passes them to the server constructor.

=cut

sub load_server {
    my ($self) = @_;

    my $server_class = $self->{server} // 'PAGI::Server';

    # Load server class
    my $server_file = $server_class;
    $server_file =~ s{::}{/}g;
    $server_file .= '.pm';

    eval { require $server_file };
    if ($@) {
        die "Cannot load server '$server_class': $@\n";
    }

    # Parse server-specific options
    my %server_opts = $self->_parse_server_options($server_class);

    # Handle access log
    # Production mode disables logging by default for performance
    # Use --access-log to explicitly enable in production
    my $access_log;
    my $disable_log = 0;

    if ($self->{no_access_log}) {
        # Explicit --no-access-log
        $disable_log = 1;
    }
    elsif ($self->{access_log}) {
        # Explicit --access-log FILE
        open $access_log, '>>', $self->{access_log}
            or die "Cannot open access log $self->{access_log}: $!\n";
    }
    elsif ($self->mode eq 'production') {
        # Production mode: disable logging by default
        $disable_log = 1;
    }
    # else: development mode uses server default (STDERR)

    # Build server
    return $server_class->new(
        app        => $self->{app},
        host       => $self->{host} // '127.0.0.1',
        port       => $self->{port} // 5000,
        quiet      => $self->{quiet} // 0,
        ($self->{loop} ? (loop_type => $self->{loop}) : ()),
        (defined $access_log || $disable_log
            ? (access_log => $access_log) : ()),
        %server_opts,
    );
}

sub _parse_server_options {
    my ($self, $server_class) = @_;

    my @args = @{$self->{server_options} // []};
    my %opts;

    if ($server_class eq 'PAGI::Server') {
        GetOptionsFromArray(
            \@args,
            # Workers/scaling
            'w|workers=i'           => \$opts{workers},
            'reuseport'             => \$opts{reuseport},
            'max-requests=i'        => \$opts{max_requests},
            'max-connections=i'     => \$opts{max_connections},

            # TLS
            'ssl-cert=s'            => \$opts{_ssl_cert},
            'ssl-key=s'             => \$opts{_ssl_key},

            # Timeouts
            'timeout=i'             => \$opts{timeout},
            'shutdown-timeout=i'    => \$opts{shutdown_timeout},
            'request-timeout=i'     => \$opts{request_timeout},
            'ws-idle-timeout=i'     => \$opts{ws_idle_timeout},
            'sse-idle-timeout=i'    => \$opts{sse_idle_timeout},

            # Limits
            'max-body-size=i'       => \$opts{max_body_size},
            'max-header-size=i'     => \$opts{max_header_size},
            'max-header-count=i'    => \$opts{max_header_count},
            'max-receive-queue=i'   => \$opts{max_receive_queue},
            'max-ws-frame-size=i'   => \$opts{max_ws_frame_size},
            'b|listener-backlog=i'  => \$opts{listener_backlog},

            # Misc
            'log-level=s'           => \$opts{log_level},
            'sync-file-threshold=i' => \$opts{sync_file_threshold},
        );

        # Build ssl hash if certs provided
        # Note: TLS module availability is checked by the server, not here
        if ($opts{_ssl_cert} || $opts{_ssl_key}) {
            die "--ssl-cert and --ssl-key must be specified together\n"
                unless $opts{_ssl_cert} && $opts{_ssl_key};

            die "SSL cert not found: $opts{_ssl_cert}\n"
                unless -f $opts{_ssl_cert};
            die "SSL key not found: $opts{_ssl_key}\n"
                unless -f $opts{_ssl_key};

            $opts{ssl} = {
                cert_file => delete $opts{_ssl_cert},
                key_file  => delete $opts{_ssl_key},
            };
        }
        delete $opts{_ssl_cert};
        delete $opts{_ssl_key};

        # Handle workers (0 for single-process, >1 for multi-worker)
        if (defined $opts{workers}) {
            $opts{workers} = $opts{workers} > 1 ? $opts{workers} : 0;
        }
    }

    # Return only defined options
    return map { $_ => $opts{$_} } grep { defined $opts{$_} } keys %opts;
}

=head2 run

    PAGI::Runner->run(@ARGV);
    $runner->run(@ARGV);

Main entry point. Parses options, loads the app, creates the server,
and delegates to C<< $server->run() >> which manages the event loop.

=cut

# Package variable for END block cleanup
our $_current_runner;

sub run {
    my $self = shift;

    # Support both class and instance method
    unless (ref $self) {
        $self = $self->new;
    }

    # Parse options
    $self->parse_options(@_);

    # Export resolved mode to environment so apps can check it
    # (similar to Plack's PLACK_ENV)
    $ENV{PAGI_ENV} = $self->mode;

    # Configure Future::IO for IO::Async if available
    # This enables Future::IO-based libraries (Async::Redis, etc.) and
    # PAGI::SSE->every() to work seamlessly under pagi-server
    $self->_configure_future_io;

    # Handle --version
    if ($self->{show_version}) {
        $self->_show_version;
        return;
    }

    # Handle --help
    if ($self->{show_help}) {
        $self->_show_help;
        return;
    }

    # Prepare app (load + wrap with middleware)
    $self->prepare_app;

    # Create server
    my $server = $self->load_server;

    # Daemonize before running (bind errors will be lost in daemon mode,
    # but this is acceptable for production where systemd/docker is preferred)
    if ($self->{daemonize}) {
        $self->_daemonize;
    }

    # Write PID file (after daemonizing so we record the daemon's PID)
    if ($self->{pid_file}) {
        $self->_write_pid_file($self->{pid_file});
        # Store for END block cleanup
        $_current_runner = $self;
    }

    # Drop privileges
    if ($self->{user} || $self->{group}) {
        $self->_drop_privileges;
    }

    # Run server (server owns the event loop)
    $server->run;

    # Cleanup PID file on normal exit
    $self->_remove_pid_file if $self->{_pid_file_path};
}

# END block for PID file cleanup on abnormal exit
END {
    if ($_current_runner && $_current_runner->{_pid_file_path}) {
        $_current_runner->_remove_pid_file;
    }
}

# Internal methods

sub _configure_future_io {
    my ($self) = @_;

    # Try to configure Future::IO for IO::Async
    # This enables seamless use of Future::IO-based libraries under pagi-server
    my $configured = eval {
        require Future::IO::Impl::IOAsync;
        1;
    };

    if ($configured) {
        # Report in non-production mode
        if ($self->mode ne 'production' && !$self->{quiet}) {
            warn "Future::IO configured for IO::Async\n";
        }
    }
    # If Future::IO::Impl::IOAsync not installed, that's fine - user just
    # won't have Future::IO integration. Apps that need it will get a
    # helpful error message from PAGI::SSE->every() or similar.
}

sub _is_module_name {
    my ($self, $spec) = @_;
    return $spec =~ /::/;
}

sub _is_file_path {
    my ($self, $spec) = @_;
    return $spec =~ m{/} || $spec =~ /\.(?:pl|psgi)$/i;
}

sub _load_module {
    my ($self, $module, %args) = @_;

    # Validate module name (basic security check)
    die "Invalid module name: $module\n"
        unless $module =~ /^[A-Za-z_][A-Za-z0-9_]*(?:::[A-Za-z_][A-Za-z0-9_]*)*$/;

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

    # Get the module's actual file path for correct home directory detection
    my $module_file = $INC{$file};

    # Instantiate and get app (pass _caller_file for correct home dir)
    my $instance = $module->new(%args, _caller_file => $module_file);
    my $app = $instance->to_app;

    unless (ref $app eq 'CODE') {
        die "Module '$module' to_app() did not return a coderef\n";
    }

    return $app;
}

sub _load_file {
    my ($self, $file) = @_;

    # Convert to absolute path
    $file = File::Spec->rel2abs($file);

    die "App file not found: $file\n" unless -f $file;

    # Match plackup behavior so FindBin::Bin resolves to the app file directory
    local $0 = $file;
    local @ARGV = ($file);
    if (exists $INC{'FindBin.pm'}) {
        FindBin::again();
    }

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

sub _parse_app_args {
    my ($self, @args) = @_;

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

sub _show_help {
    my ($self) = @_;

    print <<'HELP';
Usage: pagi-server [options] [app] [key=value ...]

Common Options:
    -I, --lib PATH      Add PATH to @INC (repeatable, like perl -I)
    -a, --app FILE      Load app from file (legacy option)
    -o, --host HOST     Bind address (default: 127.0.0.1)
    -p, --port PORT     Bind port (default: 5000)
    -s, --server CLASS  Server class (default: PAGI::Server)
    -E, --env MODE      Environment mode (development, production, none)
    -l, --loop BACKEND  Event loop backend (EV, Epoll, UV, Poll)
    --access-log FILE   Access log file (default: STDERR)
    --no-access-log     Disable access logging
    -D, --daemonize     Run as background daemon
    --pid FILE          Write PID to file
    --user USER         Run as specified user (after binding)
    --group GROUP       Run as specified group (after binding)
    -q, --quiet         Suppress startup messages
    --no-default-middleware  Disable mode-based middleware
    -v, --version       Show version info
    --help              Show this help

PAGI::Server Options (pass-through):
    -w, --workers NUM   Number of worker processes (default: 1)
    --ssl-cert FILE     SSL certificate file
    --ssl-key FILE      SSL private key file
    --reuseport         SO_REUSEPORT mode (reduces accept contention)
    --max-requests NUM  Requests per worker before restart
    --max-connections N Max concurrent connections (0=auto)
    --max-body-size NUM Max request body size (default: 10MB)
    --timeout NUM       Connection idle timeout in seconds
    --log-level LEVEL   Log verbosity: debug, info, warn, error

Environment Modes:
    development    Auto-enable Lint middleware (default if TTY)
    production     No auto-middleware (default if no TTY)
    none           Explicit opt-out of all auto-middleware

App can be:
    Module name:    pagi-server PAGI::App::Directory root=/var/www
    File path:      pagi-server ./app.pl
    Default:        pagi-server                (serves current directory)

Examples:
    pagi-server                                    # Serve current directory
    pagi-server -E production ./app.pl            # Production mode
    pagi-server -p 8080 --workers 4 ./myapp.pl    # Custom port + workers
    pagi-server PAGI::App::Directory root=/tmp    # Serve /tmp

HELP
}

sub _show_version {
    my ($self) = @_;

    require PAGI;
    require PAGI::Server;
    print "pagi-server (PAGI $PAGI::VERSION, PAGI::Server $PAGI::Server::VERSION)\n";
}

sub _daemonize {
    my ($self) = @_;

    # First fork - parent exits, child continues
    my $pid = fork();
    die "Cannot fork: $!" unless defined $pid;
    exit(0) if $pid;  # Parent exits

    # Child becomes session leader
    setsid() or die "Cannot create new session: $!";

    # Second fork - prevent acquiring a controlling terminal
    $pid = fork();
    die "Cannot fork: $!" unless defined $pid;
    exit(0) if $pid;  # First child exits

    # Grandchild continues as daemon
    # Change to root directory to avoid blocking unmounts
    chdir('/') or die "Cannot chdir to /: $!";

    # Clear umask
    umask(0);

    # Redirect standard file descriptors to /dev/null
    open(STDIN, '<', '/dev/null') or die "Cannot redirect STDIN: $!";
    open(STDOUT, '>', '/dev/null') or die "Cannot redirect STDOUT: $!";
    open(STDERR, '>', '/dev/null') or die "Cannot redirect STDERR: $!";

    return $$;  # Return daemon PID
}

sub _write_pid_file {
    my ($self, $pid_file) = @_;

    open(my $fh, '>', $pid_file)
        or die "Cannot write PID file $pid_file: $!\n";
    print $fh "$$\n";
    close($fh);

    # Store for cleanup
    $self->{_pid_file_path} = $pid_file;
}

sub _remove_pid_file {
    my ($self) = @_;

    return unless $self->{_pid_file_path};
    unlink($self->{_pid_file_path});
}

sub _drop_privileges {
    my ($self) = @_;

    my $user = $self->{user};
    my $group = $self->{group};

    return unless $user || $group;

    # Must be root to change user/group
    if ($> != 0) {
        die "Must run as root to use --user/--group\n";
    }

    # Change group first (while still root)
    if ($group) {
        my $gid = getgrnam($group);
        die "Unknown group: $group\n" unless defined $gid;

        # Set both real and effective GID
        $( = $) = $gid;
        die "Cannot change to group $group: $!\n" if $) != $gid;
    }

    # Then change user
    if ($user) {
        my ($uid, $gid) = (getpwnam($user))[2, 3];
        die "Unknown user: $user\n" unless defined $uid;

        # If no group specified, use user's primary group
        unless ($group) {
            $( = $) = $gid;
        }

        # Set both real and effective UID
        $< = $> = $uid;
        die "Cannot change to user $user: $!\n" if $> != $uid;
    }
}

1;

__END__

=head1 BREAKING CHANGES

As of version 1.0, PAGI::Runner has been refactored to be server-agnostic:

=over 4

=item * Server-specific options are now passed through to the server

=item * The C<prepare_server()> method has been replaced by C<load_server()>

=item * Development mode now auto-enables Lint middleware

=back

The CLI interface is unchanged - existing command-line usage continues
to work as before.

=head1 SEE ALSO

L<PAGI::Server>, L<PAGI::Middleware::Lint>, L<Plack::Runner>

=head1 AUTHOR

John Napiorkowski E<lt>jjnapiork@cpan.orgE<gt>

=head1 LICENSE

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
