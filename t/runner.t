use strict;
use warnings;
use Test2::V0;
use IO::Async::Loop;
use Net::Async::HTTP;
use Future::AsyncAwait;
use FindBin;
use File::Temp qw(tempdir);
use File::Spec;
use Cwd qw(abs_path);

our $test_bin;
BEGIN { $test_bin = $FindBin::Bin; }
use lib "$test_bin/../lib";
use PAGI::Runner;

# Test 1: Basic construction
subtest 'constructor with defaults' => sub {
    my $runner = PAGI::Runner->new;

    ok(!defined $runner->{host}, 'host undef (defaults applied in load_server)');
    ok(!defined $runner->{port}, 'port undef (defaults applied in load_server)');
    is($runner->{quiet}, 0, 'default quiet');
    ok(!defined $runner->{app}, 'no app initially');
};

# Test 2: Constructor with options
subtest 'constructor with options' => sub {
    my $runner = PAGI::Runner->new(
        host    => '0.0.0.0',
        port    => 8080,
        quiet   => 1,
    );

    is($runner->{host}, '0.0.0.0', 'custom host');
    is($runner->{port}, 8080, 'custom port');
    is($runner->{quiet}, 1, 'custom quiet');
};

# Test 3: Parse CLI options (runner options)
subtest 'parse runner CLI options' => sub {
    my $runner = PAGI::Runner->new;
    $runner->parse_options(
        '-p', '8080',
        '-o', '0.0.0.0',
        '-q',
        'PAGI::App::Directory',
        'root=/tmp',
    );

    is($runner->{port}, 8080, 'port parsed');
    is($runner->{host}, '0.0.0.0', 'host parsed');
    is($runner->{quiet}, 1, 'quiet parsed');
    # App spec and args are now in argv
    is(scalar @{$runner->{argv}}, 2, 'two args in argv');
    is($runner->{argv}[0], 'PAGI::App::Directory', 'app spec in argv');
    is($runner->{argv}[1], 'root=/tmp', 'app arg in argv');
};

# Test 4: Parse long CLI options
subtest 'parse long CLI options' => sub {
    my $runner = PAGI::Runner->new;
    $runner->parse_options(
        '--port', '9000',
        '--host', '192.168.1.1',
        '--quiet',
        '--loop', 'EV',
        'app.pl',
    );

    is($runner->{port}, 9000, 'port parsed');
    is($runner->{host}, '192.168.1.1', 'host parsed');
    is($runner->{quiet}, 1, 'quiet parsed');
    is($runner->{loop}, 'EV', 'loop parsed');
    is($runner->{argv}[0], 'app.pl', 'app file in argv');
};

# Test 5: Legacy --app flag
subtest 'legacy --app flag' => sub {
    my $runner = PAGI::Runner->new;
    $runner->parse_options('--app', 'examples/01-hello-http/app.pl', '-p', '3000');

    is($runner->{app_spec}, 'examples/01-hello-http/app.pl', '--app sets app_spec');
    is($runner->{port}, 3000, 'port also parsed');
};

# Test 6: Module name detection
subtest 'module name detection' => sub {
    my $runner = PAGI::Runner->new;

    ok($runner->_is_module_name('PAGI::App::Directory'), 'detects module name');
    ok($runner->_is_module_name('Foo::Bar::Baz'), 'detects any module name');
    ok(!$runner->_is_module_name('app.pl'), 'file is not module');
    ok(!$runner->_is_module_name('./path/to/app.pl'), 'path is not module');
};

# Test 7: File path detection
subtest 'file path detection' => sub {
    my $runner = PAGI::Runner->new;

    ok($runner->_is_file_path('./app.pl'), 'detects relative path');
    ok($runner->_is_file_path('/path/to/app.pl'), 'detects absolute path');
    ok($runner->_is_file_path('app.pl'), 'detects .pl extension');
    ok($runner->_is_file_path('myapp.psgi'), 'detects .psgi extension');
    ok(!$runner->_is_file_path('PAGI::App::Directory'), 'module is not file');
};

# Test 8: Parse app args (key=value)
subtest 'parse app args' => sub {
    my $runner = PAGI::Runner->new;
    my %args = $runner->_parse_app_args('root=/tmp', 'show_hidden=1', 'index=index.html');

    is($args{root}, '/tmp', 'root parsed');
    is($args{show_hidden}, '1', 'show_hidden parsed');
    is($args{index}, 'index.html', 'index parsed');
};

# Test 9: Load app from file
subtest 'load app from file' => sub {
    my $runner = PAGI::Runner->new;
    $runner->{app_spec} = "$test_bin/../examples/01-hello-http/app.pl";

    my $app = $runner->load_app;

    ok(ref $app eq 'CODE', 'loaded app is coderef');
    is($runner->{app}, $app, 'app stored in runner');
};

