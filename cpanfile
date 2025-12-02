# PAGI::Server dependencies
# Install with: cpanm --installdeps .

requires 'perl', '5.032';

# Core async framework
requires 'IO::Async', '0.802';
requires 'Future', '0.50';
requires 'Future::AsyncAwait', '0.66';

# HTTP parsing
requires 'HTTP::Parser::XS', '0.17';

# WebSocket support
requires 'Protocol::WebSocket', '0.26';

# TLS support
requires 'IO::Async::SSL', '0.25';
requires 'IO::Socket::SSL', '2.074';

# Utilities
requires 'URI::Escape', '5.09';
requires 'Hash::MultiValue', '0.16';
requires 'JSON::MaybeXS', '1.004003';

# Testing
on 'test' => sub {
    requires 'Test2::V0', '0.000159';
    requires 'Test::Future::IO::Impl', '0.14';
    requires 'Net::Async::HTTP', '0.49';
    requires 'Net::Async::WebSocket::Client', '0.14';
};

# Development
on 'develop' => sub {
    requires 'Dist::Zilla', '6.030';
    requires 'Dist::Zilla::Plugin::MetaJSON';
    requires 'Dist::Zilla::Plugin::MetaResources';
    requires 'Dist::Zilla::Plugin::MetaNoIndex';
    requires 'Dist::Zilla::Plugin::Prereqs::FromCPANfile';
};
