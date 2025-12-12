package MyApp::Service::Order;

use strict;
use warnings;
use experimental 'signatures';
use parent 'PAGI::Simple::Service::PerApp';

use MyApp::Model::Order;
use MyApp::Model::LineItem;

# =============================================================================
# MyApp::Service::Order - Order data operations
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
    my $order = MyApp::Model::Order->new(
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
