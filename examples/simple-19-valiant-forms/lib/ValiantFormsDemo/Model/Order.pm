package ValiantFormsDemo::Model::Order;

use Moo;
use Valiant::Validations;
use experimental 'signatures';
use ValiantFormsDemo::Model::LineItem;

has 'id'            => (is => 'rw');
has 'customer_name' => (is => 'rw', default => '');
has 'customer_email'=> (is => 'rw', default => '');
has 'notes'         => (is => 'rw', default => '');
has 'line_items'    => (
    is => 'rw',
    default => sub { [] },
);

validates customer_name  => (presence => 1, length => { minimum => 2, maximum => 100 });
validates customer_email => (presence => 1, format => { match => qr/^[^@]+\@[^@]+$/, message => 'must be a valid email' });

# Required for Valiant nested forms
sub accept_nested_for { ['line_items'] }

# For fields_for iteration
sub build_line_item ($self) {
    return ValiantFormsDemo::Model::LineItem->new;
}

sub total ($self) {
    my $total = 0;
    for my $item (@{$self->line_items // []}) {
        next if $item->marked_for_destruction;
        $total += $item->total;
    }
    return $total;
}

sub add_line_item ($self, %attrs) {
    push @{$self->line_items}, ValiantFormsDemo::Model::LineItem->new(%attrs);
}

# Simulate persistence check
sub persisted ($self) {
    return defined $self->id && length $self->id;
}

1;
