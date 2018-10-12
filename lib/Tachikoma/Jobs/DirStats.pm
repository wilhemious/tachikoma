#!/usr/bin/perl
# ----------------------------------------------------------------------
# Tachikoma::Jobs::DirStats
# ----------------------------------------------------------------------
#
# $Id: DirStats.pm 415 2008-12-24 21:08:33Z chris $
#

package Tachikoma::Jobs::DirStats;
use strict;
use warnings;
use Tachikoma::Job;
use Tachikoma::Message qw(
    TYPE TO STREAM PAYLOAD
    TM_BYTESTREAM TM_PERSIST TM_RESPONSE TM_EOF
);
use Digest::MD5;
use Time::HiRes;
use vars qw( @EXPORT_OK );
use parent qw( Exporter Tachikoma::Job );
@EXPORT_OK = qw( stat_directory );

my $Router_Timeout    = 900;
my $Default_Max_Files = 256;
my $Default_Port      = 5600;
# my $Separator         = chr(0);
my $Separator         = join( '', chr(30), ' -> ', chr(30) );
my %Dot_Include       = map { $_ => 1 } qw(
    .htaccess
    .svn
);
my %SVN_Include = map { $_ => 1 } qw(
    entries
    wc.db
);

sub initialize_graph {
    my $self = shift;
    my ( $prefix, $target_settings, $max_files, $pedantic ) =
        ( split( ' ', $self->arguments, 4 ) );
    my ( $host, $port ) = split( ':', $target_settings, 2 );
    $prefix ||= '';
    $prefix =~ s(^'|'$)()g;
    $host      ||= 'localhost';
    $port      ||= $Default_Port;
    $max_files ||= $Default_Max_Files;
    $self->prefix($prefix);
    $self->target_host($host);
    $self->target_port($port);
    $self->max_files($max_files);
    $self->pedantic($pedantic);
    $self->connector->sink($self);
    $self->sink( $self->router );
    return;
}

sub fill {
    my $self    = shift;
    my $message = shift;
    return if ( not $message->type & TM_BYTESTREAM );
    my ( $path, $withsums ) = split( ' ', $message->payload, 3 );
    chomp($path);
    $path =~ s(^'|'$)()g;
    $path =~ s(/+$)();
    my $prefix = $self->prefix;

    if ( $path ne $prefix and $path !~ m(^$prefix/) ) {
        $self->stderr( "ERROR: bad path: $path from ", $message->from );
        return $self->cancel($message);
    }
    $self->send_stats( $_, $withsums ) for ( glob($path) );
    return $self->SUPER::fill($message);
}

sub send_stats {
    my $self     = shift;
    my $path     = shift;
    my $withsums = shift;
    my $target   = $self->target;

    # stat clients
    my $start     = Time::HiRes::time;
    my %unique    = ();
    my $count     = 0;
    my $finishing = undef;
    my $upper     = $self->max_files;
    my $lower     = $upper / 2;
    $target->callback(
        sub {
            my $message = shift;
            my $type    = $message->[TYPE];
            if ( $type & TM_BYTESTREAM ) {
                $unique{ $message->[PAYLOAD] } = undef;
            }
            elsif ( $type & TM_RESPONSE ) {
                $count--;
            }
            elsif ( $type & TM_EOF ) {
                die "ERROR: premature EOF\n";
            }
            else {
                die "ERROR: unexpected response\n";
            }
            return if ( $count <= $lower and not $finishing );
            return $count > 0 ? 'wait' : undef;
        }
    );
    my $total = $self->explore_path( $path, $withsums, \$count );
    $finishing = $count;
    $target->drain if ($finishing);

    # $self->stderr(sprintf(
    #     "sent %d stats in %.2f seconds",
    #     $total, Time::HiRes::time - $start
    # ));

    # send updates
    # $start      = Time::HiRes::time;
    my @updates = sort keys %unique;
    $total = @updates;
    return if ( not $total );
    $target->callback(
        sub {
            my $message = shift;
            my $type    = $message->[TYPE];
            if ( $type & TM_RESPONSE ) {
                my $path = ( split( ':', $message->[STREAM], 2 ) )[1];
                $count--;
            }
            elsif ( $type & TM_EOF ) {
                die "ERROR: premature EOF\n";
            }
            else {
                die "ERROR: unexpected response\n";
            }
            return if ( @updates and $count < $lower );
            return $count > 0 ? 'wait' : undef;
        }
    );
    my $prefix = $self->{prefix};
    while (@updates) {
        my $update = shift(@updates);
        if ($update) {
            my $relative = ( split( ':', $update, 2 ) )[1];
            $self->send_update(
                join( '', 'update:', $prefix, '/', $relative ) );
            $count++;
        }
        $target->drain if ( $count >= $upper );
    }
    $target->drain if ($count);
    $self->stderr(
        sprintf( "$total broadcasts under $path in %.2f seconds",
            Time::HiRes::time - $start )
    );
    return;
}