subtest 'load app from file sets FindBin::Bin to app directory' => sub {
    my $tmpdir = tempdir(CLEANUP => 1);
    my $app_file = File::Spec->catfile($tmpdir, 'findbin_app.pl');

    open my $fh, '>', $app_file or die "Cannot write $app_file: $!";
    print $fh <<'APP';
package App::FindBinTest;
use FindBin;
our $BIN = $FindBin::Bin;
sub app { }
return \&app;
APP
    close $fh;

    my $runner = PAGI::Runner->new;
    $runner->{app_spec} = $app_file;
    my $app = $runner->load_app;

    ok(ref $app eq 'CODE', 'loaded app is coderef');
    no warnings 'once';
    is(abs_path($App::FindBinTest::BIN), abs_path($tmpdir), 'FindBin::Bin matches app directory');
};

# Test 10: Load app from module
subtest 'load app from module' => sub {
    my $runner = PAGI::Runner->new;
    $runner->{argv} = ['PAGI::App::Directory', 'root=.'];

    my $app = $runner->load_app;

    ok(ref $app eq 'CODE', 'loaded app is coderef');
    is($runner->{app}, $app, 'app stored in runner');
    is($runner->{app_spec}, 'PAGI::App::Directory', 'app_spec stored');
    is($runner->{app_args}{root}, '.', 'app_args stored');
};

# Test 11: Default app (no arguments)
subtest 'default app loads Directory' => sub {
    my $runner = PAGI::Runner->new;
    my $app = $runner->load_app;

    ok(ref $app eq 'CODE', 'default app is coderef');
    is($runner->{app_spec}, 'PAGI::App::Directory', 'default is Directory');
    is($runner->{app_args}{root}, '.', 'default root is current dir');
};

# Test 12: Error on missing file
subtest 'error on missing file' => sub {
    my $runner = PAGI::Runner->new;
    $runner->{app_spec} = 'nonexistent_file_12345.pl';

    like(
        dies { $runner->load_app },
        qr/not found/i,
        'dies on missing file'
    );
};

# Test 13: Error on invalid module
subtest 'error on invalid module' => sub {
    my $runner = PAGI::Runner->new;
    $runner->{argv} = ['PAGI::App::NonExistent12345'];

    like(
        dies { $runner->load_app },
        qr/Cannot find module/i,
        'dies on invalid module'
    );
};

# Test 14: Error on file that doesn't return coderef
subtest 'error on non-coderef file' => sub {
    my $tmpdir = tempdir(CLEANUP => 1);
    my $bad_app = "$tmpdir/bad_app.pl";

    # Write a file that returns a hashref instead of coderef
    open my $fh, '>', $bad_app or die "Cannot write $bad_app: $!";
    print $fh "{ foo => 'bar' };\n";
    close $fh;

    my $runner = PAGI::Runner->new;
    $runner->{app_spec} = $bad_app;

    like(
        dies { $runner->load_app },
        qr/must return a coderef/i,
        'dies on non-coderef'
    );
};

# Test 15: load_server creates PAGI::Server
subtest 'load_server creates server' => sub {
    my $runner = PAGI::Runner->new(port => 0, quiet => 1);
    $runner->prepare_app;  # Load and prepare app

    my $server = $runner->load_server;

    ok($server->isa('PAGI::Server'), 'returns PAGI::Server');
};

# Test 16: load_server dies without app
subtest 'load_server dies without app' => sub {
    my $runner = PAGI::Runner->new;

    like(
        dies { $runner->load_server },
        qr/app/i,
        'dies without app'
    );
};

# Test 17: Integration test - server responds to requests
subtest 'integration: server responds to requests' => sub {
    my $loop = IO::Async::Loop->new;

    my $runner = PAGI::Runner->new(port => 0, quiet => 1);
    $runner->{app_spec} = "$test_bin/../examples/01-hello-http/app.pl";
    $runner->{default_middleware} = 0;  # Disable Lint for test
    $runner->prepare_app;
    my $server = $runner->load_server;

    $loop->add($server);
    $server->listen->get;

    my $port = $server->port;
    ok($port > 0, "server bound to port $port");

    my $http = Net::Async::HTTP->new;
    $loop->add($http);

    my $response = $http->GET("http://127.0.0.1:$port/")->get;

    is($response->code, 200, 'response is 200 OK');
    like($response->decoded_content, qr/Hello from PAGI/, 'correct response body');

    $server->shutdown->get;
    $loop->remove($server);
    $loop->remove($http);
};

