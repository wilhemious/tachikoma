#!/usr/bin/perl
# ----------------------------------------------------------------------
# Tachikoma::Nodes::Index
# ----------------------------------------------------------------------
#
# $Id: Index.pm 31247 2017-11-06 05:42:49Z chris $
#

package Tachikoma::Nodes::Index;
use strict;
use warnings;
use Tachikoma::Nodes::Table;
use Tachikoma::Nodes::ConsumerBroker;
use Tachikoma::Message qw(
    TYPE FROM TO ID STREAM PAYLOAD
    TM_BYTESTREAM TM_STORABLE TM_INFO
);
use Digest::MD5 qw( md5 );
use Getopt::Long qw( GetOptionsFromString );
use parent qw( Tachikoma::Nodes::Table );

use version; our $VERSION = 'v2.0.197';

my $Default_Num_Partitions = 1;
my $Default_Window_Size    = 900;
my $Default_Num_Buckets    = 4;
my $Default_Limit          = 0;

sub help {
    my $self = shift;
    return <<'EOF';
make_node Index <node name> --num_partitions=<int> \
                            --window_size=<int>    \
                            --num_buckets=<int>    \
                            --limit=<int>
EOF
}

sub arguments {
    my $self = shift;
    if (@_) {
        my $arguments = shift;
        my ( $num_partitions, $window_size, $num_buckets, $limit );
        my ( $r, $argv ) = GetOptionsFromString(
            $arguments,
            'num_partitions=i' => \$num_partitions,
            'window_size=i'    => \$window_size,
            'num_buckets=i'    => \$num_buckets,
            'limit=i'          => \$limit,
        );
        die "ERROR: invalid option\n" if ( not $r );
        $self->{arguments}      = $arguments;
        $self->{caches}         = [];
        $self->{num_partitions} = $num_partitions // $Default_Num_Partitions;
        $self->{window_size}    = $window_size // $Default_Window_Size;
        $self->{num_buckets}    = $num_buckets // $Default_Num_Buckets;
        $self->{limit}          = $limit || $Default_Limit;
        $self->{next_window}    = undef;

        if ( $self->{window_size} ) {
            my $time = time;
            my ( $sec, $min, $hour ) = localtime $time;
            my $delay = $self->{window_size};
            $delay -= $hour * 3600 % $delay if ( $delay > 3600 );
            $delay -= $min * 60 % $delay    if ( $delay > 60 );
            $delay -= $sec % $delay;
            $self->{next_window} = $time + $delay;
            $self->set_timer( $delay * 1000, 'oneshot' );
        }
    }
    return $self->{arguments};
}

sub lookup {
    my ( $self, $key, $negate ) = @_;
    my %rv = ();
    if ($negate) {
        for my $cache ( @{ $self->{caches} } ) {
            for my $bucket ( @{$cache} ) {
                for my $other ( keys %{$bucket} ) {
                    next if ( $other eq $key );
                    $rv{$_} = 1 for ( @{ $bucket->{$other} } );
                }
            }
        }
    }
    else {
        for my $cache ( @{ $self->{caches} } ) {
            for my $bucket ( @{$cache} ) {
                next if ( not exists $bucket->{$key} );
                $rv{$_} = 1 for ( @{ $bucket->{$key} } );
            }
        }
    }
    return \%rv;
}

sub search {
    my ( $self, $glob, $negate ) = @_;
    my %rv = ();
    if ($negate) {
        for my $cache ( @{ $self->{caches} } ) {
            for my $bucket ( @{$cache} ) {
                for my $key ( keys %{$bucket} ) {
                    next if ( $key =~ m{$glob} );
                    $rv{$_} = 1 for ( @{ $bucket->{$key} } );
                }
            }
        }
    }
    else {
        for my $cache ( @{ $self->{caches} } ) {
            for my $bucket ( @{$cache} ) {
                for my $key ( keys %{$bucket} ) {
                    next if ( $key !~ m{$glob} );
                    $rv{$_} = 1 for ( @{ $bucket->{$key} } );
                }
            }
        }
    }
    return \%rv;
}

