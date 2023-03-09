#!/usr/bin/perl

# subscribe to public_translated for UTF8 encoded messages
# subscribe to action_translated for UTF8 CTCP ACTION message
# subscribe to bot_mentioned for UTF8 public messages where bot is addressed
# fill $self->{triggers}->{$pattern}->{$coderef} to authomatically get callback when pattern is mentioned
# fill $self->{commands}->{$pattern}->{$coderef} to authomatically get callback when bot AND pattern is mentioned
# use $self->say($channel, @lines) to encoding-safe speak on channel (multilines OK, lines should be UTF8)
# use $self->action($channel, $action) to encoding-safe CTCP ACTION on channel (should be UTF8)
# don't forget to do  $self->SUPER::PCI_register( @_[1 .. $#_] );

package ePotsV2::Topicster;

use parent ePotsV2::Interactive;


use POE::Component::IRC::Plugin qw( :ALL );
use IRC::Utils qw( parse_user );
use Encode;
use utf8;
use DB_File;
use DBM_Filter;


# Plugin object constructor
 sub new {
     my $package = shift;
     my $confdir = shift;

     $confdir = 'data/Topicster' unless defined $confdir;
     $confdir = 'data/Topicster' if $confdir eq '';

     return bless {
         # magic word
         commands => { 
             "топ[ие][кг]" => \&say_topic,
         },
         datadir => $confdir,
         bases => {},
     }, $package;
 }

 sub PCI_register {
     my ($self, $irc) = @_[0 .. 1];
     $self->SUPER::PCI_register( @_[1 .. $#_] );

     $self->read_config();
     $irc->plugin_register( $self, 'SERVER', qw( bot_mentioned topic 332 333 ) );

     return 1;
 }

 sub PCI_unregister {
     my ($self, $irc) = @_[0 .. 1];
     $self->SUPER::PCI_unregister( @_[1 .. $#_] );

     # close bases gracefully
     foreach $base (keys %{$self->{bases}} ) {
       $self->{bases}->{$base}->[2]->sync();
       $self->{bases}->{$base}->[2] = undef;
       untie @{$self->{bases}->{$base}->[1]} 
              if defined $self->{bases}->{$base}->[1];
     }

     return 1;
 }


 sub read_config {
     my $self=shift;
     my $datadir=$self->{datadir};
     my $conffile="$datadir/Topicster.conf";

     open IN, "<$conffile" or die "Unable to open config file $conffile";
     binmode IN, ":utf8";
     while(<IN>) {
        chomp;
        if( /^channel\s+(\#\S+)\s+(.*)$/ ) {
           my $chan = lc($1);
           my $db   = $2;
           $self->{bases}->{$chan} = [ "$datadir/$db", undef, undef ];
        }
     }
     CORE::close IN;

     # {bases}->{$channel}->[ $db_filename, $tied_array_ref, $tied_object ]

     foreach my $chan (keys %{$self->{bases}}) {
        my $file = $self->{bases}->{$chan}->[0];
        my @base;
        my $ref = tie @base, 'DB_File', "$file", O_CREAT|O_RDWR, 0644, $DB_RECNO;
        $self->{bases}->{$chan}->[1] = \@base;
        $self->{bases}->{$chan}->[2] = $ref;
        # we are unicode-ready!
        $ref->Filter_Push( 'encode', 'utf-8' );
        $ref->sync();
     }

     return;
 }


 sub say_topic {
   my ( $self, $who, $where, $line, $i_called, $request_text, $trigger, $triggered, $before_trigger, $after_trigger ) = @_;

   $where=lc($where);

   return PCI_EAT_NONE unless defined $self->{bases}->{$where};

   my $nick = parse_user( $who );
   my $nonurl = ( $request_text =~ m/не [уu][рr][лl]/i );

   # number of elements in db
   my $c = scalar( @{$self->{bases}->{$where}->[1]} );
   my $text;

   # skip some URL's if we wnat non-url
   my $count = 0;
   my $limit = 10;
   do {
     my $ind = int(rand $c);
     $text = $self->{bases}->{$where}->[1]->[$ind];
     $count++;
   } while( $nonurl && ($count < $limit) && ( $text =~ /^https?:\/\//i ) );

   if( ( $nonurl && ( $text =~ /^https?:\/\//i ) ) ) {
     $self->say( $where, $nick . ", извини, сплошные урлы лезут, держи что есть:  " . $text );
   } else {
     $self->say( $where, $nick . ", держи:  " . $text );
   }

   return PCI_EAT_ALL;
 }

 sub S_topic {
   my ($self, $irc) = splice @_, 0, 2;
   my ($who, $chan, $topic, $hashref) = @_;
   my $chan_ = lc($$chan);
   return PCI_EAT_NONE unless defined $self->{bases}->{$chan_};
   $self->register_topic( $chan_, $irc->{bot}->decode_from_server( $$topic ), $$who, ${$hashref}->{SetAt} );

   return PCI_EAT_NONE;
 }

 # 332/333 messages are sent by server when joining channel with current topic info
 sub S_332 {
   my ($self, $irc) = splice @_, 0, 2;
   my ($server, $raw, $refref) = @_;
   my ($chan, $topic) = @{$$refref}[0,1];
   $chan = lc($chan);
   return PCI_EAT_NONE unless defined $self->{bases}->{$chan};
   $self->{$chan}->{pending} = $irc->{bot}->decode_from_server( $topic );

   return PCI_EAT_NONE;
 }

 sub S_333 {
   my ($self, $irc) = splice @_, 0, 2;
   my ($server, $raw, $refref) = @_;
   my ($chan, $setby, $setwhen) = @{$$refref}[0 .. 2];
   $chan = lc($chan);
   return PCI_EAT_NONE unless defined $self->{bases}->{$chan};

   $self->register_topic( $chan, $self->{$chan}->{pending}, $setby, $setwhen );

   return PCI_EAT_NONE;
 }

 sub register_topic {
   my ( $self, $chan, $topic, $setby, $setwhen ) = @_;

   $chan = lc($chan);

   return unless defined $self->{bases}->{$chan};

   # check for duplicate
   my $last = @{$self->{bases}->{$chan}->[1]}[$#{$self->{bases}->{$chan}->[1]}];
   if( !defined( $last ) || $last ne $topic ) {
      push( @{$self->{bases}->{$chan}->[1]}, $topic );
      $self->{bases}->{$chan}->[2]->sync();
   }
 }

1;
