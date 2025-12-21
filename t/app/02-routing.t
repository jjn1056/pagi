#!/usr/bin/env perl

use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use IO::Async::Loop;

use lib 'lib';

use PAGI::App::URLMap;
use PAGI::App::Cascade;
use PAGI::App::NotFound;
use PAGI::App::Redirect;

my $loop = IO::Async::Loop->new;

sub run_async {
    my ($code) = @_;
    my $future = $code->();
    $loop->await($future);
}

# Helper app generators
sub make_response_app {
    my ($status, $body) = @_;

    return async sub  {
        my ($scope, $receive, $send) = @_;
        await $send->({ type => 'http.response.start', status => $status, headers => [] });
        await $send->({ type => 'http.response.body', body => $body, more => 0 });
    };
}

# =============================================================================
# Test: PAGI::App::URLMap
# =============================================================================

subtest 'App::URLMap routes by path prefix' => sub {

    subtest 'routes to mounted app' => sub {
        my $urlmap = PAGI::App::URLMap->new;
        $urlmap->mount('/api' => make_response_app(200, 'API'));
        $urlmap->mount('/web' => make_response_app(200, 'WEB'));
        my $app = $urlmap->to_app;

        my @sent;
        run_async(async sub {
            await $app->(
                { type => 'http', path => '/api/users' },
                async sub { { type => 'http.disconnect' } },
                async sub  {
        my ($event) = @_; push @sent, $event },
            );
        });

        is $sent[0]{status}, 200, 'routes to API';
        is $sent[1]{body}, 'API', 'API app responded';
    };

    subtest 'adjusts path for mounted app' => sub {
        my $received_path;
        my $inner = async sub  {
        my ($scope, $receive, $send) = @_;
            $received_path = $scope->{path};
            await $send->({ type => 'http.response.start', status => 200, headers => [] });
            await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
        };

        my $urlmap = PAGI::App::URLMap->new;
        $urlmap->mount('/api' => $inner);
        my $app = $urlmap->to_app;

        run_async(async sub {
            await $app->(
                { type => 'http', path => '/api/users/123' },
                async sub { { type => 'http.disconnect' } },
                async sub  {
        my ($event) = @_; },
            );
        });

        is $received_path, '/users/123', 'path adjusted (prefix removed)';
    };

    subtest 'returns 404 for unmatched path' => sub {
        my $urlmap = PAGI::App::URLMap->new;
        $urlmap->mount('/api' => make_response_app(200, 'API'));
        my $app = $urlmap->to_app;

        my @sent;
        run_async(async sub {
            await $app->(
                { type => 'http', path => '/unknown' },
                async sub { { type => 'http.disconnect' } },
                async sub  {
        my ($event) = @_; push @sent, $event },
            );
        });

        is $sent[0]{status}, 404, 'returns 404';
    };

    subtest 'longest prefix wins' => sub {
        my $urlmap = PAGI::App::URLMap->new;
        $urlmap->mount('/api' => make_response_app(200, 'API'));
        $urlmap->mount('/api/v2' => make_response_app(200, 'API-V2'));
        my $app = $urlmap->to_app;

        my @sent;
        run_async(async sub {
            await $app->(
                { type => 'http', path => '/api/v2/users' },
                async sub { { type => 'http.disconnect' } },
                async sub  {
        my ($event) = @_; push @sent, $event },
            );
        });

        is $sent[1]{body}, 'API-V2', 'longer prefix matched';
    };
};

# =============================================================================
# Test: PAGI::App::Cascade
# =============================================================================

