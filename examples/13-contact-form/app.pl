#!/usr/bin/env perl
use strict;
use warnings;

use Future::AsyncAwait;
use File::Basename qw(dirname);
use File::Spec;

use PAGI::Request;
use PAGI::Response;
use PAGI::App::File;

# Configure upload limits
PAGI::Request->configure(
    max_file_size   => 5 * 1024 * 1024,  # 5MB per file upload
    spool_threshold => 64 * 1024,
);

my $PUBLIC_DIR = File::Spec->catdir(dirname(__FILE__), 'public');
my $UPLOAD_DIR = File::Spec->catdir(dirname(__FILE__), 'uploads');

# Static file server for public directory
my $static_app = PAGI::App::File->new(root => $PUBLIC_DIR)->to_app;

# Allowed MIME types for attachments
my %ALLOWED_TYPES = (
    'application/pdf' => 'pdf',
    'image/jpeg'      => 'jpg',
    'image/png'       => 'png',
    'image/gif'       => 'gif',
    'text/plain'      => 'txt',
);

my $app = async sub {
    my ($scope, $receive, $send) = @_;

    return await _handle_lifespan($scope, $receive, $send)
        if $scope->{type} eq 'lifespan';

    die "Unsupported: $scope->{type}" unless $scope->{type} eq 'http';

    my $req = PAGI::Request->new($scope, $receive);
    my $path = $req->path;
    my $method = $req->method;

    # Route: POST /submit - handle form
    if ($method eq 'POST' && $path eq '/submit') {
        return await _handle_submit($req, $send);
    }

    # All other requests: serve static files from public/
    return await $static_app->($scope, $receive, $send);
};

async sub _handle_submit {
    my ($req, $send) = @_;

    my $form = await $req->form_params;
    my @errors;

    # Validate required fields
    my $name = $form->get('name') // '';
    my $email = $form->get('email') // '';
    my $message = $form->get('message') // '';
    my $subject = $form->get('subject') // 'general';
    my $subscribe = $form->get('subscribe') // '';

    push @errors, 'Name is required' unless length $name;
    push @errors, 'Email is required' unless length $email;
    push @errors, 'Invalid email format' unless $email =~ /@/;
    push @errors, 'Message is required' unless length $message;

    # Handle file upload
    my $attachment = await $req->upload('attachment');
    my $saved_file;

    if ($attachment && !$attachment->is_empty) {
        my $ct = $attachment->content_type;
        my $size = $attachment->size;

        # Validate type
        unless (exists $ALLOWED_TYPES{$ct}) {
            push @errors, "File type not allowed: $ct";
        }

        # Validate size (already enforced by Request, but double-check)
        if ($size > 5 * 1024 * 1024) {
            push @errors, "File too large (max 5MB)";
        }

        # Save file if valid
        unless (@errors) {
            my $ext = $ALLOWED_TYPES{$ct} // 'bin';
            my $safe_name = time() . '-' . int(rand(10000)) . ".$ext";
            my $dest = "$UPLOAD_DIR/$safe_name";

            my $save_ok = eval {
                $attachment->move_to($dest);
                1;
            };
            if ($save_ok) {
                $saved_file = $safe_name;
            } else {
                push @errors, "Failed to save file: $@";
            }
        }
    }

    my $res = PAGI::Response->new($req->raw, $send);

    # Return errors if any
    if (@errors) {
        return await $res->status(400)->json({
            success => 0,
            errors  => \@errors,
        });
    }

    # Success response
    return await $res->json({
        success => 1,
        message => 'Thank you for your message!',
        data    => {
            name      => $name,
            email     => $email,
            subject   => $subject,
            message   => substr($message, 0, 100) . (length($message) > 100 ? '...' : ''),
            subscribe => ($subscribe eq 'yes' ? 1 : 0),
            attachment => $saved_file,
        },
    });
}

async sub _handle_lifespan {
    my ($scope, $receive, $send) = @_;

    while (1) {
        my $event = await $receive->();
        if ($event->{type} eq 'lifespan.startup') {
            # Ensure upload directory exists
            mkdir $UPLOAD_DIR unless -d $UPLOAD_DIR;
            print STDERR "[lifespan] Contact form app started\n";
            print STDERR "[lifespan] Upload directory: $UPLOAD_DIR\n";
            await $send->({ type => 'lifespan.startup.complete' });
        }
        elsif ($event->{type} eq 'lifespan.shutdown') {
            print STDERR "[lifespan] Shutting down\n";
            await $send->({ type => 'lifespan.shutdown.complete' });
            last;
        }
    }
}

$app;

__END__

=head1 NAME

Contact Form Example - PAGI::Request Demo

=head1 SYNOPSIS

    pagi-server examples/13-contact-form/app.pl --port 5000

Then visit http://localhost:5000/

=head1 DESCRIPTION

Demonstrates PAGI::Request features:

=over

=item * Form parsing with validation

=item * File upload handling

=item * Content-type validation

=item * JSON responses

=back

=cut
