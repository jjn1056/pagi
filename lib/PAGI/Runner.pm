package PAGI::Runner;

use strict;
use warnings;
use experimental 'signatures';
use Getopt::Long qw(GetOptionsFromArray :config pass_through no_auto_abbrev);
use Pod::Usage;
use File::Spec;
use POSIX qw(setsid);
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

=item listener_backlog => $num

Listener queue size. No default, if left blank then the
server sets a default that is rational for itself.

=item timeout => $num

Seconds before we timeout the request. If left blank will
default to whatever is default for the server.

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

=item no_access_log => $bool

Disable access logging entirely. Eliminates per-request I/O overhead,
which can improve throughput by 5-15% depending on workload. Default: 0

=item log_level => $level

Controls the verbosity of server log messages. Valid levels from least
to most verbose: 'error', 'warn', 'info', 'debug'. Default: 'info'

=item reuseport => $bool

Enable SO_REUSEPORT mode for multi-worker servers. Each worker creates its
own listening socket, allowing the kernel to distribute connections. Reduces
accept() contention and can improve p99 latency under high concurrency.
Default: 0

=item max_receive_queue => $count

Maximum WebSocket receive queue size (message count). When exceeded, connection
is closed with code 1008. DoS protection for slow consumers. Default: 1000

=item max_ws_frame_size => $bytes

Maximum WebSocket frame payload size in bytes. When a client sends a frame
larger than this limit, the connection is closed. Default: 65536 (64KB)

=item max_requests => $count

Maximum requests per worker before restart. Default: 0 (unlimited)

=item libs => \@paths

Additional library paths to add to @INC before loading the app.
Similar to C<perl -I>. Default: []

=item daemonize => $bool

Fork to background and detach from terminal. Default: 0

=item pid_file => $path

Write process ID to this file. Useful for init scripts and process managers.

=item user => $username

Drop privileges to this user after binding to port. Requires starting as root.

=item group => $groupname

Drop privileges to this group after binding to port. Requires starting as root.

=back

=cut

sub new ($class, %args) {
    return bless {
        host              => $args{host}              // '127.0.0.1',
        port              => $args{port}              // 5000,
        workers           => $args{workers}           // 1,
        quiet             => $args{quiet}             // 0,
        loop              => $args{loop}              // undef,
        ssl_cert          => $args{ssl_cert}          // undef,
        ssl_key           => $args{ssl_key}           // undef,
        access_log        => $args{access_log}        // undef,
        no_access_log     => $args{no_access_log}     // 0,
        log_level         => $args{log_level}         // undef,
        timeout           => $args{timeout}           // undef,
        listener_backlog  => $args{listener_backlog}  // undef,
        reuseport         => $args{reuseport}         // 0,
        max_receive_queue => $args{max_receive_queue} // undef,
        max_ws_frame_size => $args{max_ws_frame_size} // undef,
        max_requests      => $args{max_requests}      // undef,
        daemonize         => $args{daemonize}         // 0,
        pid_file          => $args{pid_file}          // undef,
        user              => $args{user}              // undef,
        group             => $args{group}             // undef,
        libs              => $args{libs}              // [],
        app               => undef,
        app_spec          => undef,
        app_args          => {},
    }, $class;
}

=head2 parse_options

    my @remaining = $runner->parse_options(@args);

Parses CLI options from the argument list. Known options are extracted
and stored in the runner object. Returns remaining arguments (app specifier
and constructor args).

Supported options:

    -I, --lib       Add path to @INC (repeatable, like perl -I)
    -a, --app       App file path (legacy, for backward compatibility)
    -h, --host      Bind address
    -p, --port      Bind port
    -w, --workers   Number of workers
    -l, --loop      Event loop backend
    --ssl-cert      SSL certificate path
    --ssl-key       SSL key path
    --access-log    Access log path
    --no-access-log Disable access logging (for max performance)
    --log-level     Log verbosity: debug, info, warn, error (default: info)
    --reuseport     Enable SO_REUSEPORT for multi-worker scaling
    --max-requests  Requests per worker before restart (default: unlimited)
    -q, --quiet     Suppress output
    --help          Show help

=cut