subtest 'App::Cascade tries apps in sequence' => sub {

    subtest 'returns first non-404 response' => sub {
        my $cascade = PAGI::App::Cascade->new(
            apps => [
                make_response_app(404, 'Not Found'),
                make_response_app(200, 'Found'),
                make_response_app(200, 'Never Reached'),
            ],
        );
        my $app = $cascade->to_app;

        my @sent;
        run_async(async sub {
            await $app->(
                { type => 'http', path => '/test' },
                async sub { { type => 'http.disconnect' } },
                async sub  {
        my ($event) = @_; push @sent, $event },
            );
        });

        is $sent[0]{status}, 200, 'returns 200';
        is $sent[1]{body}, 'Found', 'correct app responded';
    };

    subtest 'returns 404 if all apps return 404' => sub {
        my $cascade = PAGI::App::Cascade->new(
            apps => [
                make_response_app(404, 'Not Found 1'),
                make_response_app(404, 'Not Found 2'),
            ],
        );
        my $app = $cascade->to_app;

        my @sent;
        run_async(async sub {
            await $app->(
                { type => 'http', path => '/test' },
                async sub { { type => 'http.disconnect' } },
                async sub  {
        my ($event) = @_; push @sent, $event },
            );
        });

        is $sent[0]{status}, 404, 'returns 404 when all fail';
    };

    subtest 'custom catch codes' => sub {
        my $cascade = PAGI::App::Cascade->new(
            apps => [
                make_response_app(403, 'Forbidden'),
                make_response_app(200, 'Success'),
            ],
            catch => [403, 404],
        );
        my $app = $cascade->to_app;

        my @sent;
        run_async(async sub {
            await $app->(
                { type => 'http', path => '/test' },
                async sub { { type => 'http.disconnect' } },
                async sub  {
        my ($event) = @_; push @sent, $event },
            );
        });

        is $sent[0]{status}, 200, 'catches 403 and tries next';
    };
};

# =============================================================================
# Test: PAGI::App::NotFound
# =============================================================================

subtest 'App::NotFound returns 404' => sub {

    subtest 'default 404 response' => sub {
        my $app = PAGI::App::NotFound->new->to_app;

        my @sent;
        run_async(async sub {
            await $app->(
                { type => 'http', path => '/anything' },
                async sub { { type => 'http.disconnect' } },
                async sub  {
        my ($event) = @_; push @sent, $event },
            );
        });

        is $sent[0]{status}, 404, 'returns 404';
        like $sent[1]{body}, qr/Not Found/i, 'default body';
    };

    subtest 'custom body' => sub {
        my $app = PAGI::App::NotFound->new(body => 'Custom 404')->to_app;

        my @sent;
        run_async(async sub {
            await $app->(
                { type => 'http', path => '/anything' },
                async sub { { type => 'http.disconnect' } },
                async sub  {
        my ($event) = @_; push @sent, $event },
            );
        });

        is $sent[1]{body}, 'Custom 404', 'custom body';
    };
};

# =============================================================================
# Test: PAGI::App::Redirect
# =============================================================================

subtest 'App::Redirect returns redirects' => sub {

    subtest 'default 302 redirect' => sub {
        my $app = PAGI::App::Redirect->new(to => '/new-location')->to_app;

        my @sent;
        run_async(async sub {
            await $app->(
                { type => 'http', path => '/old' },
                async sub { { type => 'http.disconnect' } },
                async sub  {
        my ($event) = @_; push @sent, $event },
            );
        });

        is $sent[0]{status}, 302, 'returns 302';
        ok((grep { $_->[0] eq 'location' && $_->[1] eq '/new-location' } @{$sent[0]{headers}}),
            'Location header set');
    };

    subtest '301 permanent redirect' => sub {
        my $app = PAGI::App::Redirect->new(to => '/new', status => 301)->to_app;

        my @sent;
        run_async(async sub {
            await $app->(
                { type => 'http', path => '/old' },
                async sub { { type => 'http.disconnect' } },
                async sub  {
        my ($event) = @_; push @sent, $event },
            );
        });

        is $sent[0]{status}, 301, 'returns 301';
    };

    subtest 'redirect with code' => sub {
        my $app = PAGI::App::Redirect->new(
            to => sub { "/prefix$_[0]->{path}" },
        )->to_app;

        my @sent;
        run_async(async sub {
            await $app->(
                { type => 'http', path => '/test' },
                async sub { { type => 'http.disconnect' } },
                async sub  {
        my ($event) = @_; push @sent, $event },
            );
        });

        ok((grep { $_->[0] eq 'location' && $_->[1] eq '/prefix/test' } @{$sent[0]{headers}}),
            'dynamic Location');
    };
};

done_testing;
