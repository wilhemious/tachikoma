#!/usr/bin/perl
# ----------------------------------------------------------------------
# Tachikoma::Nodes::IndexByStream
# ----------------------------------------------------------------------
#
# $Id: IndexByStream.pm 3511 2009-10-08 00:18:42Z chris $
#

package Tachikoma::Nodes::IndexByStream;
use strict;
use warnings;
use Tachikoma::Node;
use Tachikoma::Message qw(
    TYPE FROM TO ID STREAM TIMESTAMP PAYLOAD
    TM_BYTESTREAM TM_PERSIST TM_RESPONSE TM_ERROR
);
use parent qw( Tachikoma::Node );

sub fill {
    my $self    = shift;
    my $message = shift;
    $self->{counter}++;
    return
        if ( $message->[TYPE] & TM_RESPONSE
        or $message->[TYPE] & TM_ERROR );
    my $partition = ( $message->[FROM] =~ m{(\d+)$} )[0];
    my $offset    = ( split m{:}, $message->[ID], 2 )[0] // 0;
    my $response  = Tachikoma::Message->new;
    $response->[TYPE]      = TM_BYTESTREAM | TM_PERSIST;
    $response->[FROM]      = $message->[FROM];
    $response->[TO]        = $self->{owner} || $message->[TO];
    $response->[ID]        = $message->[ID];
    $response->[STREAM]    = $message->[STREAM];
    $response->[TIMESTAMP] = $message->[TIMESTAMP];
    $response->[PAYLOAD] =
        length( $message->[PAYLOAD] )
        ? "$partition:$offset\n"
        : '';
    return $self->{sink}->fill($response);
}

1;