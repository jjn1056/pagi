#!/usr/bin/env perl
#
# Converts PAGI specification markdown files to POD for CPAN distribution.
#
# Run manually: perl script/build-spec-pod.pl
# Or automatically via dzil build (configured in dist.ini)
#

use strict;
use warnings;
use File::Spec;
use File::Path qw(make_path);
use File::Basename qw(dirname);

# Check for Markdown::Pod
eval { require Markdown::Pod; 1 }
    or die "Markdown::Pod required. Install with: cpanm Markdown::Pod\n";

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

# Convert markdown-style links to POD L<> links
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

# Ensure output directories exist
make_path("$OUTPUT_BASE/PAGI") unless -d "$OUTPUT_BASE/PAGI";
make_path($OUTPUT_DIR) unless -d $OUTPUT_DIR;

# Convert markdown to POD
my $m2p = Markdown::Pod->new;

for my $file (@SPEC_FILES) {
    my $input_path = File::Spec->catfile($SPEC_DIR, $file);
    next unless -f $input_path;

    # Read markdown
    open my $fh, '<:encoding(UTF-8)', $input_path
        or die "Cannot read $input_path: $!\n";
    my $markdown = do { local $/; <$fh> };
    close $fh;

    # Convert to POD (suppress warnings from Markdown::Pod internals)
    my $pod;
    {
        local $SIG{__WARN__} = sub { };  # Suppress warnings during conversion
        eval {
            $pod = $m2p->markdown_to_pod(markdown => $markdown);
        };
        if ($@ || !defined $pod) {
            warn "Warning: Failed to convert $file: $@\n";
            next;
        }
    }

    # Ensure pod is at least an empty string
    $pod //= '';

    # Convert .mkdn links to POD L<> links
    $pod = convert_mkdn_links($pod);

    # Determine output filename
    my $basename = $file;
    $basename =~ s/\.mkdn$//;
    $basename = ucfirst($basename);  # Main.pod, Www.pod, etc.

    # Add POD header
    my $module_name = "PAGI::Spec::$basename";
    $module_name = 'PAGI::Spec' if $basename eq 'Main';  # Main spec is just PAGI::Spec

    my $output_file = $basename eq 'Main'
        ? File::Spec->catfile($OUTPUT_BASE, 'PAGI', 'Spec.pod')
        : File::Spec->catfile($OUTPUT_DIR, "$basename.pod");

    my $header = <<"POD_HEADER";
=encoding utf8

=head1 NAME

$module_name - PAGI Specification Documentation

=head1 NOTICE

This documentation is auto-generated from the PAGI specification
markdown files. For the authoritative source, see:

L<https://github.com/jjn1056/PAGI/tree/main/docs/specs>

=cut

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
