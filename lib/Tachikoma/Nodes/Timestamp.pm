#!/usr/bin/perl
# ----------------------------------------------------------------------
# Tachikoma::Nodes::Timestamp
# ----------------------------------------------------------------------
#
# $Id: Timestamp.pm 17140 2013-07-17 06:12:25Z chris $
#

package Tachikoma::Nodes::Timestamp;
use strict;
use warnings;
use Tachikoma::Node;
use Tachikoma::Message qw( TYPE PAYLOAD TM_BYTESTREAM );
use parent qw( Tachikoma::Node );

sub new {
    my $class = shift;
    my $self  = $class->SUPER::new;
    $self->{position} = 'prefix';
    $self->{offset}   = 0;
    bless $self, $class;
    return $self;
}

sub help {
    my $self = shift;
    return <<'EOF';
make_node Timestamp <node name> [ "prefix" | "suffix" ] [ <offset> ]
EOF
}

sub arguments {
    my $self = shift;
    if (@_) {
        my $arguments = shift;
        $arguments = ( $arguments =~ m(^(.*)$) )[0];
        $self->{arguments} = $arguments;
        my ( $position, $offset ) = split( ' ', $arguments, 2 );
        $self->{position} = $position // 'prefix';
        $self->{offset}   = $offset // 0;
    }
    return $self->{arguments};
}

sub fill {
    my $self    = shift;
    my $message = shift;
    return $self->SUPER::fill($message)
        if ( not $message->[TYPE] & TM_BYTESTREAM );
    my $copy   = bless( [@$message], ref($message) );
    my $offset = $self->{offset};
    my $out    = '';
    if ( $self->{position} eq 'prefix' ) {
        for my $line ( split( m(^), $message->[PAYLOAD] ) ) {
            chomp($line);
            $out .= join( '', $Tachikoma::Now + $offset, ' ', $line, "\n" );
        }
    }
    else {
        for my $line ( split( m(^), $message->[PAYLOAD] ) ) {
            chomp($line);
            $out .= join( '', $line, ' ', $Tachikoma::Now + $offset, "\n" );
        }
    }
    $copy->[PAYLOAD] = $out;
    return $self->SUPER::fill($copy);
}

sub position {
    my $self = shift;
    if (@_) {
        $self->{position} = shift;
    }
    return $self->{position};
}

sub offset {
    my $self = shift;
    if (@_) {
        $self->{offset} = shift;
    }
    return $self->{offset};
}

1;