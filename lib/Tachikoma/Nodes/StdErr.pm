#!/usr/bin/perl
# ----------------------------------------------------------------------
# Tachikoma::Nodes::StdErr
# ----------------------------------------------------------------------
#
# $Id: StdErr.pm 12579 2012-01-11 04:10:56Z chris $
#

package Tachikoma::Nodes::StdErr;
use strict;
use warnings;
use Tachikoma::Node;
use Tachikoma::Message qw( TM_BYTESTREAM );
use parent qw( Tachikoma::Node );

use version; our $VERSION = qv('v2.0.280');

sub help {
    my $self = shift;
    return <<'EOF';
make_node StdErr <node name>
EOF
}

sub fill {
    my $self    = shift;
    my $message = shift;
    $self->stderr( $message->payload )
        if ( $message->type & TM_BYTESTREAM );
    return;
}

1;
