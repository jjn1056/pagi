#!/usr/bin/env perl
use strict;
use warnings;
use Getopt::Long;
use File::Find;
use File::Slurp qw(read_file write_file);

my $dry_run = 0;
my @paths;

GetOptions(
    'dry-run' => \$dry_run,
) or die "Usage: $0 [--dry-run] [paths...]\n";

@paths = @ARGV;
@paths = qw(lib examples t) unless @paths;

my $files_modified = 0;
my $subs_converted = 0;

# Process each path
for my $path (@paths) {
    if (-f $path) {
        process_file($path);
    } elsif (-d $path) {
        find(sub {
            return unless -f $_ && /\.(pm|pl|t)$/;
            process_file($File::Find::name);
        }, $path);
    } else {
        warn "Path does not exist: $path\n";
    }
}

print "\n";
print "Summary:\n";
print "  Files modified: $files_modified\n";
print "  Subroutines converted: $subs_converted\n";
print "  Mode: " . ($dry_run ? "DRY RUN (no changes written)" : "LIVE") . "\n";

sub process_file {
    my ($file) = @_;

    my $content = eval { read_file($file, { binmode => ':utf8' }) };
    if ($@) {
        warn "Error reading file $file: $@";
        return;
    }
    my $original = $content;
    my $file_subs_converted = 0;

    # Pattern 1-4: Named subs with signatures (including async)
    # Match: sub name (...) { or async sub name (...) {
    $content =~ s{
        ^([ \t]*)(async[ \t]+)?sub[ \t]+(\w+)[ \t]*\(([^)]*)\)[ \t]*\{
    }{
        my $indent = $1;
        my $async = $2 || '';
        my $name = $3;
        my $params = $4;

        my ($converted, $defaults) = convert_params($params);
        $file_subs_converted++;

        my $result = "${indent}${async}sub $name \{\n${indent}    my $converted = \@_;\n";
        if ($defaults) {
            $result .= $defaults;
        }
        $result .= "${indent}";
        $result;
    }gmxe;

    # Pattern 5: Anonymous async subs (return async sub (...) {)
    # This pattern needs special handling for indentation
    $content =~ s{
        (return[ \t]+async[ \t]+sub[ \t]*)\(([^)]*)\)([ \t]*\{)
    }{
        my $prefix = $1;
        my $params = $2;
        my $suffix = $3;

        my ($converted, $defaults) = convert_params($params, '        ');
        $file_subs_converted++;

        # Extract indentation from the line
        my $line_indent = '';
        if ($prefix =~ /^(\s*)/) {
            $line_indent = $1;
        }

        my $result = "${prefix}${suffix}\n${line_indent}        my $converted = \@_;";
        if ($defaults) {
            $result .= "\n" . $defaults;
        }
        $result;
    }gmxe;

    # Additional pattern: Other anonymous async subs not in return statements
    # Match: = async sub (...) { or other contexts
    $content =~ s{
        (=[ \t]+async[ \t]+sub[ \t]*)\(([^)]*)\)([ \t]*\{)
    }{
        my $prefix = $1;
        my $params = $2;
        my $suffix = $3;

        my ($converted, $defaults) = convert_params($params, '        ');
        $file_subs_converted++;

        my $result = "${prefix}${suffix}\n        my $converted = \@_;";
        if ($defaults) {
            $result .= "\n" . $defaults;
        }
        $result;
    }gmxe;

    # Pattern: intercept_send style - my $wrapped_send = $self->intercept_send($send, async sub ($event) {
    $content =~ s{
        (,[ \t]+async[ \t]+sub[ \t]*)\(([^)]*)\)([ \t]*\{)
    }{
        my $prefix = $1;
        my $params = $2;
        my $suffix = $3;

        my ($converted, $defaults) = convert_params($params, '        ');
        $file_subs_converted++;

        my $result = "${prefix}${suffix}\n        my $converted = \@_;";
        if ($defaults) {
            $result .= "\n" . $defaults;
        }
        $result;
    }gmxe;

    # Pattern 6: Remove 'use experimental' lines
    my $experimental_removed = 0;
    $content =~ s{^use\s+experimental\s+['"]signatures['"];\n}{}gm && $experimental_removed++;

    if ($content ne $original) {
        $files_modified++;
        $subs_converted += $file_subs_converted;

        if ($dry_run) {
            print "Would modify: $file ($file_subs_converted subs";
            print ", removed 'use experimental'" if $experimental_removed;
            print ")\n";
        } else {
            eval { write_file($file, { binmode => ':utf8' }, $content) };
            if ($@) {
                warn "Error writing file $file: $@";
                return;
            }
            print "Modified: $file ($file_subs_converted subs";
            print ", removed 'use experimental'" if $experimental_removed;
            print ")\n";
        }
    }
}

sub convert_params {
    my ($params, $indent) = @_;
    $indent //= '    ';

    # Clean up whitespace
    $params =~ s/^\s+//;
    $params =~ s/\s+$//;

    # Split parameters by comma, but preserve hash/array slurping
    my @parts;
    my $current = '';
    my $depth = 0;

    for my $char (split //, $params) {
        if ($char eq '(' || $char eq '{' || $char eq '[') {
            $depth++;
            $current .= $char;
        } elsif ($char eq ')' || $char eq '}' || $char eq ']') {
            $depth--;
            $current .= $char;
        } elsif ($char eq ',' && $depth == 0) {
            push @parts, $current;
            $current = '';
        } else {
            $current .= $char;
        }
    }
    push @parts, $current if $current;

    # Process each parameter
    my @converted;
    my @defaults_code;
    for my $part (@parts) {
        $part =~ s/^\s+//;
        $part =~ s/\s+$//;

        # Handle default values
        if ($part =~ /^([\$\@\%]\w+)\s*=\s*(.+)$/) {
            my ($var, $default) = ($1, $2);
            push @converted, $var;
            # Add default assignment using //= operator for scalars
            if ($var =~ /^\$/) {
                push @defaults_code, "${indent}$var //= $default;";
            }
            # For arrays/hashes, would need different handling, but they're rare with defaults
        } else {
            push @converted, $part;
        }
    }

    my $params_str = '(' . join(', ', @converted) . ')';
    my $defaults_str = @defaults_code ? join("\n", @defaults_code) . "\n" : '';

    return wantarray ? ($params_str, $defaults_str) : $params_str;
}