# Test 18: Integration test - module-based app
subtest 'integration: module-based app serves files' => sub {
    my $loop = IO::Async::Loop->new;

    # Create a temp directory with a file
    my $tmpdir = tempdir(CLEANUP => 1);
    open my $fh, '>', "$tmpdir/test.txt" or die $!;
    print $fh "Hello from test file";
    close $fh;

    my $runner = PAGI::Runner->new(port => 0, quiet => 1);
    $runner->{argv} = ['PAGI::App::File', "root=$tmpdir"];
    $runner->{default_middleware} = 0;  # Disable Lint for test
    $runner->prepare_app;
    my $server = $runner->load_server;

    $loop->add($server);
    $server->listen->get;

    my $port = $server->port;

    my $http = Net::Async::HTTP->new;
    $loop->add($http);

    my $response = $http->GET("http://127.0.0.1:$port/test.txt")->get;

    is($response->code, 200, 'file served with 200');
    is($response->decoded_content, 'Hello from test file', 'correct file content');

    $server->shutdown->get;
    $loop->remove($server);
    $loop->remove($http);
};

# Test 19: SSL options validation (via server_options)
subtest 'server_options hashref is passed through' => sub {
    # Server options are now passed as a hashref from bin/pagi-server
    my $runner = PAGI::Runner->new;
    $runner->parse_options(
        'server_options', { workers => 4, reuseport => 1 },
        'app.pl',
    );

    is(ref($runner->{server_options}), 'HASH', 'server_options is a hashref');
    is($runner->{server_options}{workers}, 4, 'workers option passed through');
    is($runner->{server_options}{reuseport}, 1, 'reuseport option passed through');
};

# Test 20: help flag
subtest 'help flag sets show_help' => sub {
    my $runner = PAGI::Runner->new;
    $runner->parse_options('--help');

    ok($runner->{show_help}, 'show_help is set');
};

# Test 21: production CLI options parsing
subtest 'production CLI options parsing' => sub {
    my $runner = PAGI::Runner->new;
    $runner->parse_options(
        '-D',
        '--pid', '/tmp/test.pid',
        '--user', 'nobody',
        '--group', 'nogroup',
    );

    is($runner->{daemonize}, 1, '--daemonize parsed');
    is($runner->{pid_file}, '/tmp/test.pid', '--pid parsed');
    is($runner->{user}, 'nobody', '--user parsed');
    is($runner->{group}, 'nogroup', '--group parsed');
};

# Test 22: _drop_privileges validation
subtest '_drop_privileges validation' => sub {
    # Skip on Windows - getpwnam/getgrnam not available
    if ($^O eq 'MSWin32') {
        skip_all 'User/group privilege tests not supported on Windows';
    }

    # Test 1: Returns early if neither user nor group specified
    my $runner1 = PAGI::Runner->new(port => 0, quiet => 1);
    ok(lives { $runner1->_drop_privileges }, '_drop_privileges returns early when no user/group');

    # Test 2: Requires root for --user
    my $runner2 = PAGI::Runner->new(
        user => 'nobody',
        port => 0,
        quiet => 1,
    );

    if ($> == 0) {
        # Running as root - test should validate user exists
        my $runner3 = PAGI::Runner->new(
            user => 'nonexistent_user_12345',
            port => 0,
            quiet => 1,
        );
        like(
            dies { $runner3->_drop_privileges },
            qr/Unknown user/,
            'rejects unknown user (as root)'
        );
    } else {
        # Not root - should require root
        like(
            dies { $runner2->_drop_privileges },
            qr/Must run as root/,
            'requires root for --user'
        );
    }

    # Test 3: Requires root for --group
    my $runner4 = PAGI::Runner->new(
        group => 'nogroup',
        port => 0,
        quiet => 1,
    );

    if ($> == 0) {
        # Running as root - test should validate group exists
        my $runner5 = PAGI::Runner->new(
            group => 'nonexistent_group_12345',
            port => 0,
            quiet => 1,
        );
        like(
            dies { $runner5->_drop_privileges },
            qr/Unknown group/,
            'rejects unknown group (as root)'
        );
    } else {
        # Not root - should require root
        like(
            dies { $runner4->_drop_privileges },
            qr/Must run as root/,
            'requires root for --group'
        );
    }
};

# Test 23: _drop_privileges method exists
subtest '_drop_privileges method exists' => sub {
    my $runner = PAGI::Runner->new;
    ok($runner->can('_drop_privileges'), '_drop_privileges method exists');
};

