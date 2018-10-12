#!/usr/bin/perl
# ----------------------------------------------------------------------
# Tachikoma::Nodes::Socket
# ----------------------------------------------------------------------
#
# Tachikomatic IPC - send and receive messages over sockets
#                  - RSA/Ed25519 handshakes
#                  - TLSv1
#                  - heartbeats and latency scores to reset bad connections
#                  - on_EOF: close, send, ignore, reconnect
#
# $Id: Socket.pm 27118 2016-09-20 18:29:02Z chris $
#

package Tachikoma::Nodes::Socket;
use strict;
use warnings;
use Tachikoma::Nodes::FileHandle qw( TK_R TK_W TK_SYNC setsockopts );
use Tachikoma::Message qw(
    TYPE FROM TO ID TIMESTAMP PAYLOAD
    TM_BYTESTREAM TM_HEARTBEAT TM_ERROR
    VECTOR_SIZE
);
use Tachikoma::Config qw(
    %Tachikoma $ID $Private_Ed25519_Key %SSL_Config %Var $Wire_Version
);
use Tachikoma::Crypto;
use Digest::MD5 qw( md5 );
use IO::Socket::SSL qw(
    SSL_WANT_WRITE SSL_VERIFY_PEER SSL_VERIFY_FAIL_IF_NO_PEER_CERT
);
use Socket qw(
    PF_UNIX PF_INET SOCK_STREAM SOL_SOCKET SOMAXCONN
    SO_REUSEADDR SO_SNDBUF SO_RCVBUF SO_SNDLOWAT SO_KEEPALIVE
    inet_aton inet_ntoa pack_sockaddr_in unpack_sockaddr_in
    pack_sockaddr_un
);
use POSIX qw( F_SETFL O_NONBLOCK EAGAIN SIGUSR1 );
my $USE_SODIUM;

BEGIN {
    $USE_SODIUM = eval {
        my $module_name = 'Crypt::NaCl::Sodium';
        my $module_path = 'Crypt/NaCl/Sodium.pm';
        require $module_path;
        import $module_name qw( :utils );
        return 1;
    };
}
use vars qw( @EXPORT_OK );
use parent qw( Tachikoma::Nodes::FileHandle Tachikoma::Crypto );
@EXPORT_OK = qw( TK_R TK_W TK_SYNC TK_EPOLLED setsockopts );

use version; our $VERSION = 'v2.0.195';

sub unix_server {
    my $class    = shift;
    my $filename = shift;
    my $name     = shift;
    my $perms    = shift;
    my $gid      = shift;
    my $socket;
    socket $socket, PF_UNIX, SOCK_STREAM, 0 or die "FAILED: socket: $!";
    setsockopts($socket);
    bind $socket, pack_sockaddr_un($filename) or die "ERROR: bind: $!\n";
    listen $socket, SOMAXCONN or die "FAILED: listen: $!";
    die "FAILED: stat() says $filename isn't a socket"
        if ( not -S $filename );
    chmod oct $perms, $filename or die "ERROR: chmod: $!" if ($perms);
    chown $>, $gid, $filename or die "ERROR: chown: $!" if ($gid);
    my $server = $class->new;
    $server->name($name);
    $server->{type}                           = 'listen';
    $server->{filename}                       = $filename;
    $server->{fileperms}                      = $perms;
    $server->{filegid}                        = $gid;
    $server->{registrations}->{connected}     = {};
    $server->{registrations}->{authenticated} = {};
    $server->fh($socket);
    return $server->register_server_node;
}

sub unix_client {    ## no critic (ProhibitManyArgs)
    my $class      = shift;
    my $filename   = shift;
    my $name       = shift;
    my $flags      = shift;
    my $use_SSL    = shift;
    my $SSL_config = shift;
    my $socket;
    socket $socket, PF_UNIX, SOCK_STREAM, 0 or die "FAILED: socket: $!";
    setsockopts($socket);
    my $client = $class->new($flags);
    $client->name($name);
    $client->{type}          = 'connect';
    $client->{filename}      = $filename;
    $client->{last_upbeat}   = $Tachikoma::Now;
    $client->{last_downbeat} = $Tachikoma::Now;
    $client->fh($socket);

    # this has to happen after fh() sets O_NONBLOCK correctly:
    if ( not connect $socket, pack_sockaddr_un($filename) ) {
        $client->remove_node;
        die "ERROR: connect: $!\n";
    }
    if ($use_SSL) {
        $client->SSL_config($SSL_config) if ($SSL_config);
        $client->use_SSL($use_SSL);
        $client->start_SSL_connection;
    }
    else {
        $client->init_connect;
    }
    $client->register_reader_node;
    return $client;
}

sub unix_client_async {
    my $class    = shift;
    my $filename = shift;
    my $name     = shift;
    my $client   = $class->new;
    $client->name($name);
    $client->{type}          = 'connect';
    $client->{filename}      = $filename;
    $client->{last_upbeat}   = $Tachikoma::Now;
    $client->{last_downbeat} = $Tachikoma::Now;
    push @Tachikoma::Reconnect, $client;
    return $client;
}

