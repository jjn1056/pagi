package ValiantFormsDemo::Model::LineItem;

use Moo;
use Valiant::Validations;
use experimental 'signatures';

has 'id'          => (is => 'rw');
has 'product'     => (is => 'rw', default => '');
has 'quantity'    => (is => 'rw', default => 1);
has 'unit_price'  => (is => 'rw', default => 0);
has '_destroy'    => (is => 'rw', default => 0);

validates product    => (presence => 1, length => { minimum => 2 });
validates quantity   => (numericality => { greater_than => 0, only_integer => 1 });
validates unit_price => (numericality => { greater_than_or_equal_to => 0 });

sub total ($self) {
    return ($self->quantity // 0) * ($self->unit_price // 0);
}

sub marked_for_destruction ($self) {
    return $self->_destroy ? 1 : 0;
}

1;