sub explore_path {
    my $self     = shift;
    my $path     = shift;
    my $withsums = shift;
    my $count    = shift;
    my $total    = 0;
    my $prefix   = $self->{prefix};
    my $target   = $self->{target};
    my $pedantic = $self->{pedantic};
    my ( $out, $directories );
    eval {
        ( $out, $directories ) =
            stat_directory( $prefix, $path, $withsums, $pedantic );
    };

    if ($@) {
        if ( $@ =~ m(can't open) ) {
            return 0;
        }
        else {
            die $@;
        }
    }
    my $message = Tachikoma::Message->new;
    $message->[TYPE]    = TM_BYTESTREAM | TM_PERSIST;
    $message->[TO]      = 'DirStats:tee';
    $message->[STREAM]  = $path;
    $message->[PAYLOAD] = join( '', @$out );
    $target->fill($message);
    $$count++;
    $total++;
    $target->drain if ( $$count >= $self->{max_files} );
    $total += $self->explore_path( $_, $withsums, $count )
        for (@$directories);
    return $total;
}

sub send_update {
    my $self   = shift;
    my $update = shift;
    my $stream = $update;
    chomp($stream);
    my $message = Tachikoma::Message->new;
    $message->[TYPE]    = TM_BYTESTREAM | TM_PERSIST;
    $message->[TO]      = 'FileController';
    $message->[STREAM]  = $stream;
    $message->[PAYLOAD] = $update;
    $self->{target}->fill($message);
    return;
}

sub stat_directory {
    my $prefix   = shift;
    my $path     = shift;
    my $withsums = shift;
    my $pedantic = shift;
    my $relative = undef;
    my $is_svn   = ( $path =~ m(/.svn$) );
    if ( $path eq $prefix ) {
        $relative = '';
    }
    elsif ( $path =~ m(^$prefix/(.*)$) ) {
        $relative = $1;
    }
    else {
        die "ERROR: bad path: $path";
    }
    opendir( my $dh, $path ) or die "ERROR: can't opendir $path: $!";
    my @entries = readdir($dh);
    closedir $dh;
    my @out = ( join( '', $relative, "\n" ) );
    my @directories = ();
    for my $entry (@entries) {
        next
            if ( ( $entry =~ m(^\.) and not $Dot_Include{$entry} )
            or ( $is_svn and not $pedantic and not $SVN_Include{$entry} ) );
        if ( $entry =~ m([\r\n]) ) {
            $entry =~ s(\n)(\\n)g;
            $entry =~ s(\r)(\\r)g;
            print STDERR "LMAO: $path/$entry\n";
            next;
        }
        my $path_entry = join( '/', $path, $entry );
        my @lstat = lstat($path_entry);
        next if ( not @lstat );
        my $stat = ( -l _ ) ? 'L' : ( -d _ ) ? 'D' : 'F';
        my $size = ( $stat eq 'F' ) ? $lstat[7] : '-';
        my $perms         = sprintf( '%04o', $lstat[2] & 07777 );
        my $last_modified = $lstat[9];
        my $digest        = '-';

        if ( $withsums and $stat eq 'F' ) {
            my $md5 = Digest::MD5->new;
            open( my $fh, '<', $path_entry )
                or die "ERROR: can't open $path_entry: $!";
            $md5->addfile($fh);
            $digest = $md5->hexdigest;
            close($fh);
        }
        $entry = join( '', $entry, $Separator, readlink($path_entry) )
            if ( $stat eq 'L' );
        push(
            @out,
            join(
                ' ', $stat, $size, $perms, $last_modified, $digest, $entry
                )
                . "\n"
        );
        push( @directories, $path_entry ) if ( $stat eq 'D' );
    }
    return ( \@out, \@directories );
}

sub prefix {
    my $self = shift;
    if (@_) {
        $self->{prefix} = shift;
    }
    return $self->{prefix};
}

sub target {
    my $self = shift;
    if (@_) {
        $self->{target} = shift;
    }
    if ( not defined $self->{target} ) {
        $self->{target} =
            Tachikoma->inet_client( $self->{target_host},
            $self->{target_port} );
        $self->{target}->timeout($Router_Timeout);
    }
    return $self->{target};
}

sub target_host {
    my $self = shift;
    if (@_) {
        $self->{target_host} = shift;
    }
    return $self->{target_host};
}

sub target_port {
    my $self = shift;
    if (@_) {
        $self->{target_port} = shift;
    }
    return $self->{target_port};
}

sub max_files {
    my $self = shift;
    if (@_) {
        $self->{max_files} = shift;
    }
    return $self->{max_files};
}

sub pedantic {
    my $self = shift;
    if (@_) {
        $self->{pedantic} = shift;
    }
    return $self->{pedantic};
}

1;