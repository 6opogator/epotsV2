#!/usr/bin/perl

package ePotsV2;

 use strict;
 use warnings;
 use POE qw(Component::IRC::State Component::IRC::Plugin::AutoJoin Component::IRC::Plugin::Connector Component::IRC::Plugin::CTCP);
 use POE::Component::IRC::Plugin::PlugMan;
 use POE::Component::IRC::Plugin::NickServID;
 use IRC::Utils qw(is_valid_chan_name);
 use ePotsV2::IRC::State;
 use ePotsV2::UserManager;
 use Encode;
 use Data::Dumper;

 binmode STDOUT, ':utf8';
 binmode STDERR, ':utf8';

 sub new {
     my $package = shift;
     my $self = bless {}, $package;

     $self->configure;

     return $self;
 }

 sub configure {
     my $self = shift;

     my $conffile = "ePotsV2.conf";

     open IN, "<$conffile" or die "Unable to open config file $conffile";
     binmode IN, ":utf8";
     while(<IN>) {
       chomp;
       next if /^\s*#/;
       $self->{nick}      = $1 if /^nick\s+(\S+)$/i;
       $self->{uid}       = $1 if /^user\s+(\S+)$/i;
       $self->{realname}  = $1 if /^ircname\s+(\S.*)$/i;
       push(@{$self->{aliases}}, $1)
                               if /^alias\s+(\S+)$/i;
       $self->{channels}->{$1}=&config_channel($2)
                               if /^channel\s+(\S+)\s*(.*)$/i;
       push(@{$self->{modules}}, [ $1, $2 ] )
                               if /^plugin\s+(\S+)\s+(\S+)$/i;
       push(@{$self->{modules}}, [ $1, '' ] )
                               if /^plugin\s+(\S+)$/i;
       ($self->{server},$self->{encoding})  = ($1, $2) 
                               if /^server\s+(\S+)\s+(\S+)$/i;
       $self->{port}      = $1 if /^port\s+(\d+)$/i;
       $self->{awaypoll}  = $1 if /^awaypoll\s+(\d+)$/i;
       $self->{debug}     = 1  if /^debug$/i;
       $self->{ssl}       = 1  if /^ssl$/i;
       $self->{flood}     = 1  if /^i_can_flood$/i;
       $self->{flood_delay} = $1  if /^flood_delay\s+(\S+)$/i;
       $self->{flood_cps}   = $1  if /^flood_cps\s+(\S+)$/i;
       $self->{nickserv_pass} = $1  if /^nickserv_pass\s+(\S+)$/i;

     }
     CORE::close IN;

     $self->{awaypoll} = 300 unless defined $self->{awaypoll};
     $self->{ssl} = 0        unless defined $self->{ssl};
     $self->{flood} = 0      unless defined $self->{flood};
     $self->{flood_delay} = 10  unless defined $self->{flood_delay};
     $self->{flood_cps}   = 120 unless defined $self->{flood_cps};
     push(@{$self->{aliases}}, $self->{nick});

     return undef;
 }

 sub config_channel {
    my @params = split(/\s/, shift);
    my $result = {};
    $result->{key} = '';
    $result->{sleepmode} = 0;
    while(@params) {
      my $param=shift(@params);
      if( $param =~ /\+(.*)/ ) {
        $result->{'setmode'} = [] unless defined $result->{'setmode'};
        my @modes=split( "", $1 );
        foreach my $m ( split( "", $1 ) ) {
          if( $m =~ /l|k|o|b|v/ ) {
            my $mpar=shift(@params);
            unless( defined $mpar ) {
print "error in config: mode +$m require parameter. mode ignored.\n";
              next;
            }
            push @{$result->{'setmode'}}, [ $m, $mpar ];
          } else {
            push @{$result->{'setmode'}}, $m;
          }
        }
      } elsif( $param =~ /\-(.*)/ ) {
        $result->{'resetmode'} = [] unless defined $result->{'resetmode'};
        my @modes=split( "", $1 );
        foreach my $m ( split( "", $1 ) ) {
          if( $m =~ /o|b|v/ ) {
            my $mpar=shift(@params);
            unless( defined $mpar ) {
print "error in config: mode -$m require parameter. mode ignored.\n";
              next;
            }
            push @{$result->{'resetmode'}}, [ $m, $mpar ];
          } else {
            push @{$result->{'resetmode'}}, $m;
          }
        }
      } else {
        $result->{'key'} = $param;
      }
    }
    return $result;
  }

  sub run {
    my $self = shift;

    # We create a new PoCo-IRC object
    my $irc =  ePotsV2::IRC::State->spawn(            #POE::Component::IRC::State->spawn( #
        nick => $self->{nick},
        username => $self->{uid},
        ircname => $self->{realname},
        server  => $self->{server},
        port    => $self->{port},
        UseSSL  => $self->{ssl},
        AwayPoll => 300,
        Flood   => $self->{flood},                   # no flood protection at all
        flood_delay => $self->{flood_delay},         # delay between messages if flood protection is on (default 10)
        flood_cps   => $self->{flood_cps},           # max characters-per-second if flood protection is on (default 120)
        bot     => $self,                            # dirty hack
        ) or die "Unable to create PoCo-IRC-State object! $!";

    $self->{irc} = $irc;

    POE::Session->create(
        package_states => [
           ePotsV2 => [ qw( _default _start irc_bot_say irc_bot_action irc_public irc_ctcp_action irc_msg ) ],
        ],
        heap => { irc => $irc, bot => $self },
    ) or die "Unable to create POE::Session object! $!";

    $poe_kernel->run();

  }