sub range {
    my ( $self, $from, $to ) = @_;
    my %rv = ();
    for my $cache ( @{ $self->{caches} } ) {
        for my $bucket ( @{$cache} ) {
            for my $key ( keys %{$bucket} ) {
                next
                    if ( ( defined $from and $key < $from )
                    or ( defined $to and $key > $to ) );
                $rv{$_} = 1 for ( @{ $bucket->{$key} } );
            }
        }
    }
    return \%rv;
}

sub get_keys {
    my ($self) = @_;
    my %unique = ();
    for my $cache ( @{ $self->{caches} } ) {
        for my $bucket ( @{$cache} ) {
            next if ( not $bucket );
            $unique{$_} += @{ $bucket->{$_} } for ( keys %{$bucket} );
        }
    }
    return \%unique;
}

sub collect {
    my ( $self, $timestamp, $key, $value ) = @_;
    return 1 if ( not length $value );
    my $cache = $self->get_cache($key);
    my $bucket = $self->get_bucket( $cache, $timestamp );
    shift @{ $bucket->{$key} }
        if ( push( @{ $bucket->{$key} //= [] }, $value ) > $self->{limit}
        and $self->{limit} );
    return;
}

########################
# synchronous interface
########################

sub fetch {
    my ( $self, $key ) = @_;
    die 'ERROR: no key' if ( not defined $key );
    my $field     = $self->{field} or die 'ERROR: no field';
    my $payload   = undef;
    my $rv        = undef;
    my $tachikoma = $self->{connector};
    my $request   = Tachikoma::Message->new;
    $request->type(TM_INFO);
    $request->to($field);
    $request->payload("GET $key\n");

    if ( not $tachikoma ) {
        $tachikoma = Tachikoma->inet_client( $self->{host}, $self->{port} );
        $self->{connector} = $tachikoma;
    }
    $tachikoma->callback(
        sub {
            my $response = shift;
            if ( $response->type & TM_STORABLE ) {
                $payload = $response->payload;
            }
            else {
                die 'ERROR: fetch failed';
            }
            return;
        }
    );
    $tachikoma->fill($request);
    $tachikoma->drain;
    my %offsets = %{$payload};
    $rv = [];
    for my $entry ( sort keys %{$payload} ) {
        my ( $partition, $offset ) = split m{:}, $entry, 2;
        next if ( not defined $offset or not $offsets{$entry} );
        push @{$rv},
            @{ $self->fetch_offset( $partition, $offset, \%offsets ) };
    }
    return $rv;
}

sub fetch_offset {
    my ( $self, $partition, $offset, $offsets ) = @_;
    my $value = undef;
    my $topic = $self->{topic} or die 'ERROR: no topic';
    my $group = $self->{consumer_broker};
    chomp $offset;
    if ( not $group ) {
        $group = Tachikoma::Nodes::ConsumerBroker->new($topic);
        $self->{consumer_broker} = $group;
    }
    else {
        $group->get_partitions;
    }
    my $consumer = $group->{consumers}->{$partition}
        || $group->make_sync_consumer($partition);
    if ($consumer) {
        my $messages = undef;
        $consumer->next_offset($offset);
        do { $messages = $consumer->fetch }
            while ( not @{$messages} and not $consumer->{eos} );
        die $consumer->sync_error if ( $consumer->{sync_error} );
        if ( not @{$messages} ) {
            print {*STDERR}
                "WARNING: fetch_offset failed ($partition:$offset)\n";
            $value = [];
        }
        elsif ($offsets) {
            $value = [];
            while ( my $message = shift @{$messages} ) {
                my $this_partition = $message->[FROM];
                my $this_offset    = ( split m{:}, $message->[ID], 2 )[0];
                my $entry          = "$this_partition:$this_offset\n";
                if ( $offsets->{$entry} ) {
                    push @{$value}, $message;
                    delete $offsets->{$entry};
                }
            }
        }
        else {
            my $message = shift @{$messages};
            $value = $message if ( $message->[ID] =~ m{^$offset:} );
        }
    }
    else {
        die "ERROR: consumer lookup failed $partition:$offset";
    }
    return $value;
}

# async support
sub limit {
    my $self = shift;
    if (@_) {
        $self->{limit} = shift;
    }
    return $self->{limit};
}

1;