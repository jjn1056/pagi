package MyApp::Service::UserProfile;

use strict;
use warnings;
use experimental 'signatures';
use parent 'PAGI::Simple::Service::PerRequest';
use Future::AsyncAwait;

# =============================================================================
# User Profile Service (PerRequest Scope)
#
# Cached per request - $c->service('UserProfile') returns the same instance
# within a single request, but different instances across requests.
# Uses async methods to simulate fetching user data.
# =============================================================================

# Simulated user data (in real app, this would be a database)
my %users = (
    1 => { name => 'Alice', email => 'alice@example.com', role => 'admin' },
    2 => { name => 'Bob', email => 'bob@example.com', role => 'user' },
    3 => { name => 'Carol', email => 'carol@example.com', role => 'moderator' },
);

my %preferences = (
    1 => { theme => 'dark', notifications => 1, language => 'en' },
    2 => { theme => 'light', notifications => 0, language => 'es' },
    3 => { theme => 'auto', notifications => 1, language => 'fr' },
);

# Track loaded users within this request (demonstrates PerRequest caching benefit)
sub new ($class, %args) {
    my $self = $class->SUPER::new(%args);
    $self->{_loaded_users} = {};
    return $self;
}

# Async method - fetches user data
async sub get_user ($self, $user_id) {
    # In a real app, this would be an async database query:
    # my $user = await $db->query("SELECT * FROM users WHERE id = ?", $user_id);

    # Cache within this request to avoid duplicate fetches
    unless (exists $self->{_loaded_users}{$user_id}) {
        my $data = $users{$user_id} // { name => 'Unknown', email => '', role => 'guest' };
        $self->{_loaded_users}{$user_id} = {
            id => $user_id,
            %$data,
            loaded_at => time(),
        };
    }

    return $self->{_loaded_users}{$user_id};
}

# Another async method
async sub get_preferences ($self, $user_id) {
    # This could be a separate async database call
    my $prefs = $preferences{$user_id} // { theme => 'light', notifications => 1, language => 'en' };

    return {
        user_id => $user_id,
        %$prefs,
    };
}

# Async method combining data
async sub get_full_profile ($self, $user_id) {
    my $user = await $self->get_user($user_id);
    my $prefs = await $self->get_preferences($user_id);

    return {
        %$user,
        preferences => $prefs,
    };
}

1;