#
# $poe_kernel->run();
#
 sub _start {
     my ($kernel, $heap) = @_[KERNEL ,HEAP];

     # retrieve our component's object from the heap where we stashed it
     my $irc = $heap->{irc};
     my $bot = $heap->{bot};

     $heap->{connector} = POE::Component::IRC::Plugin::Connector->new();
     $irc->plugin_add( 'Connector' => $heap->{connector} );

     my %channels = ();
     foreach  my $channel ( keys %{$bot->{channels}} ) {
       $channels{$channel} = $bot->{channels}->{$channel}->{'key'};
     }

     $irc->plugin_add('AutoJoin', 
              POE::Component::IRC::Plugin::AutoJoin->new( Channels => \%channels, RejoinOnKick => 1 ));

     $irc->plugin_add( 'CTCP' => POE::Component::IRC::Plugin::CTCP->new(
         version => "ePots 2.0",
         clientinfo => "Electronic Pots",
	 userinfo => "Electronic Pots",
         source => "POE::Component::IRC v".$POE::Component::IRC::VERSION." + perl v.".$] ) );

     if( defined( $bot->{nickserv_pass} ) ) {
        $irc->plugin_add( 'NickServID', POE::Component::IRC::Plugin::NickServID->new(
             Password => $bot->{nickserv_pass} ));
     }

     $bot->{user_manager} = new ePotsV2::UserManager();
     $bot->{plugin_manager} = POE::Component::IRC::Plugin::PlugMan->new( auth_sub => \&plugman_auth_sub, debug => 1 );
     $irc->plugin_add( 'PlugMan' => $bot->{plugin_manager} );

     foreach my $module ( @{$bot->{modules}} ) {
         $bot->load_module( @$module );
     }

     $irc->yield( register => 'all' );
     $irc->yield( connect => { } );
     return;
 }

 sub load_module {
     my $self = shift;
     my $module = shift;
     my $params = shift;


print "Loading $module\n";
     $self->{plugin_manager}->load( $module, "ePotsV2::$module", $params );

#     eval( "use ".$module );
#     if( $@ ) {
#       print "Unable to compile module $module: $! $@\n";
#       return;
#     }
#
#     my $modobj = eval( "new $module( $params )" );
#     if( $@ ) {
#       print "Unable to init module $module: $! $@\n";
#       return;
#     }
#     $self->{irc}->plugin_add( $module, $modobj );
 }

 sub irc_public {
     my ($kernel, $who, $where, $what) = @_[SENDER, ARG0 .. ARG2];
#     my $nick = ( split /!/, $who )[0];
     my $channel = $where->[0];
     my $self = $_[HEAP] -> {bot};
     my $irc = $_[HEAP] -> {irc};

     my $what_ = $self->decode_from_server( $what );

     $irc->send_event( irc_public_translated => $who => $where => $what_ );
     foreach my $nick ( @{$self->{aliases}} ) {
#       my $pattern = "^$nick?[\\s.,:>]";
       if( $what_ =~ m/^\s*[@%]?\Q$nick\E[:,;.!?~]?\s+(.*)$/i ) {
         $irc->send_event( irc_bot_mentioned => $who => $where => $nick => $1 => $what_ );
         last;
       }
     }

     return;
 }

 sub irc_ctcp_action {
     my ($kernel, $who, $where, $what) = @_[SENDER, ARG0 .. ARG2];
#     my $nick = ( split /!/, $who )[0];
     my $channel = $where->[0];
     my $self = $_[HEAP] -> {bot};
     my $irc = $_[HEAP] -> {irc};

     my $what_ = $self->decode_from_server( $what );

     $irc->send_event( irc_action_translated => $who => $where => $what_ );

     return;
 }

 sub irc_msg {
     my ($kernel, $who, $where, $what) = @_[SENDER, ARG0 .. ARG2];
#     my $nick = ( split /!/, $who )[0];
     my $channel = $where->[0];
     my $self = $_[HEAP] -> {bot};
     my $irc = $_[HEAP] -> {irc};

     my $what_ = $self->decode_from_server( $what );

     $irc->send_event( irc_msg_translated => $who => $where => $what_ );

     return;
 }