sub inet_server {
    my $class    = shift;
    my $hostname = shift;
    my $port     = shift;
    my $iaddr    = inet_aton($hostname) or die "FAILED: no host: $hostname";
    my $sockaddr = pack_sockaddr_in( $port, $iaddr );
    my $proto    = getprotobyname 'tcp';
    my $socket;
    socket $socket, PF_INET, SOCK_STREAM, $proto
        or die "FAILED: socket: $!";
    setsockopt $socket, SOL_SOCKET, SO_REUSEADDR, 1
        or die "FAILED: setsockopt: $!";
    setsockopts($socket);
    bind $socket, pack_sockaddr_in( $port, $iaddr )
        or die "ERROR: bind: $!\n";
    listen $socket, SOMAXCONN or die "FAILED: listen: $!";
    my $server = $class->new;
    $server->name( join q{:}, $hostname, $port );
    $server->{type}                           = 'listen';
    $server->{registrations}->{connected}     = {};
    $server->{registrations}->{authenticated} = {};
    $server->fh($socket);
    return $server->register_server_node;
}

sub inet_client {
    my $class      = shift;
    my $hostname   = shift;
    my $port       = shift or die "FAILED: no port specified for $hostname";
    my $flags      = shift;
    my $use_SSL    = shift;
    my $SSL_config = shift;
    my $iaddr = inet_aton($hostname) or die "ERROR: no host: $hostname\n";
    my $proto = getprotobyname 'tcp';
    my $socket;
    socket $socket, PF_INET, SOCK_STREAM, $proto
        or die "FAILED: socket: $!";
    setsockopts($socket);
    my $client = $class->new($flags);
    $client->name( join q{:}, $hostname, $port );
    $client->{type}          = 'connect';
    $client->{hostname}      = $hostname;
    $client->{address}       = $iaddr;
    $client->{port}          = $port;
    $client->{last_upbeat}   = $Tachikoma::Now;
    $client->{last_downbeat} = $Tachikoma::Now;
    $client->fh($socket);

    # this has to happen after fh() sets O_NONBLOCK correctly:
    if (    not( connect $socket, pack_sockaddr_in( $port, $iaddr ) )
        and defined $flags
        and $flags & TK_SYNC )
    {
        $client->remove_node;
        die "ERROR: connect: $!\n";
    }
    if ($use_SSL) {
        $client->SSL_config($SSL_config) if ($SSL_config);
        $client->use_SSL($use_SSL);
        $client->start_SSL_connection;
    }
    else {
        $client->init_connect;
    }
    $client->register_reader_node;
    return $client;
}

sub inet_client_async {
    my $class    = shift;
    my $hostname = shift;
    my $port     = shift || 4230;
    my $name     = shift || $hostname;
    my $client   = $class->new;
    $client->name($name);
    $client->{type}          = 'connect';
    $client->{hostname}      = $hostname;
    $client->{port}          = $port;
    $client->{last_upbeat}   = $Tachikoma::Now;
    $client->{last_downbeat} = $Tachikoma::Now;
    $client->dns_lookup;
    push @Tachikoma::Reconnect, $client;
    return $client;
}

sub new {
    my $proto        = shift;
    my $class        = ref($proto) || $proto;
    my $flags        = shift || 0;
    my $self         = $class->SUPER::new;
    my $input_buffer = q{};
    $self->{type}             = 'socket';
    $self->{flags}            = $flags;
    $self->{on_EOF}           = 'close';
    $self->{hostname}         = undef;
    $self->{address}          = undef;
    $self->{port}             = undef;
    $self->{filename}         = undef;
    $self->{fileperms}        = undef;
    $self->{filegid}          = undef;
    $self->{use_SSL}          = undef;
    $self->{SSL_config}       = undef;
    $self->{auth_challenge}   = undef;
    $self->{auth_timestamp}   = undef;
    $self->{scheme}           = Tachikoma->scheme;
    $self->{delegates}        = {};
    $self->{drain_fh}         = \&Tachikoma::Nodes::FileHandle::drain_fh;
    $self->{fill_fh}          = \&Tachikoma::Nodes::FileHandle::fill_fh;
    $self->{last_upbeat}      = undef;
    $self->{last_downbeat}    = undef;
    $self->{latency_score}    = undef;
    $self->{inet_aton_serial} = undef;
    $self->{registrations}->{reconnect} = {};
    $self->{registrations}->{EOF}       = {};
    $self->{fill_modes}                 = {
        null            => \&Tachikoma::Nodes::FileHandle::null_cb,
        unauthenticated => \&do_not_enter,
        init            => \&fill_buffer_init,
        fill            => $flags & TK_SYNC
        ? \&Tachikoma::Nodes::FileHandle::fill_fh_sync
        : \&Tachikoma::Nodes::FileHandle::fill_buffer
    };
    $self->{fill} = $self->{fill_modes}->{fill};
    bless $self, $class;
    return $self;
}

sub register_server_node {
    my $self = shift;
    $Tachikoma::Event_Framework->register_server_node($self);
    $self->{drain_fh} = \&accept_connections;
    $self->{fill}     = \&Tachikoma::Nodes::FileHandle::null_cb;
    return $self;
}

sub accept_connections {    ## no critic (RequireArgUnpacking)
    my $self = shift;
    return $Tachikoma::Event_Framework->accept_connections( $self, @_ );
}

