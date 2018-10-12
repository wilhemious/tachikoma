#!/usr/bin/perl
# ----------------------------------------------------------------------
# Tachikoma::Jobs::DirCheck
# ----------------------------------------------------------------------
#
# $Id: DirCheck.pm 415 2008-12-24 21:08:33Z chris $
#

package Tachikoma::Jobs::DirCheck;
use strict;
use warnings;
use Tachikoma::Job;
use Tachikoma::Message qw(
    TYPE FROM TO ID STREAM TIMESTAMP PAYLOAD
    TM_BYTESTREAM TM_PERSIST TM_RESPONSE
);
use Digest::MD5;
use File::Path qw( remove_tree );
use parent qw( Tachikoma::Job );

# my $Separator   = chr(0);
my $Separator   = join( '', chr(30), ' -> ', chr(30) );
my %Dot_Include = map { $_ => 1 } qw(
    .htaccess
    .svn
);
my %Cache          = ();
my $Cache_Lifetime = 86400 * 3;
my $Scrub_Interval = 86400 / 3;
my $Last_Scrub     = 0;

sub fill {
    my $self    = shift;
    my $message = shift;
    return if ( not $message->type & TM_BYTESTREAM );
    my ( $relative, $stats ) = split( "\n", $message->payload, 2 );
    chomp($relative);
    die "ERROR: bad path: $relative"
        if ( $relative =~ m(^\.\.$|^\.\./|/\.\.(?=/)|/\.\.$) );
    my ( $prefix, $delete_threshold, $mode ) =
        split( ' ', $self->{arguments}, 3 );
    $mode ||= 'update';
    my $should_delete = ( $mode eq 'update' ) ? $delete_threshold : undef;
    $delete_threshold ||= 43200;
    my $my_path = join( '/', $prefix, $relative );
    $my_path =~ s(/+$)();
    my $message_to = $message->[FROM];
    $message_to =~ s(/DirStats:tee)();

    if ( $relative eq '.intent' ) {
        my $fh;
        my $payload = '';
        if ( open( $fh, '<', $my_path ) ) {
            $payload .= $_ while (<$fh>);
            close($fh);
        }
        else {
            $payload = "can't open $my_path: $!";
        }
        my $response = Tachikoma::Message->new;
        $response->[TYPE]    = TM_PERSIST | TM_RESPONSE;
        $response->[TO]      = $message_to;
        $response->[ID]      = $message->[ID];
        $response->[STREAM]  = $message->[STREAM];
        $response->[PAYLOAD] = $payload;
        return $self->SUPER::fill($response);
    }
    my %other = ();
    for my $line ( split( "\n", $stats ) ) {
        my ( $stat, $size, $perms, $last_modified, $digest, $entry ) =
            ( split( m(\s), $line, 6 ) );
        my $link;
        ( $entry, $link ) = split( $Separator, $entry, 2 )
            if ( $stat eq 'L' );
        $other{$entry} =
            [ $stat, $size, $perms, $last_modified, $digest, $link ];
    }
    my $dh;
    if ( not opendir( $dh, $my_path ) ) {
        if ( $! =~ m(No such file or directory|Not a directory) ) {
            if ( $mode eq 'update' and $! =~ m(Not a directory) ) {
                $self->stderr("removing $my_path");
                unlink($my_path)
                    or
                    $self->stderr( "ERROR: couldn't remove $my_path: ", $! );
            }
            for my $entry ( keys %other ) {
                my $their_path_entry = join( '/', $relative, $entry );
                my $response = Tachikoma::Message->new;
                $response->[TYPE] = TM_BYTESTREAM;
                $response->[TO]   = $message_to;
                $response->[PAYLOAD] =
                    join( '', 'update:', $their_path_entry, "\n" );
                $self->SUPER::fill($response);
            }
        }
        else {
            $self->stderr("ERROR: can't opendir $my_path: $!");
        }
        return $self->cancel($message);
    }
    my $recent  = $message->[TIMESTAMP] - $delete_threshold;
    my @entries = readdir($dh);
    closedir $dh;
    my %checked = ();
    while (@entries) {
        my $entry = shift(@entries);
        if ( $entry =~ m(^\.) and not $Dot_Include{$entry} ) {
            if ( $entry =~ m(^\.temp-\w{16}$) ) {
                my $my_path_entry = join( '/', $my_path, $entry );
                my @lstat = lstat($my_path_entry);
                next if ( not @lstat );
                my $last_modified = $lstat[9];
                if (    $mode eq 'update'
                    and $Tachikoma::Now - $last_modified > 3600 )
                {
                    $self->stderr(
                        "unlinking stale temp file: $my_path_entry");
                    unlink($my_path_entry)
                        or $self->stderr(
                        "ERROR: couldn't remove $my_path_entry: ", $! );
                }
            }
            next;
        }
        my $my_path_entry = join( '/', $my_path, $entry );
        my @lstat = cached_lstat($my_path_entry);
        next if ( not @lstat );

        # my $stat          = (-l _) ? 'L' : (-d _) ? 'D' : 'F';
        my $stat          = $lstat[-1];
        my $size          = ( $stat eq 'F' ) ? $lstat[7] : '-';
        my $perms         = sprintf( "%04o", $lstat[2] & 07777 );
        my $other_entry   = $other{$entry};
        my $their_stat    = $other_entry ? $other_entry->[0] : '';
        my $their_size    = $other_entry ? $other_entry->[1] : '-';
        my $their_perms   = $other_entry ? $other_entry->[2] : '';
        my $my_is_dir     = ( $stat eq 'D' ) ? 1 : 0;
        my $theirs_is_dir = ( $their_stat eq 'D' ) ? 1 : 0;
        my $last_modified = $lstat[9];
        my $digest        = '-';
        my $theirs_exists = exists $other{$entry};
        if ( not $theirs_exists or $my_is_dir != $theirs_is_dir ) {
            next if ( validate( $my_path_entry, $entry, \@entries ) );
            next if ( $last_modified > $recent );
            if ( not $should_delete ) {
                if ( not $theirs_exists ) {
                    $self->print_less_often( "WARNING: possible orphan: ",
                        $my_path_entry );
                }
                else {
                    $self->stderr("WARNING: type mismatch: $my_path_entry");
                }
                $checked{$entry} = 1;
                next;
            }
            $self->stderr("removing $my_path_entry");
            if ($my_is_dir) {
                my $errors = [];
                remove_tree( $my_path_entry, { error => \$errors } );
                if (@$errors) {
                    $self->stderr( "ERROR: couldn't remove $my_path_entry: ",
                        values %{ $errors->[0] } );
                }
            }
            else {
                unlink($my_path_entry)
                    or
                    $self->stderr( "ERROR: couldn't remove $my_path_entry: ",
                    $! );
            }
        }
        elsif ( $their_stat eq $stat
            and ( $theirs_is_dir or $their_size eq $size ) )
        {
            if ( $stat eq 'L' ) {
                my $my_link    = readlink($my_path_entry);
                my $their_link = $other_entry->[5];
                if ( $my_link ne $their_link ) {
                    validate( $my_path_entry, $entry, \@entries );
                }
                else {
                    $checked{$entry} = 1;
                }
                next;
            }
            if ( $last_modified > $other_entry->[3] ) {
                if ( $mode eq 'update' and $stat ne 'D' ) {
                    validate( $my_path_entry, $entry, \@entries );
                }
                else {
                    $checked{$entry} = 1;
                }
                next;
            }
            if ( $their_perms ne $perms ) {
                validate( $my_path_entry, $entry, \@entries );
                next;
            }
            if ( $mode eq 'update' and $last_modified < $other_entry->[3] ) {
                validate( $my_path_entry, $entry, \@entries );
                next;
            }
            my $their_digest = $other_entry->[4];
            if ( $stat eq 'F' and $their_digest ne '-' ) {
                my $md5 = Digest::MD5->new;
                open( my $fh, '<', $my_path_entry )
                    or die "ERROR: can't open $my_path_entry: $!";
                $md5->addfile($fh);
                $digest = $md5->hexdigest;
                close($fh);
            }
            next if ( $their_digest ne $digest );
            $checked{$entry} = 1;
        }
        else {
            validate( $my_path_entry, $entry, \@entries );
        }
    }
    for my $entry ( keys %other ) {
        next if ( $checked{$entry} );
        my $their_path_entry = (
            $relative
            ? join( '/', $relative, $entry )
            : $entry
        );
        my $response = Tachikoma::Message->new;
        $response->[TYPE]    = TM_BYTESTREAM;
        $response->[TO]      = $message_to;
        $response->[PAYLOAD] = join( '', 'update:', $their_path_entry, "\n" );
        $self->SUPER::fill($response);
    }
    scrub();
    return $self->cancel($message);
}