# Test 24: mode() method
subtest 'mode detection' => sub {
    # Test explicit env
    my $runner1 = PAGI::Runner->new(env => 'production');
    is($runner1->mode, 'production', 'explicit env wins');

    # Test PAGI_ENV
    local $ENV{PAGI_ENV} = 'development';
    my $runner2 = PAGI::Runner->new;
    is($runner2->mode, 'development', 'PAGI_ENV used when no explicit env');

    # With explicit env, PAGI_ENV is ignored
    my $runner3 = PAGI::Runner->new(env => 'none');
    is($runner3->mode, 'none', 'explicit env overrides PAGI_ENV');
};

# Test 25: -E flag parsing
subtest '-E flag parsing' => sub {
    my $runner = PAGI::Runner->new;
    $runner->parse_options('-E', 'production', 'app.pl');

    is($runner->{env}, 'production', '-E parsed');
    is($runner->mode, 'production', 'mode returns production');
};

# Test 26: server options pass-through
subtest 'runner keeps only its options' => sub {
    # Server options are now parsed in bin/pagi-server, not Runner
    # Runner should only see its own options
    my $runner = PAGI::Runner->new;
    $runner->parse_options(
        '-p', '8080',
        '-q',
        'app.pl',
    );

    is($runner->{port}, 8080, 'runner option -p parsed');
    is($runner->{quiet}, 1, 'runner option -q parsed');
    is(ref($runner->{server_options}), 'HASH', 'server_options is empty hashref');
};

# Test 27: --no-default-middleware flag
subtest '--no-default-middleware flag' => sub {
    my $runner = PAGI::Runner->new;
    $runner->parse_options('--no-default-middleware', 'app.pl');

    is($runner->{default_middleware}, 0, '--no-default-middleware sets to 0');
};

# Test 28: -e inline code
subtest '-e inline code' => sub {
    my $runner = PAGI::Runner->new;
    # Use a proper PAGI-style app signature
    my $code = 'sub { my ($scope, $receive, $send) = @_; $send->({type => "http.response.start", status => 200, headers => []}); $send->({type => "http.response.body", body => "Hello"}) }';
    $runner->parse_options('-e', $code);

    is($runner->{eval}, $code, '-e code stored');

    my $app = $runner->load_app;
    ok(ref $app eq 'CODE', '-e returns coderef');
    is($runner->{app_spec}, '-e', 'app_spec is -e');
};

# Test 29: -M module loading
subtest '-M module loading' => sub {
    my $runner = PAGI::Runner->new;
    $runner->parse_options('-M', 'PAGI::App::File', '-e', 'PAGI::App::File->new(root => ".")->to_app');

    is(scalar @{$runner->{modules}}, 1, 'one module stored');
    is($runner->{modules}[0], 'PAGI::App::File', 'correct module');

    my $app = $runner->load_app;
    ok(ref $app eq 'CODE', '-M/-e returns coderef');
};

# Test 30: cuddled -M option
subtest 'cuddled -M option' => sub {
    my $runner = PAGI::Runner->new;
    $runner->parse_options('-MPAGI::App::File', '-e', 'PAGI::App::File->new(root => ".")->to_app');

    is(scalar @{$runner->{modules}}, 1, 'cuddled module parsed');
    is($runner->{modules}[0], 'PAGI::App::File', 'correct cuddled module');
};

# Test 31: -e error handling
subtest '-e error handling' => sub {
    my $runner = PAGI::Runner->new;
    $runner->parse_options('-e', '{ not => "a coderef" }');

    like(
        dies { $runner->load_app },
        qr/must return a coderef/,
        '-e dies if not coderef'
    );
};

# Test 32: PAGI_ENV is exported after mode resolution
subtest 'PAGI_ENV exported after mode resolution' => sub {
    # Clear PAGI_ENV first
    local $ENV{PAGI_ENV};

    # Simulate what run() does: parse options then set PAGI_ENV
    my $runner = PAGI::Runner->new;
    $runner->parse_options('-E', 'production', 'app.pl');

    # This is what run() does after parse_options
    $ENV{PAGI_ENV} = $runner->mode;

    is($ENV{PAGI_ENV}, 'production', 'PAGI_ENV set to resolved mode');

    # Test with TTY auto-detection (no -E flag)
    delete $ENV{PAGI_ENV};
    my $runner2 = PAGI::Runner->new;
    $runner2->parse_options('app.pl');
    $ENV{PAGI_ENV} = $runner2->mode;

    # Should be development (if TTY) or production (if not)
    # In test environment, this depends on how tests are run
    ok(defined $ENV{PAGI_ENV}, 'PAGI_ENV set even with auto-detection');
    like($ENV{PAGI_ENV}, qr/^(development|production)$/, 'PAGI_ENV is valid mode');
};

done_testing;
