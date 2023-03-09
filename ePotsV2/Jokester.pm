#!/usr/bin/perl

# subscribe to public_translated for UTF8 encoded messages
# subscribe to action_translated for UTF8 CTCP ACTION message
# subscribe to bot_mentioned for UTF8 public messages where bot is addressed
# fill $self->{triggers}->{$pattern}->{$coderef} to authomatically get callback when pattern is mentioned
# fill $self->{commands}->{$pattern}->{$coderef} to authomatically get callback when bot AND pattern is mentioned
# use $self->say($channel, @lines) to encoding-safe speak on channel (multilines OK, lines should be UTF8)
# use $self->action($channel, $action) to encoding-safe CTCP ACTION on channel (should be UTF8)
# don't forget to do  $self->SUPER::PCI_register( @_[1 .. $#_] );

package ePotsV2::Jokester;

use parent ePotsV2::Interactive;


use POE::Component::IRC::Plugin qw( :ALL );
use IRC::Utils qw( parse_user );
use Encode;
use utf8;

use DB_File;
use DBM_Filter;

#use Data::Dumper;

# Plugin object constructor
 sub new {
     my $package = shift;
     my $confdir = shift;

     $confdir = 'data/Jokester' unless defined $confdir;
     $confdir = 'data/Jokester' if $confdir eq '';

     return bless {
         datadir => $confdir,
         commands => {}, # $mask => \&coderef
         masks => {},    # mask => [ totalreccount, [bases] ]
         bases => {},    # $bases->{$name} = [reccount, \@tiedarray ];
     }, $package;
 }

 sub PCI_register {
     my ($self, $irc) = @_[0 .. 1];
     $self->SUPER::PCI_register( @_[1 .. $#_] );

     $self->read_config();
     $irc->plugin_register( $self, 'SERVER', qw( bot_mentioned ) );

     return 1;
 }

 sub PCI_unregister {
     my ($self, $irc) = @_[0 .. 1];
     $self->SUPER::PCI_unregister( @_[1 .. $#_] );

     # close bases gracefully
     foreach $base (keys %{$self->{bases}} ) {
       untie @{$self->{bases}->{$base}->[1]} 
              if defined $self->{bases}->{$base}->[1];
     }

     return 1;
 }


 sub read_config {
  my $self=shift;
  my $datadir=$self->{datadir};
  my $conffile="$datadir/Jokester.conf";

  open( IN, "<:encoding(UTF-8)", $conffile) or print "Unable to open config file $conffile: $!\n";
  while(<IN>) {
    chomp;
    if( /^mask\s+\"(.*)\"\s+(.*)$/ ) {
      my $mask = $1;
      my $newmask = lc($mask);  # perl bug!!! don't use lc($1)
      my @bases = split( '\s+', $2 );
      $self->{masks}->{$newmask} = [undef,[@bases]];
    }
  }
  CORE::close IN;
  foreach my $mask (keys %{$self->{masks}}) {
    $self->{masks}->{$mask}->[0] = 0;
    foreach my $base (@{$self->{masks}->{$mask}->[1]}) {
      unless( defined($self->{bases}->{$base}) ) {
        my @base;
        my $ref = tie( @base, 'DB_File', $self->{datadir}."/$base.db", O_CREAT|O_RDWR, 0644, $DB_RECNO );
        # we are unicode-ready!
        $ref->Filter_Push( 'encode', 'utf-8' );
        $self->{bases}->{$base} = [ scalar(@base), undef ];
        untie @base;
      } 
      $self->{masks}->{$mask}->[0] += $self->{bases}->{$base}->[0];
    }
    $self->{commands}->{$mask} = \&say_joke;
  }
  return undef;
 }


 sub say_joke {
   my ( $self, $who, $where, $line, $i_called, $request_text, $trigger, $triggered, $before_trigger, $after_trigger ) = @_;

   my $nick = parse_user( $who );

   my ( $c, $db ) = (@{$self->{masks}->{$trigger}}) or return PCI_EAT_NONE;

   my $ind = int(rand $c);
   my $curr=0;
   my $base;
   for( my $i=0; $i<@$db; $i++ ) {
      $base=$db->[$i];
      $curr=$ind;
      $ind -= $self->{bases}->{$base}->[0];
      last if $ind < 0;
   }
   my @cdb;
   my $ref = tie( @cdb, 'DB_File', $self->{datadir}."/$base.db", O_CREAT|O_RDWR, 0644, $DB_RECNO );
   $ref->Filter_Push( 'encode', 'utf-8' );
   my @reply = map( "  $_", split( '\/\/', $cdb[$curr] ) );
   untie @cdb;
   $self->say( $where, "$nick:", @reply );

   return PCI_EAT_ALL;
 }


1;