sub cached_lstat {
    my $path  = shift;
    my $lstat = $Cache{$path};
    if ( not $lstat or not @$lstat ) {
        $lstat = [ lstat($path) ];
        push( @$lstat,
            $Tachikoma::Now, ( -l _ ) ? 'L' : ( -d _ ) ? 'D' : 'F' )
            if (@$lstat);
        $Cache{$path} = $lstat
            if ( not @$lstat
            or $Tachikoma::Now - $lstat->[9] < $Cache_Lifetime );
    }
    return @$lstat;
}

sub validate {
    my $path      = shift;
    my $entry     = shift;
    my $entries   = shift;
    my $timestamp = $Cache{$path} ? $Cache{$path}->[-2] : undef;
    my $rv        = undef;
    if ( $timestamp and $timestamp < $Tachikoma::Now ) {
        delete $Cache{$path};
        unshift( @$entries, $entry );
        $rv = 1;
    }
    return $rv;
}

sub scrub {
    if ( $Tachikoma::Now - $Last_Scrub > $Scrub_Interval ) {
        for my $path ( keys %Cache ) {
            delete $Cache{$path}
                if (
                $Tachikoma::Now - $Cache{$path}->[9] >= $Cache_Lifetime );
        }
        $Last_Scrub = $Tachikoma::Now;
    }
    return;
}

1;