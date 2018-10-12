#!/usr/bin/perl
# ----------------------------------------------------------------------
# Tachikoma::Nodes::ClientConnector
# ----------------------------------------------------------------------
#
# $Id: ClientConnector.pm 3511 2009-10-08 00:18:42Z chris $
#

package Tachikoma::Nodes::ClientConnector;
use strict;
use warnings;
use Tachikoma::Node;
use Tachikoma::Message qw( TYPE FROM TM_INFO TM_EOF );
use parent qw( Tachikoma::Node );

use version; our $VERSION = qv('v2.0.280');

sub help {
    my $self = shift;
    return <<'EOF';
make_node ClientConnector <node name> <tee or load balancer> [ <path> ]
register <listen port> <client connector> <event>
    possible events: connected, authenticated
EOF
}

sub fill {
    my $self    = shift;
    my $message = shift;
    my $type    = $message->[TYPE];
    my ( $name, $path ) = split q{ }, $self->{arguments}, 2;
    my $owner = join q{/}, grep defined, $message->[FROM], $path;
    $self->{counter}++;
    if ( $type & TM_INFO ) {
        my $okay = eval {
            $self->connect_node( $name, $owner );
            return 1;
        };
        $self->stderr( $@ // 'ERROR: connect_node: unknown error' )
            if ( not $okay );
        return 1;
    }
    elsif ( $type & TM_EOF ) {
        my $okay = eval {
            $self->disconnect_node( $name, $owner );
            return 1;
        };
        $self->stderr( $@ // 'ERROR: disconnect_node: unknown error' )
            if ( not $okay );
        return 1;
    }
    return $self->SUPER::fill($message);
}

1;