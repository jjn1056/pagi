package PAGI::Simple::StructuredParams;

use strict;
use warnings;
use experimental 'signatures';

use Hash::MultiValue;

# Step 1: Core class with chainable API foundation

sub new ($class, %args) {
    # Accept Hash::MultiValue object for D1 duplicate handling
    # Also accept params => {} for test convenience (converted internally)
    my $mv = $args{multi_value};
    if (!$mv && $args{params}) {
        # Test convenience: convert hashref to Hash::MultiValue
        my @pairs = map { $_ => $args{params}{$_} } keys %{$args{params}};
        $mv = Hash::MultiValue->new(@pairs);
    }
    $mv //= Hash::MultiValue->new();

    my $self = bless {
        _source_type     => $args{source_type} // 'body',
        _multi_value     => $mv,  # Hash::MultiValue for get() vs get_all()
        _namespace       => undef,
        _permitted_rules => [],
        _skip_fields     => {},
        _required_fields => [],  # For Step 7
        _context         => $args{context},  # For build() access to models
    }, $class;
    return $self;
}

sub namespace ($self, $ns = undef) {
    if (defined $ns) {
        $self->{_namespace} = $ns;
        return $self;
    }
    return $self->{_namespace};
}

sub permitted ($self, @rules) {
    push @{$self->{_permitted_rules}}, @rules;
    return $self;
}

sub skip ($self, @fields) {
    $self->{_skip_fields}{$_} = 1 for @fields;
    return $self;
}

sub to_hash ($self) {
    my $filtered_mv = $self->_apply_namespace();  # Returns Hash::MultiValue

    # Store for D1 handling in _apply_permitted() (Step 3)
    $self->{_filtered_mv} = $filtered_mv;

    my $nested = $self->_build_nested($filtered_mv);
    # Whitelisting comes in Step 3
    return $nested;
}

# Step 2: Dot-notation parsing

# Parse a key into path segments
# "person.name" => ['person', 'name']
# "items[0].name" => ['items', '[0]', 'name']
# "items[].name" => ['items', '[]', 'name']
sub _parse_key ($self, $key) {
    my @parts;
    # Match either: non-dot/non-bracket sequences OR bracket notation (including empty [])
    while ($key =~ /([^\.\[]+|\[\d*\])/g) {
        push @parts, $1;
    }
    return @parts;
}

# Filter keys by namespace prefix, return new Hash::MultiValue
sub _apply_namespace ($self) {
    my $mv = $self->{_multi_value};
    my $ns = $self->{_namespace};

    # Build a NEW Hash::MultiValue with namespace stripped from keys
    # This preserves ALL values (including duplicates) for D1 handling later
    my @pairs;
    my $prefix = defined $ns && length $ns ? "$ns." : '';
    my $prefix_len = length $prefix;

    # Use each() to iterate through all key-value pairs exactly once
    $mv->each(sub {
        my ($key, $value) = @_;
        if (!$prefix_len || index($key, $prefix) == 0) {
            my $new_key = $prefix_len ? substr($key, $prefix_len) : $key;
            push @pairs, $new_key, $value;
        }
    });

    # Return new Hash::MultiValue (not hashref!) to preserve duplicates
    return Hash::MultiValue->new(@pairs);
}

# Build nested structure from flat Hash::MultiValue
sub _build_nested ($self, $mv) {
    my %result;

    # Track auto-index counters per array path for D2 empty bracket handling
    my %auto_index;

    # Get unique keys (Hash::MultiValue->keys returns duplicates)
    my %seen;
    my @unique_keys = grep { !$seen{$_}++ } $mv->keys;

    # First pass: find all explicit indices to set initial auto_index values
    for my $key (sort @unique_keys) {
        my @parts = $self->_parse_key($key);
        my $array_path = '';

        for my $part (@parts) {
            if ($part =~ /^\[(\d+)\]$/) {
                my $idx = $1;
                # Update auto_index to be at least idx+1
                $auto_index{$array_path} = $idx + 1
                    if !defined $auto_index{$array_path} || $auto_index{$array_path} <= $idx;
            } elsif ($part ne '[]' && $part !~ /^\[\d*\]$/) {
                $array_path .= ($array_path ? '.' : '') . $part;
            }
        }
    }

    # Second pass: process all key-value pairs (using unique keys)
    # For keys with empty brackets, we need to process each value separately
    # For other keys, use get() which returns last value (D1 scalar handling)
    for my $key (sort @unique_keys) {
        my @parts = $self->_parse_key($key);
        next unless @parts;

        # Check if this key contains empty brackets
        my $has_empty_bracket = grep { $_ eq '[]' } @parts;

        if ($has_empty_bracket) {
            # Process each value separately for empty bracket keys
            my @values = $mv->get_all($key);
            for my $value (@values) {
                my @resolved = $self->_resolve_empty_brackets(\@parts, \%auto_index);
                $self->_set_nested_value(\%result, \@resolved, $value);
            }
        } else {
            # No empty brackets - use last value (D1 scalar handling)
            my $value = $mv->get($key);
            $self->_set_nested_value(\%result, \@parts, $value);
        }
    }

    return \%result;
}

# Resolve empty brackets to actual indices, updating auto_index
sub _resolve_empty_brackets ($self, $parts, $auto_index) {
    my @resolved;
    my $array_path = '';

    for my $part (@$parts) {
        if ($part eq '[]') {
            # D2: Empty bracket - assign next available index
            $auto_index->{$array_path} //= 0;
            my $next_idx = $auto_index->{$array_path}++;
            push @resolved, "[$next_idx]";
        } else {
            push @resolved, $part;

            # Track array path for auto-indexing (skip bracket parts)
            if ($part !~ /^\[\d*\]$/) {
                $array_path .= ($array_path ? '.' : '') . $part;
            }
        }
    }

    return @resolved;
}

# Set a value in a nested structure given path parts
sub _set_nested_value ($self, $root, $parts, $value) {
    my $current = $root;

    for my $i (0 .. $#$parts) {
        my $part = $parts->[$i];
        my $is_last = ($i == $#$parts);

        # Check what the NEXT part is to determine container type
        my $next_part = $is_last ? undef : $parts->[$i + 1];
        my $next_is_array = defined $next_part && $next_part =~ /^\[\d+\]$/;

        if ($part =~ /^\[(\d+)\]$/) {
            # Array index
            my $idx = $1;

            if ($is_last) {
                $current->[$idx] = $value;
            } else {
                # Initialize next container if needed
                $current->[$idx] //= $next_is_array ? [] : {};
                $current = $current->[$idx];
            }
        } else {
            # Hash key
            if ($is_last) {
                $current->{$part} = $value;
            } else {
                # Initialize next container if needed
                $current->{$part} //= $next_is_array ? [] : {};
                $current = $current->{$part};
            }
        }
    }
}

1;
