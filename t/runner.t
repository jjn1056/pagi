use strict;
use warnings;
use Test2::V0;
use IO::Async::Loop;
use Net::Async::HTTP;
use Future::AsyncAwait;
use FindBin;
use File::Temp qw(tempdir);
use File::Spec;

use lib "$FindBin::Bin/../lib";
use PAGI::Runner;

# Test 1: Basic construction
subtest 'constructor with defaults' => sub {
    my $runner = PAGI::Runner->new;

    is($runner->{host}, '127.0.0.1', 'default host');
    is($runner->{port}, 5000, 'default port');
    is($runner->{workers}, 1, 'default workers');
    is($runner->{quiet}, 0, 'default quiet');
    ok(!defined $runner->{app}, 'no app initially');
};

# Test 2: Constructor with options
subtest 'constructor with options' => sub {
    my $runner = PAGI::Runner->new(
        host    => '0.0.0.0',
        port    => 8080,
        workers => 4,
        quiet   => 1,
    );

    is($runner->{host}, '0.0.0.0', 'custom host');
    is($runner->{port}, 8080, 'custom port');
    is($runner->{workers}, 4, 'custom workers');
    is($runner->{quiet}, 1, 'custom quiet');
};

# Test 3: Parse CLI options
subtest 'parse CLI options' => sub {
    my $runner = PAGI::Runner->new;
    my @remaining = $runner->parse_options(
        '-p', '8080',
        '-w', '4',
        '-h', '0.0.0.0',
        '-q',
        'PAGI::App::Directory',
        'root=/tmp',
    );

    is($runner->{port}, 8080, 'port parsed');
    is($runner->{workers}, 4, 'workers parsed');
    is($runner->{host}, '0.0.0.0', 'host parsed');
    is($runner->{quiet}, 1, 'quiet parsed');
    is(scalar @remaining, 2, 'two args remain');
    is($remaining[0], 'PAGI::App::Directory', 'app spec remains');
    is($remaining[1], 'root=/tmp', 'app arg remains');
};

# Test 4: Parse long CLI options
subtest 'parse long CLI options' => sub {
    my $runner = PAGI::Runner->new;
    my @remaining = $runner->parse_options(
        '--port', '9000',
        '--workers', '2',
        '--host', '192.168.1.1',
        '--quiet',
        '--loop', 'EV',
        'app.pl',
    );

    is($runner->{port}, 9000, 'port parsed');
    is($runner->{workers}, 2, 'workers parsed');
    is($runner->{host}, '192.168.1.1', 'host parsed');
    is($runner->{quiet}, 1, 'quiet parsed');
    is($runner->{loop}, 'EV', 'loop parsed');
    is($remaining[0], 'app.pl', 'app file remains');
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
    my $app_path = "$FindBin::Bin/../examples/01-hello-http/app.pl";

    my $app = $runner->load_app($app_path);

    ok(ref $app eq 'CODE', 'loaded app is coderef');
    is($runner->{app}, $app, 'app stored in runner');
    is($runner->{app_spec}, File::Spec->rel2abs($app_path), 'app_spec stored (absolute)');
};

# Test 10: Load app from module
subtest 'load app from module' => sub {
    my $runner = PAGI::Runner->new;
    my $app = $runner->load_app('PAGI::App::Directory', root => '.');

    ok(ref $app eq 'CODE', 'loaded app is coderef');
    is($runner->{app}, $app, 'app stored in runner');
    is($runner->{app_spec}, 'PAGI::App::Directory', 'app_spec stored');
    is($runner->{app_args}{root}, '.', 'app_args stored');
};

# Test 11: Default app (no arguments)
subtest 'default app loads Directory' => sub {
    my $runner = PAGI::Runner->new;
    my $app = $runner->load_app();

    ok(ref $app eq 'CODE', 'default app is coderef');
    is($runner->{app_spec}, 'PAGI::App::Directory', 'default is Directory');
    is($runner->{app_args}{root}, '.', 'default root is current dir');
};

# Test 12: Error on missing file
subtest 'error on missing file' => sub {
    my $runner = PAGI::Runner->new;

    like(
        dies { $runner->load_app('nonexistent_file_12345.pl') },
        qr/not found/i,
        'dies on missing file'
    );
};

# Test 13: Error on invalid module
subtest 'error on invalid module' => sub {
    my $runner = PAGI::Runner->new;

    like(
        dies { $runner->load_app('PAGI::App::NonExistent12345') },
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

    like(
        dies { $runner->load_app($bad_app) },
        qr/must return a coderef/i,
        'dies on non-coderef'
    );
};

# Test 15: prepare_server creates PAGI::Server
subtest 'prepare_server creates server' => sub {
    my $runner = PAGI::Runner->new(port => 0, quiet => 1);
    $runner->load_app('PAGI::App::Directory', root => '.');

    my $server = $runner->prepare_server;

    ok($server->isa('PAGI::Server'), 'returns PAGI::Server');
};

# Test 16: prepare_server dies without app
subtest 'prepare_server dies without app' => sub {
    my $runner = PAGI::Runner->new;

    like(
        dies { $runner->prepare_server },
        qr/No app loaded/i,
        'dies without app'
    );
};

# Test 17: Integration test - server responds to requests
subtest 'integration: server responds to requests' => sub {
    my $loop = IO::Async::Loop->new;

    my $runner = PAGI::Runner->new(port => 0, quiet => 1);
    $runner->load_app("$FindBin::Bin/../examples/01-hello-http/app.pl");
    my $server = $runner->prepare_server;

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
    $runner->load_app('PAGI::App::File', root => $tmpdir);
    my $server = $runner->prepare_server;

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

# Test 19: SSL options validation
subtest 'SSL options validation' => sub {
    my $runner = PAGI::Runner->new(ssl_cert => '/nonexistent/cert.pem');
    $runner->load_app('PAGI::App::Directory', root => '.');

    like(
        dies { $runner->prepare_server },
        qr/--ssl-cert and --ssl-key must be specified together/,
        'dies without both SSL options'
    );
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
    my @remaining = $runner->parse_options(
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

done_testing;
