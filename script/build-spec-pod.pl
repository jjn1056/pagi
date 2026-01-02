#!/usr/bin/env perl
#
# Converts PAGI specification markdown files to POD for CPAN distribution.
#
# Uses App::sdview for conversion (replaces Markdown::Pod for better output):
# - Proper =item * bullet points (not =item -)
# - Better code block handling
# - =for highlighter language markers
#
# Run manually: perl script/build-spec-pod.pl
# Or automatically via dzil build (configured in dist.ini)
#

use strict;
use warnings;
use File::Spec;
use File::Path qw(make_path);
use File::Temp qw(tempfile);
use IPC::Open3;
use Symbol 'gensym';

use Getopt::Long;

my $SPEC_DIR = 'docs/specs';
my $OUTPUT_BASE = 'lib';  # Default, can be overridden

GetOptions('output-dir=s' => \$OUTPUT_BASE);

my $OUTPUT_DIR = "$OUTPUT_BASE/PAGI/Spec";

# Spec files to convert (in order for combined doc)
my @SPEC_FILES = qw(
    main.mkdn
    www.mkdn
    lifespan.mkdn
    tls.mkdn
);

# Mapping from .mkdn filenames to POD module names
my %MKDN_TO_POD = (
    'main.mkdn'     => 'PAGI::Spec',
    'www.mkdn'      => 'PAGI::Spec::Www',
    'lifespan.mkdn' => 'PAGI::Spec::Lifespan',
    'tls.mkdn'      => 'PAGI::Spec::Tls',
);

# Known Perl modules that should be L<> links on metacpan
my @LINKABLE_MODULES = qw(
    Future
    Future::AsyncAwait
    Future::IO
    Future::Queue
    IO::Async
    IO::Async::Loop
    IO::Async::Stream
    IO::Async::SSL
    IO::Socket::SSL
    Plack
    PSGI
    Mojolicious
    Dancer2
    AnyEvent
    Coro
    Test2::V0
);

# Check for sdview
my $SDVIEW = `which sdview 2>/dev/null`;
chomp $SDVIEW;
unless ($SDVIEW && -x $SDVIEW) {
    die "App::sdview required. Install with: cpanm App::sdview\n";
}

# Convert .mkdn internal links to POD L<> links
sub convert_mkdn_links {
    my ($pod) = @_;

    # Convert links like L<HTTP, WebSocket and SSE|www.mkdn> to L<HTTP, WebSocket and SSE|PAGI::Spec::Www>
    for my $mkdn (keys %MKDN_TO_POD) {
        my $pod_module = $MKDN_TO_POD{$mkdn};
        # Handle L<text|file.mkdn> format
        $pod =~ s/L<([^|>]+)\|\Q$mkdn\E>/L<$1|$pod_module>/g;
        # Handle plain L<file.mkdn> format
        $pod =~ s/L<\Q$mkdn\E>/L<$pod_module>/g;
    }

    return $pod;
}

# Convert known module names from C<> to L<> for metacpan links
sub convert_module_links {
    my ($pod) = @_;

    for my $module (@LINKABLE_MODULES) {
        # Convert C<Module::Name> to L<Module::Name>
        # Be careful not to convert things like C<< $module->method >>
        # Only convert if the entire C<> content is a module name
        $pod =~ s/C<\Q$module\E>/L<$module>/g;
    }

    return $pod;
}

# Clean up whitespace issues in POD
sub clean_pod_whitespace {
    my ($pod) = @_;

    # Remove trailing whitespace from lines
    $pod =~ s/[ \t]+$//mg;

    # Remove lines that are only whitespace within paragraphs
    # (replace whitespace-only lines with empty lines)
    $pod =~ s/^[ \t]+$//mg;

    # Collapse multiple blank lines into two (paragraph separator)
    $pod =~ s/\n{3,}/\n\n/g;

    return $pod;
}

# Run sdview to convert markdown to POD
sub markdown_to_pod {
    my ($markdown_file) = @_;

    # sdview requires .md extension, so create a temp file if needed
    my $input_file = $markdown_file;
    my $temp_file;
    if ($markdown_file !~ /\.md$/) {
        (undef, $temp_file) = tempfile(SUFFIX => '.md', UNLINK => 0);
        $input_file = $temp_file;

        # Copy content to temp file with proper encoding
        open my $in, '<:encoding(UTF-8)', $markdown_file
            or die "Cannot read $markdown_file: $!\n";
        my $content = do { local $/; <$in> };
        close $in;

        open my $out, '>:encoding(UTF-8)', $temp_file
            or die "Cannot write temp file $temp_file: $!\n";
        print $out $content;
        close $out;
    }

    # Run sdview with Pod output (suppress Wide character warnings to stderr)
    my $cmd = "$SDVIEW '$input_file' -t Pod -O table_style=none 2>/dev/null";
    my $pod = `$cmd`;

    # Clean up temp file
    unlink $temp_file if $temp_file;

    # sdview may exit non-zero due to Wide character warnings but still produce valid output
    # Only fail if we got no output at all
    if (!defined $pod || $pod eq '') {
        die "sdview produced no output for $markdown_file\n";
    }

    return $pod;
}

# Ensure output directories exist
make_path("$OUTPUT_BASE/PAGI") unless -d "$OUTPUT_BASE/PAGI";
make_path($OUTPUT_DIR) unless -d $OUTPUT_DIR;

for my $file (@SPEC_FILES) {
    my $input_path = File::Spec->catfile($SPEC_DIR, $file);
    next unless -f $input_path;

    print "Converting: $file\n";

    # Convert to POD using sdview
    my $pod = eval { markdown_to_pod($input_path) };
    if ($@ || !defined $pod || $pod eq '') {
        warn "Warning: Failed to convert $file: $@\n";
        next;
    }

    # Post-process the POD
    $pod = convert_mkdn_links($pod);
    $pod = convert_module_links($pod);
    $pod = clean_pod_whitespace($pod);

    # Determine output filename
    my $basename = $file;
    $basename =~ s/\.mkdn$//;
    $basename = ucfirst($basename);  # Main.pod, Www.pod, etc.

    # Build module name
    my $module_name = "PAGI::Spec::$basename";
    $module_name = 'PAGI::Spec' if $basename eq 'Main';

    my $output_file = $basename eq 'Main'
        ? File::Spec->catfile($OUTPUT_BASE, 'PAGI', 'Spec.pod')
        : File::Spec->catfile($OUTPUT_DIR, "$basename.pod");

    # Build header (must come before sdview output to ensure =encoding is first)
    my $header = <<"POD_HEADER";
=encoding utf8

=head1 NAME

$module_name - PAGI Specification Documentation

=head1 NOTICE

This documentation is auto-generated from the PAGI specification
markdown files. For the authoritative source, see:

L<https://github.com/jjn1056/PAGI/tree/main/docs/specs>

POD_HEADER

    # Write POD file
    open my $out, '>:encoding(UTF-8)', $output_file
        or die "Cannot write $output_file: $!\n";
    print $out $header;
    print $out $pod;
    close $out;

    print "Generated: $output_file\n";
}

print "Done!\n";

