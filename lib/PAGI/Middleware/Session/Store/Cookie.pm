package PAGI::Middleware::Session::Store::Cookie;

use strict;
use warnings;
use parent 'PAGI::Middleware::Session::Store';
use Future;
use JSON::MaybeXS qw(encode_json decode_json);
use MIME::Base64 qw(encode_base64 decode_base64);
use Digest::SHA qw(sha256);

=head1 NAME

PAGI::Middleware::Session::Store::Cookie - Encrypted client-side session store

=head1 SYNOPSIS

    use PAGI::Middleware::Session::Store::Cookie;

    my $store = PAGI::Middleware::Session::Store::Cookie->new(
        secret => 'at-least-32-bytes-of-secret-key!',
    );

=head1 DESCRIPTION

Stores session data encrypted in the client cookie itself using AES-256-GCM
(authenticated encryption). No server-side storage is needed.

The C<set()> method returns the encrypted blob (not the session ID).
The C<get()> method accepts the encrypted blob and returns the decoded
session data, or undef if decryption/verification fails.

B<Limitations:> Cookie size is limited to ~4KB. Large sessions will fail.
Session revocation requires server-side state (e.g., a blocklist).

B<Note:> This module will be extracted to a separate CPAN distribution
in a future release.

=cut

sub new {
    my ($class, %args) = @_;
    die "Store::Cookie requires 'secret'" unless $args{secret};

    my $self = $class->SUPER::new(%args);

    # Derive a 32-byte key from the secret via SHA-256
    $self->{_key} = sha256($self->{secret});

    return $self;
}

=head1 METHODS

=head2 get

    my $data = await $store->get($encrypted_blob);

Decrypts and decodes the blob. Returns a Future resolving to the session
hashref, or undef if the blob is invalid, tampered, or cannot be decoded.

=cut

sub get {
    my ($self, $blob) = @_;

    return Future->done(undef) unless defined $blob && length $blob;

    my $data = eval { $self->_decrypt($blob) };
    return Future->done($data);
}

=head2 set

    my $transport_value = await $store->set($id, $data);

Encrypts the session data and returns a Future resolving to the encrypted
blob. This blob is what gets passed to C<State::inject()> for storage
in the response cookie. Nothing is stored server-side.

=cut

sub set {
    my ($self, $id, $data) = @_;

    my $blob = $self->_encrypt($data);
    return Future->done($blob);
}

=head2 delete

    await $store->delete($id);

No-op for cookie stores (client manages cookie lifetime).
Returns a Future resolving to 1.

=cut

sub delete {
    my ($self, $id) = @_;
    return Future->done(1);
}

sub _encrypt {
    my ($self, $data) = @_;

    require Crypt::AuthEnc::GCM;

    my $json = encode_json($data);

    # Generate random 12-byte IV (standard for AES-GCM)
    my $iv = _random_bytes(12);

    my $gcm = Crypt::AuthEnc::GCM->new('AES', $self->{_key}, $iv);
    my $ciphertext = $gcm->encrypt_add($json);
    my $tag = $gcm->encrypt_done;

    # Pack: iv (12) + tag (16) + ciphertext
    my $packed = $iv . $tag . $ciphertext;
    return encode_base64($packed, '');
}

sub _decrypt {
    my ($self, $blob) = @_;

    require Crypt::AuthEnc::GCM;

    my $packed = decode_base64($blob);
    return undef unless defined $packed && length($packed) > 28;

    # Unpack: iv (12) + tag (16) + ciphertext
    my $iv         = substr($packed, 0, 12);
    my $tag        = substr($packed, 12, 16);
    my $ciphertext = substr($packed, 28);

    my $gcm = Crypt::AuthEnc::GCM->new('AES', $self->{_key}, $iv);
    my $json = $gcm->decrypt_add($ciphertext);
    my $valid = $gcm->decrypt_done($tag);

    return undef unless $valid;

    return decode_json($json);
}

sub _random_bytes {
    my ($n) = @_;

    # Use /dev/urandom if available, fall back to Perl's rand
    if (open my $fh, '<:raw', '/dev/urandom') {
        my $bytes;
        read($fh, $bytes, $n) == $n or die "Short read from /dev/urandom";
        close $fh;
        return $bytes;
    }

    return join('', map { chr(int(rand(256))) } 1 .. $n);
}

1;

__END__

=head1 SECURITY

Session data is encrypted with AES-256-GCM, which provides both
confidentiality (data cannot be read) and authenticity (data cannot
be tampered with). The encryption key is derived from the C<secret>
via SHA-256.

Each encryption uses a random 12-byte IV, so the same session data
produces different ciphertext each time.

=head1 SEE ALSO

L<PAGI::Middleware::Session::Store> - Base store interface

L<PAGI::Middleware::Session> - Session management middleware

=cut
