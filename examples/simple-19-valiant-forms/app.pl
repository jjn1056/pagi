#!/usr/bin/env perl

# =============================================================================
# Valiant Forms Example with Nested Forms + htmx
#
# Demonstrates:
# - form_for with Valiant::HTML::FormBuilder
# - Nested forms with fields_for (Order -> LineItems)
# - htmx for dynamic form submission
# - htmx for adding/removing line items without page reload
# - Inline validation with htmx
# - Service layer for data operations
# - Structured params for Rails-style parameter handling
#
# Run with: pagi-server --app examples/simple-19-valiant-forms/app.pl
# =============================================================================

use strict;
use warnings;
use experimental 'signatures';
use Future::AsyncAwait;

use PAGI::Simple;

my $app = PAGI::Simple->new(
    name  => 'Valiant Forms Demo',
    share => 'htmx',
    views     => {
        directory => './templates',
        roles     => ['PAGI::Simple::View::Role::Valiant'],
        preamble  => 'use experimental "signatures";',
    },
);

# -----------------------------------------------------------------------------
# Routes
# -----------------------------------------------------------------------------

# Home - list orders
$app->get('/' => sub ($c) {
    my @orders = $c->service('Order')->all;
    $c->render('orders/index', orders => \@orders);
});

# New order form
$app->get('/orders/new' => sub ($c) {
    my $order = $c->service('Order')->new_order;
    $c->render('orders/new', order => $order);
});

# Create order
$app->post('/orders' => async sub ($c) {
    my $orders = $c->service('Order');

    # Use structured params for Rails-style strong parameters
    my $data = (await $c->structured_body)
        ->namespace('valiant_forms_demo_model_order')
        ->permitted(
            'customer_name', 'customer_email', 'notes',
            +{line_items => ['product', 'quantity', 'unit_price', '_destroy']}
        )
        ->skip('_destroy')
        ->to_hash;

    my $order = $orders->create($data);

    if ($order) {
        # htmx request - return success message
        if ($c->req->is_htmx) {
            $c->html(qq{
                <div class="alert alert-success" role="alert">
                    Order #@{[$order->id]} created successfully!
                    <a href="/" hx-boost="true">View all orders</a>
                </div>
            });
        } else {
            $c->redirect('/');
        }
    } else {
        # Validation failed - build order for form re-render
        my $invalid_order = $orders->build($data);
        $invalid_order->validate;

        # Re-render form with errors
        if ($c->req->is_htmx) {
            $c->render('orders/_form', order => $invalid_order);
        } else {
            $c->render('orders/new', order => $invalid_order);
        }
    }
});

# Edit order form
$app->get('/orders/:id/edit' => sub ($c) {
    my $id = $c->path_params->{id};
    my $orders = $c->service('Order');
    my $order = $orders->find($id);

    unless ($order) {
        $c->status(404);
        $c->html('<div class="alert alert-danger">Order not found</div>');
        return;
    }

    # Ensure at least one line item for editing
    $order->add_line_item() unless @{$order->line_items};

    $c->render('orders/edit', order => $order);
});

# Update order
$app->post('/orders/:id' => async sub ($c) {
    my $id = $c->path_params->{id};
    my $orders = $c->service('Order');
    my $order = $orders->find($id);

    unless ($order) {
        $c->status(404);
        $c->html('<div class="alert alert-danger">Order not found</div>');
        return;
    }

    # Use structured params for Rails-style strong parameters
    my $data = (await $c->structured_body)
        ->namespace('valiant_forms_demo_model_order')
        ->permitted(
            'customer_name', 'customer_email', 'notes',
            +{line_items => ['product', 'quantity', 'unit_price', '_destroy']}
        )
        ->skip('_destroy')
        ->to_hash;

    my $updated = $orders->update($id, $data);

    if ($updated) {
        # htmx request - return success message
        if ($c->req->is_htmx) {
            $c->html(qq{
                <div class="alert alert-success" role="alert">
                    Order #@{[$order->id]} updated successfully!
                    <a href="/" hx-boost="true">View all orders</a>
                </div>
            });
        } else {
            $c->redirect('/');
        }
    } else {
        # Re-render form with errors (order already has validation errors)
        if ($c->req->is_htmx) {
            $c->render('orders/_form', order => $order);
        } else {
            $c->render('orders/edit', order => $order);
        }
    }
});

# Delete order
$app->delete('/orders/:id' => sub ($c) {
    my $id = $c->path_params->{id};
    my $orders = $c->service('Order');
    my $order = $orders->find($id);

    unless ($order) {
        $c->status(404);
        $c->html('<div class="alert alert-danger">Order not found</div>');
        return;
    }

    $orders->delete($id);

    if ($c->req->is_htmx) {
        $c->hx_trigger('orderDeleted', message => "Order #$id deleted");

        # If no orders left, return empty state with OOB swap
        if ($orders->count == 0) {
            $c->html(qq{
                <div id="orders-list-area" hx-swap-oob="true">
                    <div class="alert alert-info">
                        No orders yet. <a href="/orders/new" hx-boost="true">Create your first order</a>!
                    </div>
                </div>
            });
        } else {
            # Return empty to just remove the row
            $c->html('');
        }
    } else {
        $c->redirect('/');
    }
});

# Add a new line item row (htmx partial)
$app->get('/orders/line_item' => sub ($c) {
    my $index = $c->req->query->get('index') // 0;
    my $item = $c->service('Order')->new_line_item;
    $c->render('orders/_line_item_fields', item => $item, index => $index);
});

# Validate a single field (htmx)
$app->post('/validate/order/:field' => async sub ($c) {
    my $field = $c->path_params->{field};
    my $params = await $c->params;
    # Valiant FormBuilder namespaces fields as valiant_forms_demo_model_order.*
    my $prefix = 'valiant_forms_demo_model_order';
    my $value = $params->get("$prefix.$field") // '';

    my @errors = $c->service('Order')->validate_field($field, $value);
    if (@errors) {
        $c->html(qq{<div class="invalid-feedback d-block">@{[join(', ', @errors)]}</div>});
    } else {
        $c->html(qq{<div class="valid-feedback d-block">Looks good!</div>});
    }
});

$app->to_app;
