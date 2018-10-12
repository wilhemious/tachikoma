#!/usr/bin/perl
# ----------------------------------------------------------------------
# Tachikoma::Nodes::HTTP_Responder
# ----------------------------------------------------------------------
#
# $Id: HTTP_Responder.pm 35038 2018-10-10 00:26:59Z chris $
#

package Tachikoma::Nodes::HTTP_Responder;
use strict;
use warnings;
use Tachikoma::Nodes::Timer;
use Tachikoma::Message qw(
    TYPE FROM TO STREAM PAYLOAD
    TM_BYTESTREAM TM_STORABLE
);
use File::MkTemp;
use POSIX qw( strftime );
use Time::Local;
use vars qw( @EXPORT_OK );
use parent qw( Exporter Tachikoma::Nodes::Timer );
@EXPORT_OK = qw( get_time log_entry cached_strftime );

use version; our $VERSION = 'v2.0.314';

my $Time_String     = undef;
my $Last_Time       = 0;
my $Log_Time_String = undef;
my $Log_Last_Time   = 0;

sub new {
    my $class = shift;
    my $self  = $class->SUPER::new;
    $self->{payloads} = {};
    $self->{requests} = {};
    $self->{port}     = undef;
    bless $self, $class;
    return $self;
}

sub arguments {
    my $self = shift;
    if (@_) {
        $self->{arguments} = shift;
        my ( $tmp_path, $port ) = split( ' ', $self->{arguments}, 2 );
        $self->{tmp_path} = $tmp_path;
        $self->{port}     = $port;
        $self->set_timer;
    }
    return $self->{arguments};
}