sub accept_connection {
    my $self   = shift;
    my $server = $self->{fh};
    my $client;
    my $paddr = accept $client, $server;
    if ( not $paddr ) {
        $self->stderr("ERROR: accept_connection() failed: $!\n")
            if ( $! != EAGAIN );
        return;
    }
    my ( $node, $port, $address );
    my $unix = $self->{filename};
    ( $port, $address ) = unpack_sockaddr_in($paddr) if ( not $unix );

    if ( $self->{use_SSL} ) {
        my $ssl_config = $self->SSL_config;
        die "ERROR: SSL not configured\n"
            if ( not $ssl_config->{SSL_server_ca_file} );
        my $ssl_client = IO::Socket::SSL->start_SSL(
            $client,
            SSL_server         => 1,
            SSL_key_file       => $ssl_config->{SSL_server_key_file},
            SSL_cert_file      => $ssl_config->{SSL_server_cert_file},
            SSL_ca_file        => $ssl_config->{SSL_server_ca_file},
            SSL_startHandshake => 0,

            # SSL_cipher_list     => $Tachikoma::SSL_Ciphers,
            SSL_version         => $Tachikoma::SSL_Version,
            SSL_verify_callback => $self->get_ssl_verify_callback,
            SSL_verify_mode     => $self->{use_SSL} eq 'noverify'
            ? 0
            : SSL_VERIFY_PEER | SSL_VERIFY_FAIL_IF_NO_PEER_CERT
        );
        if ( not $ssl_client or not ref $ssl_client ) {
            $self->stderr( join q{: }, q{ERROR: couldn't start_SSL()},
                grep $_, $!, IO::Socket::SSL::errstr() );
            return;
        }
        $node             = $self->new;
        $node->{type}     = 'accept';
        $node->{drain_fh} = \&init_SSL_connection;
        $node->{fill_fh}  = \&init_SSL_connection;
        $node->{use_SSL}  = 'true';
        $node->fh($ssl_client);
    }
    else {
        $node = $self->new;
        $node->{type} = 'accept';
        $node->fh($client);
        $node->init_accept;
    }
    my $name;
    if ($unix) {
        my $my_name = $self->{name};
        do {
            $name = join q{:}, $my_name, Tachikoma->counter;
        } while ( exists $Tachikoma::Nodes{$name} );
    }
    else {
        $name = join q{:}, inet_ntoa($address), $port;
        if ( exists $Tachikoma::Nodes{$name} ) {
            $self->stderr("WARNING: $name exists");
            return $node->remove_node;
        }
    }
    $node->name($name);
    $node->{owner}          = $self->{owner};
    $node->{sink}           = $self->{sink};
    $node->{edge}           = $self->{edge};
    $node->{on_EOF}         = $self->{on_EOF};
    $node->{scheme}         = $self->{scheme};
    $node->{delegates}      = $self->{delegates};
    $node->{fill}           = $node->{fill_modes}->{unauthenticated};
    $node->{max_unanswered} = $self->{max_unanswered}
        if ( exists $self->{max_unanswered} );
    $node->buffer_mode( $self->{buffer_mode} )
        if ( exists $self->{buffer_mode} );

    for my $event ( keys %{ $self->{registrations} } ) {
        my $r = $self->{registrations}->{$event};
        $node->{registrations}->{$event} =
            { map { $_ => defined $r->{$_} ? 0 : undef } keys %{$r} };
    }
    $node->register_reader_node;
    $node->notify( connected => $node->{name} );
    $self->{counter}++;
    return;
}

sub init_socket {
    my $self    = shift;
    my $payload = shift;
    #
    # Earlier we forked our own resolver job and sent it a
    # message with the hostname.  When fill_buffer_init() received
    # the response it called init_socket() with the address:
    #
    my $address = ( $payload =~ m{^(\d+[.]\d+[.]\d+[.]\d+)$} )[0];
    if ( not $address ) {
        $self->{address} = pack 'H*', '00000000';
        $self->print_less_often(
            'WARNING: name lookup failed, invalid address');
        return $self->close_filehandle('reconnect');
    }
    my $iaddr = inet_aton($address) or die "FAILED: no host: $address";
    my $proto = getprotobyname 'tcp';
    my $socket;
    socket $socket, PF_INET, SOCK_STREAM, $proto or die "FAILED: socket: $!";
    setsockopts($socket);
    $self->close_filehandle;
    $self->{address} = $iaddr;
    $self->{fill}    = $self->{fill_modes}->{fill};
    $self->fh($socket);
    ## no critic (RequireCheckedSyscalls)
    connect $socket, pack_sockaddr_in( $self->{port}, $iaddr );
    ## use critic

    if ( $self->{use_SSL} ) {
        if ( not $self->start_SSL_connection ) {
            $self->handle_EOF;
        }
        return;
    }
    $self->register_reader_node;
    return $self->init_connect;
}

sub start_SSL_connection {
    my $self       = shift;
    my $socket     = $self->{fh};
    my $ssl_config = $self->SSL_config;
    die "ERROR: SSL not configured\n"
        if ( not $ssl_config->{SSL_client_ca_file} );
    my $ssl_socket = IO::Socket::SSL->start_SSL(
        $socket,
        SSL_key_file       => $ssl_config->{SSL_client_key_file},
        SSL_cert_file      => $ssl_config->{SSL_client_cert_file},
        SSL_ca_file        => $ssl_config->{SSL_client_ca_file},
        SSL_startHandshake => $self->{flags} & TK_SYNC,
        SSL_use_cert       => 1,

        # SSL_cipher_list     => $Tachikoma::SSL_Ciphers,
        SSL_version         => $Tachikoma::SSL_Version,
        SSL_verify_callback => $self->get_ssl_verify_callback,
        SSL_verify_mode     => $self->{use_SSL} eq 'noverify'
        ? 0
        : SSL_VERIFY_PEER | SSL_VERIFY_FAIL_IF_NO_PEER_CERT,
    );
    if ( not $ssl_socket or not ref $ssl_socket ) {
        my $ssl_error = $IO::Socket::SSL::SSL_ERROR;
        $ssl_error =~ s{(error)(error)}{$1: $2};
        if ( $self->{flags} & TK_SYNC ) {
            die join q{: },
                q{ERROR: couldn't start_SSL},
                grep $_, $!, $ssl_error, "\n";
        }
        else {
            $self->print_less_often( join q{: },
                q{WARNING: couldn't start_SSL},
                grep $_, $!, $ssl_error );
            return;
        }
    }
    $self->fh($ssl_socket);
    $self->register_reader_node;
    $self->register_writer_node;
    if ( $self->{flags} & TK_SYNC ) {

      # my $peer = join q{},
      #     ' authority: "', $ssl_socket->peer_certificate('authority'), q{"},
      #     ' owner: "',     $ssl_socket->peer_certificate('owner'),     q{"},
      #     ' cipher: "', $ssl_socket->get_cipher, q{"}, "\n";
      # $self->stderr( 'connect_SSL() verified peer:', $peer );
        $self->{fill} = \&fill_fh_sync_SSL;
        $self->init_connect;
    }
    else {
        $self->{drain_fh} = \&init_SSL_connection;
        $self->{fill_fh}  = \&init_SSL_connection;
    }
    return 'success';
}

sub get_ssl_verify_callback {
    my $self = shift;
    return sub {
        my $okay  = $_[0];
        my $error = $_[3];
        return 1 if ($okay);
        if ( $error eq 'error:0000000A:lib(0):func(0):DSA lib' ) {
            $self->print_less_often(
                "WARNING: SSL certificate verification error: $error");
            return 1;
        }
        $self->stderr("ERROR: SSL certificate verification failed: $error");
        return 0;
    };
}

sub init_SSL_connection {
    my $self   = shift;
    my $type   = $self->{type};
    my $fh     = $self->{fh};
    my $method = $type eq 'connect' ? 'connect_SSL' : 'accept_SSL';
    if ( $fh and $fh->$method ) {
        my $peer = join q{},
            'authority: "',
            $fh->peer_certificate('authority'),
            q{"},
            ' owner: "',
            $fh->peer_certificate('owner'),
            q{"},
            ' cipher: "',
            $fh->get_cipher,
            q{"},
            "\n";

        # $self->stderr($method, '() verified peer: ', $peer);
        if ( $type eq 'connect' ) {
            $self->init_connect;
        }
        else {
            if ( not $self->delegate_authorization( 'ssl', $peer ) ) {
                $self->stderr('ERROR: peer not allowed to connect');
                return $self->remove_node;
            }
            $self->init_accept;
        }
        $self->register_reader_node;
    }
    elsif ( $! != EAGAIN ) {
        my $ssl_error = IO::Socket::SSL::errstr();
        $ssl_error =~ s{(error)(error)}{$1: $2};
        $self->print_less_often( join q{: }, "WARNING: $method() failed",
            grep $_, $!, $ssl_error );

        # this keeps the event framework from constantly
        # complaining about missing entries in %Nodes_By_FD
        $self->unregister_reader_node;
        $self->unregister_writer_node;
        if ( $self->{fh} and fileno $self->{fh} ) {
            close $self->{fh} or $self->stderr("WARNING: close() failed: $!");
        }
        $self->{fh} = undef;
        $self->handle_EOF;
    }
    elsif ( $IO::Socket::SSL::SSL_ERROR == SSL_WANT_WRITE ) {
        $self->register_writer_node;
    }
    else {
        $self->unregister_writer_node;
    }
    return;
}

sub init_connect {
    my $self = shift;
    $self->{auth_challenge} = rand;
    if ( $self->{flags} & TK_SYNC ) {
        $self->reply_to_server_challenge;
    }
    else {
        $self->{drain_fh} = \&reply_to_server_challenge;
        $self->{fill_fh}  = \&Tachikoma::Nodes::FileHandle::null_cb;
    }
    return;
}

sub init_accept {
    my $self = shift;
    $self->{auth_challenge} = rand;
    $self->{drain_fh}       = \&auth_client_response;
    $self->{fill_fh}        = \&Tachikoma::Nodes::FileHandle::fill_fh;
    my $message =
        $self->command( 'challenge', 'client',
        md5( $self->{auth_challenge} ) );
    $message->[ID] = $Wire_Version;
    $self->{auth_timestamp} = $message->[TIMESTAMP];
    push @{ $self->{output_buffer} }, $message->packed;
    $self->register_writer_node;
    return;
}

sub reply_to_server_challenge {
    my $self = shift;
    my ( $got, $message ) =
        $self->reply_to_challenge( 'client', \&auth_server_response,
        \&Tachikoma::Nodes::FileHandle::fill_fh );
    return if ( not $message );
    my $response =
        $self->command( 'challenge', 'server',
        md5( $self->{auth_challenge} ) );
    $response->[ID] = $Wire_Version;
    $self->{auth_timestamp} = $response->[TIMESTAMP];
    if ( $self->{flags} & TK_SYNC ) {
        my $rv = syswrite $self->{fh},
            ${ $message->packed } . ${ $response->packed };
        die "ERROR: reply_to_server_challenge() couldn't write(): $!\n"
            if ( not $rv );
    }
    else {
        unshift @{ $self->{output_buffer} },
            $message->packed, $response->packed;
        $self->register_writer_node;
    }
    if ( $got > 0 ) {
        $self->stderr(
            "WARNING: discarding $got extra bytes from server challenge.");
        my $new_buffer = q{};
        $self->{input_buffer} = \$new_buffer;
    }
    return;
}

sub auth_client_response {
    my $self = shift;
    my $got  = $self->auth_response( 'client', \&reply_to_client_challenge,
        \&Tachikoma::Nodes::FileHandle::null_cb );
    $self->reply_to_client_challenge if ($got);
    return;
}

sub reply_to_client_challenge {
    my $self = shift;
    my ( $got, $message ) = $self->reply_to_challenge(
        'server',
        \&Tachikoma::Nodes::FileHandle::drain_fh,
        \&Tachikoma::Nodes::FileHandle::fill_fh
    );
    return if ( not $message );
    $self->{fill} = $self->{fill_modes}->{fill};
    $self->notify( authenticated => $self->{name} );
    unshift @{ $self->{output_buffer} }, $message->packed;
    $self->register_writer_node;
    $self->drain_buffer( $self->{input_buffer} ) if ( $got > 0 );
    return;
}

sub auth_server_response {
    my $self = shift;
    my $got  = $self->auth_response(
        'server',
        \&Tachikoma::Nodes::FileHandle::drain_fh,
        \&Tachikoma::Nodes::FileHandle::fill_fh
    );
    $self->drain_buffer( $self->{input_buffer} ) if ($got);
    return;
}

sub reply_to_challenge {
    my $self       = shift;
    my $type       = shift;
    my $drain_func = shift;
    my $fill_func  = shift;
    my $other      = $type eq 'server' ? 'client' : 'server';
    my ( $got, $message ) = $self->read_block(65536);
    return if ( not $message );
    my $version = $message->[ID];

    if ( not $version or $version ne $Wire_Version ) {
        my $caller = ( split m{::}, ( caller 1 )[3] )[-1] . '()';
        $self->stderr("ERROR: $caller failed: version mismatch");
        return $self->handle_EOF;
    }
    my $command = eval { Tachikoma::Command->new( $message->[PAYLOAD] ) };
    if ( not $command ) {
        $self->stderr("WARNING: reply_to_challenge() failed: $@");
        return $self->handle_EOF;
    }
    elsif ( $command->{arguments} ne $type ) {
        $self->stderr( 'ERROR: wrong challenge type: ',
            $command->{arguments} );
        return $self->handle_EOF;
    }
    elsif ( length $ID
        and not $self->verify_signature( $other, $message, $command ) )
    {
        return $self->handle_EOF;
    }
    $command->sign( $self->scheme, $message->timestamp );
    $message->payload( $command->packed );
    $self->{counter}++;
    $self->{drain_fh} = $drain_func;
    $self->{fill_fh}  = $fill_func;
    return ( $got, $message );
}

sub auth_response {
    my $self       = shift;
    my $type       = shift;
    my $drain_func = shift;
    my $fill_func  = shift;
    my ( $got, $message ) = $self->read_block(65536);
    return if ( not $message );
    my $caller  = ( split m{::}, ( caller 1 )[3] )[-1] . '()';
    my $version = $message->[ID];
    my $command = eval { Tachikoma::Command->new( $message->[PAYLOAD] ) };
    if ( not $command ) {
        $self->stderr("ERROR: $caller failed: $@");
        return $self->handle_EOF;
    }
    elsif ( not $version or $version ne $Wire_Version ) {
        $self->stderr("ERROR: $caller failed: version mismatch");
        return $self->handle_EOF;
    }
    elsif ( $command->{arguments} ne $type ) {
        $self->stderr("ERROR: $caller failed: wrong challenge type");
        return $self->handle_EOF;
    }
    elsif ( length $ID
        and not $self->verify_signature( $type, $message, $command ) )
    {
        return $self->handle_EOF;
    }
    if ( $message->[TIMESTAMP] ne $self->{auth_timestamp} ) {
        $self->stderr("ERROR: $caller failed: incorrect timestamp");
        return $self->handle_EOF;
    }
    elsif ( $command->{payload} ne md5( $self->{auth_challenge} ) ) {
        $self->stderr("ERROR: $caller failed: incorrect response");
        return $self->handle_EOF;
    }
    $self->{counter}++;
    $self->{auth_challenge} = undef;
    $self->{drain_fh}       = $drain_func;
    $self->{fill_fh}        = $fill_func;
    return $got;
}

sub verify_signature {
    my $self    = shift;
    my $type    = shift;
    my $message = shift;
    my $command = shift;
    my $id      = ( split m{\n}, $command->{signature}, 2 )[0];
    if ( not $self->SUPER::verify_signature( $type, $message, $command ) ) {
        return;
    }
    elsif ( not $self->delegate_authorization( 'tachikoma', "$id\n" ) ) {
        $self->stderr("ERROR: $id not allowed to connect");
        return;
    }
    return 1;
}

sub read_block {
    my $self     = shift;
    my $buf_size = shift or die 'FAILED: missing buf_size';
    my $fh       = $self->{fh} or return;
    my $buffer   = $self->{input_buffer};
    my $got      = length ${$buffer};
    my $read     = sysread $fh, ${$buffer}, $buf_size, $got;
    my $again    = $! == EAGAIN;
    my $error    = $!;
    $read = 0 if ( not defined $read and $again and $self->{use_SSL} );
    $got += $read if ( defined $read );
    my $size = $got > VECTOR_SIZE ? unpack 'N', ${$buffer} : 0;

    # XXX:
    # my $size =
    #     $got > VECTOR_SIZE
    #     ? VECTOR_SIZE + unpack 'N', ${$buffer}
    #     : 0;
    if ( $size > $buf_size ) {
        my $caller = ( split m{::}, ( caller 2 )[3] )[-1] . '()';
        $self->stderr("ERROR: $caller failed: size $size > $buf_size");
        return $self->handle_EOF;
    }
    if ( $got >= $size and $size > 0 ) {
        my $message = eval {
            Tachikoma::Message->new( \substr ${$buffer}, 0, $size, q{} );
        };

        # XXX:
        # my $message = eval { Tachikoma::Message->new($buffer) };
        if ( not $message ) {
            $self->stderr("WARNING: read_block() failed: $@");
            return $self->handle_EOF;
        }

        # XXX:
        # substr ${$buffer}, 0, $size, q{};
        $got -= $size;
        $self->{input_buffer} = $buffer;
        return ( $got, $message );
    }
    if ( not defined $read or ( $read < 1 and not $again ) ) {
        my $caller = ( split m{::}, ( caller 2 )[3] )[-1] . '()';
        $self->print_less_often("WARNING: $caller couldn't read(): $error");
        return $self->handle_EOF;
    }
    return;
}

sub delegate_authorization {
    my $self     = shift;
    my $type     = shift;
    my $peer     = shift;
    my $delegate = $self->{delegates}->{$type} or return 1;
    require Tachikoma::Nodes::Callback;
    my $ruleset = $Tachikoma::Nodes{$delegate};
    if ( not $ruleset ) {
        $self->stderr("ERROR: couldn't get $delegate");
        $self->remove_node;
        return;
    }
    my $allowed     = undef;
    my $destination = Tachikoma::Nodes::Callback->new;
    my $message     = Tachikoma::Message->new;
    $message->[TYPE]    = TM_BYTESTREAM;
    $message->[PAYLOAD] = $peer;
    $destination->callback( sub { $allowed = 1 } );
    $ruleset->{sink} = $destination;
    $ruleset->fill($message);
    $ruleset->{sink} = undef;
    return $allowed;
}

sub do_not_enter {
    my $self = shift;
    return $self->stderr('ERROR: not yet authenticated - message discarded');
}

sub drain_buffer {
    my $self   = shift;
    my $buffer = shift;
    my $name   = $self->{name};
    my $sink   = $self->{sink};
    my $edge   = $self->{edge};
    my $owner  = $self->{owner};
    my $got    = length ${$buffer};
    my $size   = $got > VECTOR_SIZE ? unpack 'N', ${$buffer} : 0;

    # XXX:
    # my $size =
    #     $got > VECTOR_SIZE
    #     ? VECTOR_SIZE + unpack 'N', ${$buffer}
    #     : 0;
    while ( $got >= $size and $size > 0 ) {
        my $message =
            Tachikoma::Message->new( \substr ${$buffer}, 0, $size, q{} );

        # XXX:
        # my $message = Tachikoma::Message->new($buffer);
        # substr ${$buffer}, 0, $size, q{};
        $got -= $size;
        $self->{bytes_read} += $size;
        $self->{counter}++;
        $size = $got > VECTOR_SIZE ? unpack 'N', ${$buffer} : 0;

        # XXX:
        # $size =
        #     $got > VECTOR_SIZE
        #     ? VECTOR_SIZE + unpack 'N', ${$buffer}
        #     : 0;
        if ( $message->[TYPE] & TM_HEARTBEAT ) {
            $self->reply_to_heartbeat($message);
            next;
        }
        elsif ($edge) {
            $edge->activate( $message->[PAYLOAD] );
            next;
        }
        $message->[FROM] =
            length $message->[FROM]
            ? join q{/}, $name, $message->[FROM]
            : $name;
        if ( $message->[TO] and $owner ) {
            $self->print_less_often(
                      "ERROR: message addressed to $message->[TO]"
                    . " while owner is set to $owner"
                    . " - dropping message from $message->[FROM]" )
                if ( $message->[TYPE] != TM_ERROR );
            next;
        }
        $message->[TO] = $owner if ($owner);
        $sink->fill($message);
    }
    return $got;
}

sub reply_to_heartbeat {
    my $self    = shift;
    my $message = shift;
    $self->{last_downbeat} = $Tachikoma::Now;
    if ( $message->[PAYLOAD] !~ m{^[\d.]+$} ) {
        $self->stderr( 'ERROR: bad heartbeat payload: ',
            $message->[PAYLOAD] );
    }
    elsif ( $self->{type} eq 'accept' ) {
        $self->fill($message);
    }
    else {
        my $latency = $Tachikoma::Right_Now - $message->[PAYLOAD];
        my $threshold = $Var{'Bad_Ping_Threshold'} || 1;
        if ( $latency > $threshold ) {
            my $score = $self->{latency_score} || 0;
            if ( $score < $threshold ) {
                $score = $threshold;
            }
            else {
                $score += $latency > $score ? $score : $latency;
            }
            $self->{latency_score} = $score;
        }
        else {
            $self->{latency_score} = $latency;
        }
    }
    return;
}

sub fill_buffer_init {
    my $self    = shift;
    my $message = shift;
    if ( $message->[FROM] eq 'Inet_AtoN' ) {
        #
        # we're a connection starting up, and our Inet_AtoN job is
        # sending us the results of the DNS lookup.
        # see also inet_client_async(), dns_lookup(), and init_socket()
        #
        my $okay = eval {
            $self->init_socket( $message->[PAYLOAD] );
            return 1;
        };
        if ( not $okay ) {
            $self->stderr("ERROR: init_socket() failed: $@");
            $self->close_filehandle('reconnect');
        }
        return;
    }
    return $self->fill_buffer($message);
}

sub fill_fh_sync_SSL {
    my $self        = shift;
    my $message     = shift;
    my $fh          = $self->{fh} or return;
    my $packed      = $message->packed;
    my $packed_size = length ${$packed};
    my $wrote       = 0;

    while ( $wrote < $packed_size ) {
        my $rv = syswrite $fh, ${$packed}, $packed_size - $wrote, $wrote;
        $rv = 0 if ( not defined $rv );
        last if ( not $rv );
        $wrote += $rv;
    }
    die "ERROR: wrote $wrote < $packed_size; $!\n"
        if ( $wrote != $packed_size );
    $self->{counter}++;
    $self->{largest_msg_sent} = $packed_size
        if ( $packed_size > $self->{largest_msg_sent} );
    $self->{bytes_written} += $wrote;
    return $wrote;
}

sub handle_EOF {
    my $self   = shift;
    my $on_EOF = $self->{on_EOF};
    if ( $on_EOF eq 'reconnect' ) {
        push @Tachikoma::Closing, sub {
            $self->close_filehandle('reconnect');
        };
    }
    else {
        $self->notify('EOF');
        $self->SUPER::handle_EOF;
    }
    return;
}

sub close_filehandle {
    my $self      = shift;
    my $reconnect = shift;
    $self->SUPER::close_filehandle;
    if ( $self->{type} eq 'listen' and $self->{filename} ) {
        unlink $self->{filename} or $self->stderr("ERROR: unlink: $!");
    }
    if ( $self->{last_upbeat} ) {
        $self->{last_upbeat}   = $Tachikoma::Now;
        $self->{last_downbeat} = $Tachikoma::Now;
    }
    if ( $reconnect and $self->{on_EOF} eq 'reconnect' ) {
        my $reconnecting = ( grep $_ eq $self, @Tachikoma::Reconnect )[0];
        push @Tachikoma::Reconnect, $self if ( not $reconnecting );
    }
    return;
}

sub reconnect {    ## no critic (ProhibitExcessComplexity)
    my $self = shift;
    return
        if ( not $self->{name}
        or not exists $Tachikoma::Nodes{ $self->{name} } );
    my $socket = $self->{fh};
    my $rv     = undef;
    if ( not $socket or not fileno $socket ) {
        if ( $self->{filename} ) {
            socket $socket, PF_UNIX, SOCK_STREAM, 0
                or die "FAILED: socket: $!";
            setsockopts($socket);
            $self->close_filehandle;
            $self->{fill} = $self->{fill_modes}->{fill};
            $self->fh($socket);
            if ( not connect $socket, pack_sockaddr_un( $self->{filename} ) )
            {
                $self->print_less_often(
                    "WARNING: reconnect: couldn't connect(): $!");
                $self->close_filehandle;
                return 'try again';
            }
        }
        elsif ( $self->{flags} & TK_SYNC ) {
            die 'FAILED: TK_SYNC not supported';
        }
        else {
            if ( not $self->{address} ) {
                if ( $Tachikoma::Inet_AtoN_Serial
                    == $self->{inet_aton_serial} )
                {
                    return 'try again' if ( $Tachikoma::Nodes{'Inet_AtoN'} );
                }
                elsif ( not $Tachikoma::Nodes{'Inet_AtoN'} ) {
                    $self->stderr('WARNING: restarting Inet_AtoN');
                }
            }
            $self->dns_lookup;
            $rv = 'try again';
        }
        $self->{high_water_mark}  = 0;
        $self->{largest_msg_sent} = 0;
        $self->{latency_score}    = undef;
    }
    if ( $self->{filename} ) {
        my $okay = eval {
            $self->register_reader_node;
            return 1;
        };
        if ( not $okay ) {
            $self->stderr(
                "WARNING: reconnect: couldn't register_reader_node(): $@");
            $self->close_filehandle;
            return 'try again';
        }
        $self->stderr( 'reconnect: ', $! || 'success' );
        if ( $self->{use_SSL} ) {
            if ( not $self->start_SSL_connection ) {
                $self->close_filehandle;
                return 'try again';
            }
        }
        else {
            $self->init_connect;
        }
    }
    else {
        $self->print_less_often('reconnect: looking up hostname')
            if ( not $self->{address} );
    }
    $self->notify('reconnect');
    return $rv;
}

sub dns_lookup {
    my $self = shift;
    #
    # When in doubt, use brute force--let's just fork our own resolver.
    # This turns out to perform quite well:
    #
    my $job_controller = $Tachikoma::Nodes{'jobs'};
    if ( not $job_controller ) {
        require Tachikoma::Nodes::JobController;
        my $interpreter = $Tachikoma::Nodes{'command_interpreter'}
            or die q{FAILED: couldn't find interpreter};
        $job_controller = Tachikoma::Nodes::JobController->new;
        $job_controller->name('jobs');
        $job_controller->sink($interpreter);
    }
    my $inet_aton = $Tachikoma::Nodes{'Inet_AtoN'};
    if ( not $inet_aton ) {
        $inet_aton = $job_controller->start_job('Inet_AtoN');
        $Tachikoma::Inet_AtoN_Serial++;
    }
    $self->{inet_aton_serial} = $Tachikoma::Inet_AtoN_Serial;
    #
    # Send the hostname to our Inet_AtoN job.
    # When it sends the reply, we pick it up with fill_buffer_init().
    #
    # see also inet_client_async(), fill_buffer_init(), init_socket(),
    #      and reconnect()
    #
    my $message = Tachikoma::Message->new;
    $message->[TYPE]    = TM_BYTESTREAM;
    $message->[FROM]    = $self->{name};
    $message->[PAYLOAD] = $self->{hostname};
    $inet_aton->fill($message);
    $self->{fill}    = $self->{fill_modes}->{init};
    $self->{address} = undef;
    return;
}

sub dump_config {    ## no critic (ProhibitExcessComplexity)
    my $self     = shift;
    my $response = q{};
    if ( $self->{type} eq 'listen' ) {
        $response = $self->{filename} ? 'listen_unix' : 'listen_inet';
        if ( ref $self eq 'Tachikoma::Nodes::STDIO' ) {
            $response .= ' --io';
        }
        $response .= ' --max_unanswered=' . $self->{max_unanswered}
            if ( $self->{max_unanswered} );
        $response .= ' --use-ssl' if ( $self->{use_SSL} );
        $response .= ' --ssl-delegate=' . $self->{delegates}->{ssl}
            if ( $self->{delegates}->{ssl} );
        $response .= ' --delegate=' . $self->{delegates}->{tachikoma}
            if ( $self->{delegates}->{tachikoma} );
        if ( $self->{filename} ) {
            $response .= ' --perms=' . $self->{fileperms}
                if ( $self->{fileperms} );
            $response .= ' --gid=' . $self->{filegid} if ( $self->{filegid} );
            $response .= " $self->{filename} $self->{name}\n";
        }
        else {
            $response .= " $self->{name}\n";
        }
        my $registrations = $self->{registrations};
        for my $event_type ( keys %{$registrations} ) {
            for my $path ( keys %{ $registrations->{$event_type} } ) {
                $response .= "register $self->{name} $path $event_type\n"
                    if ( not $registrations->{$event_type}->{$path} );
            }
        }
    }
    elsif ( $self->{type} eq 'connect' ) {
        $response = $self->{filename} ? 'connect_unix' : 'connect_inet';
        if ( ref $self eq 'Tachikoma::Nodes::STDIO' ) {
            $response .= ' --io';
            $response .= ' --reconnect' if ( $self->{on_EOF} eq 'reconnect' );
        }
        $response .= ' --use-ssl' if ( $self->{use_SSL} );
        if ( $self->{filename} ) {
            $response .= " $self->{filename} $self->{name}\n";
        }
        else {
            $response .= " $self->{hostname}";
            $response .= ":$self->{port}" if ( $self->{port} != 4230 );
            $response .= " $self->{name}"
                if ( $self->{name} ne $self->{hostname} );
            $response .= "\n";
        }
    }
    else {
        $response = $self->SUPER::dump_config;
    }
    return $response;
}

sub hostname {
    my $self = shift;
    if (@_) {
        $self->{hostname} = shift;
    }
    return $self->{hostname};
}

sub address {
    my $self = shift;
    if (@_) {
        $self->{address} = shift;
    }
    return $self->{address};
}

sub port {
    my $self = shift;
    if (@_) {
        $self->{port} = shift;
    }
    return $self->{port};
}

sub filename {
    my $self = shift;
    if (@_) {
        $self->{filename} = shift;
    }
    return $self->{filename};
}

sub fileperms {
    my $self = shift;
    if (@_) {
        $self->{fileperms} = shift;
    }
    return $self->{fileperms};
}

sub filegid {
    my $self = shift;
    if (@_) {
        $self->{filegid} = shift;
    }
    return $self->{filegid};
}

sub use_SSL {
    my $self = shift;
    if (@_) {
        $self->{use_SSL} = shift;
    }
    return $self->{use_SSL};
}

sub SSL_config {
    my $self = shift;
    if (@_) {
        my $ssl_config = shift;
        $self->{SSL_config} = $ssl_config;
    }
    if ( not defined $self->{SSL_config} ) {
        $self->{SSL_config} = \%SSL_Config;
    }
    return $self->{SSL_config};
}

sub auth_challenge {
    my $self = shift;
    if (@_) {
        $self->{auth_challenge} = shift;
    }
    return $self->{auth_challenge};
}

sub auth_timestamp {
    my $self = shift;
    if (@_) {
        $self->{auth_timestamp} = shift;
    }
    return $self->{auth_timestamp};
}

sub scheme {
    my $self = shift;
    if (@_) {
        my $scheme = shift;
        die "invalid scheme: $scheme\n"
            if ($scheme ne 'rsa'
            and $scheme ne 'sha256'
            and $scheme ne 'ed25519' );
        if ( $scheme eq 'ed25519' ) {
            die "Ed25519 not supported\n"  if ( not $USE_SODIUM );
            die "Ed25519 not configured\n" if ( not $Private_Ed25519_Key );
        }
        $self->{scheme} = $scheme;
    }
    return $self->{scheme};
}

sub delegates {
    my $self = shift;
    if (@_) {
        $self->{delegates} = shift;
    }
    return $self->{delegates};
}

sub last_upbeat {
    my $self = shift;
    if (@_) {
        $self->{last_upbeat} = shift;
    }
    return $self->{last_upbeat};
}

sub last_downbeat {
    my $self = shift;
    if (@_) {
        $self->{last_downbeat} = shift;
    }
    return $self->{last_downbeat};
}

sub latency_score {
    my $self = shift;
    if (@_) {
        $self->{latency_score} = shift;
    }
    return $self->{latency_score};
}

sub inet_aton_serial {
    my $self = shift;
    if (@_) {
        $self->{inet_aton_serial} = shift;
    }
    return $self->{inet_aton_serial};
}

1;