sub parse_options ($self, @args) {
    my %opts;
    my $help;

    # Use pass_through to leave unknown options for the app
    my @libs;
    GetOptionsFromArray(
        \@args,
        'I|lib=s'               => \@libs,
        'app|a=s'               => \$opts{app},
        'host|h=s'              => \$opts{host},
        'port|p=i'              => \$opts{port},
        'workers|w=i'           => \$opts{workers},
        'listener_backlog|b=i'  => \$opts{listener_backlog},
        'timeout=i'             => \$opts{timeout},
        'loop|l=s'              => \$opts{loop},
        'ssl-cert=s'            => \$opts{ssl_cert},
        'ssl-key=s'             => \$opts{ssl_key},
        'access-log=s'          => \$opts{access_log},
        'no-access-log'         => \$opts{no_access_log},
        'log-level=s'           => \$opts{log_level},
        'reuseport'             => \$opts{reuseport},
        'max-receive-queue=i'   => \$opts{max_receive_queue},
        'max-ws-frame-size=i'   => \$opts{max_ws_frame_size},
        'max-requests=i'        => \$opts{max_requests},
        'daemonize|D'           => \$opts{daemonize},
        'pid=s'                 => \$opts{pid_file},
        'user=s'                => \$opts{user},
        'group=s'               => \$opts{group},
        'quiet|q'               => \$opts{quiet},
        'help'                  => \$help,
    ) or die "Error parsing options\n";

    if ($help) {
        $self->{show_help} = 1;
        return @args;
    }

    # Apply parsed options
    $self->{host}             = $opts{host}                   if defined $opts{host};
    $self->{port}             = $opts{port}                   if defined $opts{port};
    $self->{workers}          = $opts{workers}                if defined $opts{workers};
    $self->{loop}             = $opts{loop}                   if defined $opts{loop};
    $self->{ssl_cert}         = $opts{ssl_cert}               if defined $opts{ssl_cert};
    $self->{ssl_key}          = $opts{ssl_key}                if defined $opts{ssl_key};
    $self->{access_log}       = $opts{access_log}             if defined $opts{access_log};
    $self->{no_access_log}    = $opts{no_access_log}          if $opts{no_access_log};
    $self->{log_level}        = $opts{log_level}              if defined $opts{log_level};
    $self->{listener_backlog} = $opts{listener_backlog}       if defined $opts{listener_backlog};
    $self->{timeout}          = $opts{timeout}                if defined $opts{timeout};
    $self->{reuseport}        = $opts{reuseport}              if $opts{reuseport};
    $self->{max_receive_queue} = $opts{max_receive_queue}    if defined $opts{max_receive_queue};
    $self->{max_ws_frame_size} = $opts{max_ws_frame_size}    if defined $opts{max_ws_frame_size};
    $self->{max_requests}      = $opts{max_requests}          if defined $opts{max_requests};
    $self->{daemonize}        = $opts{daemonize}              if $opts{daemonize};
    $self->{pid_file}         = $opts{pid_file}               if defined $opts{pid_file};
    $self->{user}             = $opts{user}                   if defined $opts{user};
    $self->{group}            = $opts{group}                  if defined $opts{group};
    $self->{quiet}            = $opts{quiet}                  if $opts{quiet};

    # Add library paths (can be specified multiple times)
    push @{$self->{libs}}, @libs if @libs;

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
    # Add library paths to @INC before loading
    if (@{$self->{libs}}) {
        unshift @INC, @{$self->{libs}};
    }

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

    # Add access log configuration
    if ($self->{no_access_log}) {
        # Explicitly disable access logging
        $server_opts{access_log} = undef;
    }
    elsif ($self->{access_log}) {
        # Log to specified file
        open my $log_fh, '>>', $self->{access_log}
            or die "Cannot open access log $self->{access_log}: $!\n";
        $server_opts{access_log} = $log_fh;
    }
    # else: let server use its default (STDERR)

    # Add log_level if provided
    if (defined $self->{log_level}) {
        $server_opts{log_level} = $self->{log_level};
    }

    # Add listener_backlog is provided, otherwise let the server decide
    if ($self->{listener_backlog}) {
        $server_opts{listener_backlog} = $self->{listener_backlog};
    }

    # Add timeout is provided, otherwise let the server decide
    if ($self->{timeout}) {
        $server_opts{timeout} = $self->{timeout};
    }

    # Add reuseport if enabled
    if ($self->{reuseport}) {
        $server_opts{reuseport} = 1;
    }

    # Add max_receive_queue if provided
    if (defined $self->{max_receive_queue}) {
        $server_opts{max_receive_queue} = $self->{max_receive_queue};
    }

    # Add max_ws_frame_size if provided
    if (defined $self->{max_ws_frame_size}) {
        $server_opts{max_ws_frame_size} = $self->{max_ws_frame_size};
    }

    # Add max_requests if provided
    if (defined $self->{max_requests}) {
        $server_opts{max_requests} = $self->{max_requests};
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

    # Daemonize after binding (so errors go to terminal)
    if ($self->{daemonize}) {
        $self->_daemonize;
    }

    # Write PID file (after daemonizing so we record the daemon's PID)
    if ($self->{pid_file}) {
        $self->_write_pid_file($self->{pid_file});
    }

    # Set up PID file cleanup on exit
    if ($self->{_pid_file_path}) {
        $loop->watch_signal(TERM => sub {
            $self->_remove_pid_file;
        });
        $loop->watch_signal(INT => sub {
            $self->_remove_pid_file;
        });
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
    -I, --lib PATH      Add PATH to @INC (repeatable, like perl -I)
    -a, --app FILE      Load app from file (legacy option)
    -h, --host HOST     Bind address (default: 127.0.0.1)
    -p, --port PORT     Bind port (default: 5000)
    -w, --workers NUM   Number of worker processes (default: 1)
    -l, --loop BACKEND  Event loop backend (EV, Epoll, UV, Poll)
    --ssl-cert FILE     SSL certificate file
    --ssl-key FILE      SSL private key file
    --access-log FILE   Access log file (default: STDERR)
    --no-access-log     Disable access logging (improves throughput)
    --reuseport         SO_REUSEPORT mode (reduces accept contention)
    --max-receive-queue NUM  Max WebSocket receive queue size (default: 1000)
    --max-ws-frame-size NUM  Max WebSocket frame size in bytes (default: 65536)
    --max-requests NUM  Requests per worker before restart (default: unlimited)
    --log-level LEVEL   Log verbosity: debug, info, warn, error (default: info)
    -D, --daemonize     Run as background daemon
    --pid FILE          Write PID to file
    --user USER         Run as specified user (after binding)
    --group GROUP       Run as specified group (after binding)
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

sub _daemonize ($self) {
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

sub _write_pid_file ($self, $pid_file) {
    open(my $fh, '>', $pid_file)
        or die "Cannot write PID file $pid_file: $!\n";
    print $fh "$$\n";
    close($fh);

    # Store for cleanup
    $self->{_pid_file_path} = $pid_file;
}

sub _remove_pid_file ($self) {
    return unless $self->{_pid_file_path};
    unlink($self->{_pid_file_path});
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
