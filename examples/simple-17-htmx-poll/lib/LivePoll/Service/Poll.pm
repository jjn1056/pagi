package LivePoll::Service::Poll;

use strict;
use warnings;
use experimental 'signatures';
use parent 'PAGI::Simple::Service::PerApp';

# =============================================================================
# LivePoll::Service::Poll - Poll data operations
# =============================================================================
#
# This service demonstrates PAGI::Simple's service system by encapsulating
# all poll-related data operations.
#
# This is a PerApp service (singleton) because:
# - The data is shared across all requests (in-memory storage)
# - The service is stateless (no per-request state)
# - No request context is needed for operations
#
# Usage:
#   my $polls = $c->service('Poll');
#   my @all = $polls->all;
#   my $poll = $polls->find($id);
#   my $new_poll = $polls->create($question, \@options);
#   $polls->vote($id, $option);
#   $polls->delete($id);
#
# =============================================================================

# In-memory storage
my $next_id = 1;
my %polls = ();

# Seed with sample data on first load
sub _seed_data {
    return if %polls;  # Already seeded

    _do_create('What is your favorite programming language?',
               ['Perl', 'Python', 'JavaScript', 'Rust']);
    _do_create('Best web framework approach?',
               ['Full-stack', 'Micro-framework', 'Static + API']);
}

# Internal create without service instance
sub _do_create ($question, $options) {
    my $id = $next_id++;
    $polls{$id} = {
        id       => $id,
        question => $question,
        options  => { map { $_ => 0 } @$options },
        created  => time(),
    };
    return $polls{$id};
}

# Seed on module load
_seed_data();

# =============================================================================
# Public API
# =============================================================================

sub all ($self) {
    return sort { $b->{created} <=> $a->{created} } values %polls;
}

sub find ($self, $id) {
    return $polls{$id};
}

sub create ($self, $question, $options) {
    return _do_create($question, $options);
}

sub vote ($self, $id, $option) {
    my $poll = $polls{$id} or return;
    $poll->{options}{$option}++ if exists $poll->{options}{$option};
    return $poll;
}

sub delete ($self, $id) {
    return delete $polls{$id};
}

# Helper to get the PubSub channel name for a poll
sub channel_name ($self, $id) {
    return "poll:$id";
}

1;