sub fill {
    my $self    = shift;
    my $message = shift;
    return if ( not $message->[TYPE] & TM_BYTESTREAM );
    my $name     = $message->[FROM];
    my $payloads = $self->{payloads};
    my $payload  = $payloads->{$name};
    my $lastfour = '';
    my $requests = $self->{requests};
    my $request  = $requests->{$name};
    my $headers  = undef;

    # collect request payloads
    if ( not $payload ) {
        my $scalar = '';
        $payloads->{$name} = \$scalar;
        $payload = \$scalar;
    }
    elsif ( not $request and length($$payload) >= 4 ) {
        $lastfour = substr( $$payload, length($$payload) - 4, 4 );
    }
    $$payload .= $message->[PAYLOAD];

    # see if we have all the headers
    if ($request) {
        $headers = $request->{headers};
    }
    else {
        my $test = $lastfour . $message->[PAYLOAD];
        return 1 if ( $test !~ m(\r\n\r\n) );
        my ( $remote_addr, $remote_port ) = split( ':', $message->[FROM], 2 );
        my ( $header_text, $body ) = split( m(\r\n\r\n), $$payload, 2 );
        $$payload = $body;
        my @lines = split( m(^), $header_text );
        my $line = shift(@lines);
        if ( not $line ) {
            delete $requests->{$name};
            delete $payloads->{$name};
            return;
        }
        $line =~ s(\r?\n$)();
        my ( $method, $uri, $version ) = split( ' ', $line, 3 );
        if ( not $uri ) {
            delete $requests->{$name};
            delete $payloads->{$name};
            return;
        }
        $uri =~ s(^http://[^/]+)()i;
        my ( $script_url, $query_string ) = split( '\?', $uri, 2 );
        $headers = {};
        $request->{server_port}  = $self->{port} || 80;
        $request->{remote_addr}  = $remote_addr;
        $request->{remote_port}  = $remote_port;
        $request->{line}         = $line;
        $request->{method}       = $method;
        $request->{uri}          = $uri;
        $request->{version}      = $version;
        $request->{path}         = $script_url;
        $request->{script_url}   = $script_url;
        $request->{query_string} = $query_string || '';

        for my $line (@lines) {
            my ( $key, $value ) = split( m(:\s*), $line, 2 );
            next if ( $key =~ m([^\w-]) );
            $value =~ s(\r?\n$)() if ( defined $value );
            $headers->{ lc($key) } = $value;
        }
        $request->{headers} = $headers;
        $requests->{$name} = $request;
    }

    # if it's a POST, see if we have the whole thing.
    # if it exceeds 128k, write it to disk.
    if ( $request->{'method'} eq 'POST' ) {
        my $length = $headers->{'content-length'};
        if ( not $length ) {
            delete $requests->{$name};
            delete $payloads->{$name};
            return;
        }

        # if ( $length > 131072 ) {
        #     if ( not $request->{tmp} ) {
        #         my $tmp_path = join( '/', $self->{tmp_path}, 'post' );
        #         $self->make_dirs($tmp_path)
        #             or return $self->stderr(
        #             "ERROR: couldn't mkdir $tmp_path: $!")
        #             if ( not -d $tmp_path );
        #         my ( $fh, $template ) = mkstempt( 'X' x 16, $tmp_path );
        #         $request->{fh} = $fh;
        #         $request->{tmp} = join( '/', $tmp_path, $template );
        #     }
        #     $request->{length} += length($$payload);
        #     syswrite( $request->{fh}, $$payload )
        #         or return $self->stderr("ERROR: can't write(): $!")
        #         if ( length($$payload) );
        #     $$payload = '';
        #     return if ( $length > $request->{length} );
        #     close( $request->{fh} );
        #     delete $request->{fh};
        # }
        # else {
        #     return if ( $length > length($$payload) );
        #     $request->{body} = $$payload;
        # }
        return if ( $length > length($$payload) );
        $request->{body} = $$payload;
    }

    # cleanup and send the request object down the pipe
    delete $requests->{$name};
    delete $payloads->{$name};
    my $request_message = Tachikoma::Message->new;
    $request_message->[TYPE]   = TM_STORABLE;
    $request_message->[FROM]   = $message->[FROM];
    $request_message->[TO]     = $self->{owner};
    $request_message->[STREAM] = join( '',
          $headers->{host}
        ? $request->{uri} =~ m(^http://$headers->{host})
                ? $request->{uri}
                : join( '', 'http://', $headers->{host}, $request->{uri} )
        : join( '', 'http://default', $request->{uri} ) );
    $request_message->[PAYLOAD] = $request;
    $self->{counter}++;
    return $self->{sink}->fill($request_message);
}

sub fire {
    my $self     = shift;
    my $payloads = $self->{payloads};
    for my $name ( keys %$payloads ) {
        delete $payloads->{$name} if ( not $Tachikoma::Nodes{$name} );
    }
    my $requests = $self->{requests};
    for my $name ( keys %$requests ) {
        delete $requests->{$name} if ( not $Tachikoma::Nodes{$name} );
    }
}

sub get_time {
    my $header = shift;
    return 0 unless $header;
    my %m = qw( Jan 1 Feb 2 Mar 3 Apr 4  May 5  Jun 6
        Jul 7 Aug 8 Sep 9 Oct 10 Nov 11 Dec 12 );
    return 0 unless $header =~ m{^ \s* \w+, \s* (\d+) \s* (\w+) \s* (\d+) \s*
          (\d+):(\d+):(\d+) \s* (\w+) \s* $}x;

    # e.g. Sun, 25 Feb 2007 11:42:04 GMT
    my ( $day, $mon, $year, $hour, $min, $sec, $zone ) =
        ( $1, $m{$2}, $3, $4, $5, $6, $7 );
    my $time =
        $zone eq 'GMT'
        ? timegm( $sec, $min, $hour, $day, $mon - 1, $year - 1900 )
        : timelocal( $sec, $min, $hour, $day, $mon - 1, $year - 1900 );
    return $time;
}

sub log_entry {
    my $self    = shift;
    my $status  = shift;
    my $message = shift;
    my $size    = shift;
    return if ( not $message->[TYPE] & TM_STORABLE );
    my $request    = $message->payload;
    my $headers    = $request->{headers};
    my $host       = $headers->{'host'} || q{""};
    my $referer    = $headers->{'referer'} || q{};
    my $user_agent = $headers->{'user-agent'} || q{};
    my $log_entry  = Tachikoma::Message->new;
    $log_entry->[TYPE]    = TM_BYTESTREAM;
    $log_entry->[TO]      = 'http:log';
    $log_entry->[PAYLOAD] = join q{},
        $host, q{ },
        $request->{remote_addr}, q{ - },
        $request->{remote_user} || q{-},
        q{ [}, cached_log_strftime(),
        q{] "}, $request->{line}, q{" },
        $status, q{ }, $size || q{-},
        q{ "}, $referer, q{" "}, $user_agent, q{"},
        "\n";
    return $self->{sink}->fill($log_entry);
}

sub cached_log_strftime {
    if ( $Tachikoma::Now > $Log_Last_Time ) {
        $Log_Time_String =
            strftime( '%d/%b/%Y:%T %z', localtime $Tachikoma::Now );
        $Log_Last_Time = $Tachikoma::Now;
    }
    return $Log_Time_String;
}

sub cached_strftime {
    if ( $Tachikoma::Now > $Last_Time ) {
        $Time_String =
            strftime( '%a, %d %b %Y %T GMT', gmtime $Tachikoma::Now );
        $Last_Time = $Tachikoma::Now;
    }
    return $Time_String;
}

sub payloads {
    my $self = shift;
    if (@_) {
        $self->{payloads} = shift;
    }
    return $self->{payloads};
}

sub requests {
    my $self = shift;
    if (@_) {
        $self->{requests} = shift;
    }
    return $self->{requests};
}

sub tmp_path {
    my $self = shift;
    if (@_) {
        $self->{tmp_path} = shift;
    }
    return $self->{tmp_path};
}

sub port {
    my $self = shift;
    if (@_) {
        $self->{port} = shift;
    }
    return $self->{port};
}

1;