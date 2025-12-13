package ValiantFormsDemo::Service::Order;

use strict;
use warnings;
use experimental 'signatures';
use parent 'PAGI::Simple::Service::PerApp';

use ValiantFormsDemo::Model::Order;
use ValiantFormsDemo::Model::LineItem;

# =============================================================================
# ValiantFormsDemo::Service::Order - Order data operations
# =============================================================================
#
# This is a PerApp service (singleton) because:
# - The data is shared across all requests (in-memory storage)
# - The service is stateless (no per-request state)
#
# Usage:
#   my $orders = $c->service('Order');
#   my @all = $orders->all;
#   my $order = $orders->find($id);
#   my $new = $orders->create(\%data);
#   $orders->update($id, \%data);
#   $orders->delete($id);
#
# =============================================================================

# In-memory storage
my $next_id = 1;
my %orders = ();

# =============================================================================
# Public API
# =============================================================================

sub all ($self) {
    return sort { $a->id <=> $b->id } values %orders;
}

sub find ($self, $id) {
    return $orders{$id};
}

sub create ($self, $data) {
    my $order = ValiantFormsDemo::Model::Order->new(
        customer_name  => $data->{customer_name} // '',
        customer_email => $data->{customer_email} // '',
        notes          => $data->{notes} // '',
    );

    # Add line items
    $self->_add_line_items($order, $data->{line_items});

    return undef unless $order->validate->valid;

    $order->id($next_id++);
    $orders{$order->id} = $order;
    return $order;
}

sub update ($self, $id, $data) {
    my $order = $orders{$id} or return undef;

    $order->customer_name($data->{customer_name} // '');
    $order->customer_email($data->{customer_email} // '');
    $order->notes($data->{notes} // '');

    # Replace line items
    $order->line_items([]);
    $self->_add_line_items($order, $data->{line_items});

    return $order->validate->valid ? $order : undef;
}

sub delete ($self, $id) {
    return delete $orders{$id};
}

sub count ($self) {
    return scalar keys %orders;
}

# Build an order from data without saving (for form re-rendering on validation failure)
sub build ($self, $data = {}) {
    my $order = ValiantFormsDemo::Model::Order->new(
        customer_name  => $data->{customer_name} // '',
        customer_email => $data->{customer_email} // '',
        notes          => $data->{notes} // '',
    );
    $self->_add_line_items($order, $data->{line_items});
    return $order;
}

# Create a new blank order (for new order forms)
sub new_order ($self) {
    my $order = ValiantFormsDemo::Model::Order->new;
    $order->add_line_item();  # Start with one empty line item
    return $order;
}

# Create a new blank line item (for htmx partials)
sub new_line_item ($self) {
    return ValiantFormsDemo::Model::LineItem->new;
}

# Validate a single field (for inline validation)
sub validate_field ($self, $field, $value) {
    my $order = ValiantFormsDemo::Model::Order->new($field => $value);
    $order->validate;
    return $order->errors->messages_for($field);
}

# =============================================================================
# Private helpers
# =============================================================================

sub _add_line_items ($self, $order, $items) {
    return unless $items && ref($items) eq 'ARRAY';

    for my $item_data (@$items) {
        next unless $item_data && keys %$item_data;
        $order->add_line_item(
            product    => $item_data->{product} // '',
            quantity   => $item_data->{quantity} // 1,
            unit_price => $item_data->{unit_price} // 0,
        );
    }
}

1;