# sub irc_isupport {
#     my $isupport = $_[ARG0];
##     print "Known prefix: ".Dumper($isupport->isupport("PREFIX"))."\n";
##     print Dumper( $_[SENDER]->get_heap()->plugin_list() ), "\n";
#     return;
# }
#
# sub lag_o_meter {
#     my ($kernel,$heap) = @_[KERNEL,HEAP];
#     print 'Time: ' . time() . ' Lag: ' . $heap->{connector}->lag() . "\n";
#     $kernel->delay( 'lag_o_meter' => 60 );
#     return;
# }
#

 sub irc_plugin_error {
     my $message = $_[ARG0];
     print STDERR "Plugin error: $message\n";
     return;
 }

# # We registered for all events, this will produce some debug info.
 sub _default {
     my ($event, $args) = @_[ARG0 .. $#_];
     my @output = ( "$event: " );
     my ($kernel, $heap) = @_[KERNEL ,HEAP];
     my $bot = $heap->{bot};
     my @translated = ( "irc_public_translated", "irc_bot_mentioned", "irc_msg_translated", "irc_action_translated" );

     for my $arg (@$args) {
         if ( ref $arg eq 'ARRAY' ) {
             if( grep( $event eq $_, @translated ) ) {
                push( @output, '[' . join(', ', @$arg ) . ']' );
             } else {
                push( @output, $bot->decode_from_server( '[' . join(', ', @$arg ) . ']' ) );
             }
         }
         elsif( defined $arg ) {
             if( grep( $event eq $_, @translated ) ) {
                push ( @output, "'$arg'" );
             } else {
                push ( @output, $bot->decode_from_server( "'$arg'" ) );
             }
         } else {
             push ( @output, "__undef__" );
         }
     }
     print STDERR join '/', @output, "\n" if $bot->{debug};
     return;
 }

 sub irc_bot_say {
     my ($where, $arg) = @_[ARG0 .. $#_];
     my ($kernel, $heap) = @_[KERNEL ,HEAP];
     my $irc = $heap->{irc};
     my $bot = $heap->{bot};

     $irc->yield(privmsg => $where => $bot->encode_to_server( $arg ) );
 }

 sub irc_bot_action {
     my ($where, $arg) = @_[ARG0 .. $#_];
     my ($kernel, $heap) = @_[KERNEL ,HEAP];
     my $irc = $heap->{irc};
     my $bot = $heap->{bot};

     $irc->yield(ctcp => $where => $bot->encode_to_server( "ACTION $arg" ) );
 }

 sub decode_from_server {
     my ($self, $what) = @_;
     return decode( $self->{encoding}, $what );
 }

 sub encode_to_server {
     my ($self, $what) = @_;
     return encode( $self->{encoding}, $what );
 }

 sub plugman_auth_sub {
     my ($irc, $who, $where) = @_;
     my $self = $irc->{bot};

     # no control in public channels
     return 0 if is_valid_chan_name( $where, $irc->isupport("CHANTYPES") );
     # no user manager in effect
     return 0 unless defined $self->{user_manager};
     # let user manager decide
     return $self->{user_manager}->is_my_op( $who );
 }

1;
