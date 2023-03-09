#!/usr/bin/perl

# subscribe to public_translated for UTF8 encoded messages
# subscribe to action_translated for UTF8 CTCP ACTION message
# subscribe to bot_mentioned for UTF8 public messages where bot is addressed
# fill $self->{triggers}->{$pattern}->{$coderef} to authomatically get callback when pattern is mentioned
# fill $self->{commands}->{$pattern}->{$coderef} to authomatically get callback when bot AND pattern is mentioned
# use $self->say($channel, @lines) to encoding-safe speak on channel (multilines OK, lines should be UTF8)
# use $self->action($channel, $action) to encoding-safe CTCP ACTION on channel (should be UTF8)
# don't forget to do  $self->SUPER::PCI_register( @_[1 .. $#_] );

package ePotsV2::HowLong;

use parent ePotsV2::Interactive;


use POE::Component::IRC::Plugin qw( :ALL );
use IRC::Utils qw( parse_user );
use Encode;
use utf8;
use MLDBM qw( DB_File Storable );
use DB_File;
use DBM_Filter;


# Plugin object constructor
 sub new {
     my $package = shift;
     my $confdir = shift;

     $confdir = 'data/HowLong' unless defined $confdir;
     $confdir = 'data/HowLong' if $confdir eq '';

     return bless {
         # magic word
         commands => { 
             "дембель" => \&say_how_long,
             "до дембеля" => \&remember,
         },
         base => undef,
         datadir => $confdir,
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

     # close base gracefully
     if(  defined( $self->{base} ) ) {
       $self->{base}->{handle}->sync();
       $self->{base}->{handle} = undef;
       untie %{$self->{base}->{tied}};
     }

     return 1;
 }


 sub read_config {
     my $self=shift;
     my $datadir=$self->{datadir};

     my $file = "$datadir/howlong.db";
     my %base;
     my $ref = tie %base, 'MLDBM', "$file", O_CREAT|O_RDWR, 0644;
     $self->{base}->{handle} = $ref;
     $self->{base}->{tied} = \%base;
     $self->{base}->{handle}->sync();

     return;
 }


 sub say_how_long {
   my ( $self, $who, $where, $line, $i_called, $request_text, $trigger, $triggered, $before_trigger, $after_trigger ) = @_;

   $where=lc($where);

   my $nick = parse_user( $who );
   my $lnick = lc($nick);

   if( defined( $self->{base}->{tied}->{$lnick} ) ) {
     my $days = int(( $self->{base}->{tied}->{$lnick} - time() ) / ( 60 * 60 * 24 )) + 1;
     if( $days <= 0 ) {
       $self->say( $where, $nick . ", дык, вроде, " . $self->syntax( -$days ) . " назад" );
     } else {
       $self->say( $where, $nick . ", " . $self->syntax( $days ) );
     }
   } else {
     $self->say( $where, $nick . ", тебе - как до Пекина раком" );
   }

   return PCI_EAT_ALL;
 }

 sub remember {
   my ( $self, $who, $where, $line, $i_called, $request_text, $trigger, $triggered, $before_trigger, $after_trigger ) = @_;

   $where=lc($where);

   my $nick = parse_user( $who );
   my $lnick = lc($nick);

   if ( $after_trigger =~ /\s*(\d+)\s*.*/ ) {
     $self->{base}->{tied}->{$lnick} = time() + $1 * 60 * 60 * 24 ;
     $self->{base}->{handle}->sync();
     $self->say( $where, $nick . ", OK" );
   } else {
     return PCI_EAT_NONE;
   }

   return PCI_EAT_ALL;
 }


 ##### utility ######
 # return correct form of numerical (with numerical itself)
 sub syntax {
   my $self = shift;
   my $num  = shift;

   my $restnum = $num % 100;
   my @syntax1 = ( "остался", "осталось", "осталось" );
   my @syntax2 = ( "день", "дня", "дней" );

   return $syntax1[
      ( $restnum > 20 || $restnum < 10 ) ? (
        $restnum % 10 == 1 ? 0 : (
          ($restnum % 10) =~ /2|3|4/ ? 1 : 2
        )
      ) : 2 
      ] . " $num " . $syntax2[
      ( $restnum > 20 || $restnum < 10 ) ? (
        $restnum % 10 == 1 ? 0 : (
          ($restnum % 10) =~ /2|3|4/ ? 1 : 2
        )
      ) : 2 
   ];
 }

1;
