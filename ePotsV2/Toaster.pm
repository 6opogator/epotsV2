#!/usr/bin/perl

#!/usr/bin/perl

# subscribe to public_translated for UTF8 encoded messages
# subscribe to action_translated for UTF8 CTCP ACTION message
# subscribe to bot_mentioned for UTF8 public messages where bot is addressed
# fill $self->{triggers}->{$pattern}->{$coderef} to authomatically get callback when pattern is mentioned
# fill $self->{commands}->{$pattern}->{$coderef} to authomatically get callback when bot AND pattern is mentioned
# use $self->say($channel, @lines) to encoding-safe speak on channel (multilines OK, lines should be UTF8)
# use $self->action($channel, $action) to encoding-safe CTCP ACTION on channel (should be UTF8)
# don't forget to do  $self->SUPER::PCI_register( @_[1 .. $#_] );

package ePotsV2::Toaster;

use parent ePotsV2::Interactive;

use POE::Component::IRC::Plugin qw( :ALL );
use IRC::Utils qw( parse_user );
use Encode;
use utf8;

# Tells celebration reasons for today (/usr/bin/calendar -t)
# set up local ~/.calendar/calendar file to select which dates to use

# Plugin object constructor
 sub new {
     my $package = shift;
     my $confdir = shift;

     return bless {
         commands => {
             "НУ ЧТО" => \&interact,
             "ЗА ЧТО.*ПИТЬ" => \&interact,
         }                             ,  # $mask => \&coderef
     }, $package;
 }

 sub PCI_register {
     my ($self, $irc) = @_[0 .. 1];
     $self->SUPER::PCI_register( @_[1 .. $#_] );

     $irc->plugin_register( $self, 'SERVER', qw( bot_mentioned ) );

     return 1;
 }


 sub interact {
   my ( $self, $who, $where, $line, $i_called, $request_text, $trigger, $triggered, $before_trigger, $after_trigger ) = @_;

   my $nick = parse_user( $who );

   open IN, '/usr/bin/calendar -l 7 |';
   binmode IN, ":utf8";

   my $greeted = 0;
   while(<IN>) {
     unless( $greeted ) {
       $self->say( $where, $nick . ", а выпить можно вот за что:" );
       $greeted = 1;
     }
     chomp;
     next if /^\s/;
     my ( $mon, $day, @text ) = split;
     $self->say( $where, "$day $mon: " . join( ' ', @text ) );
   }
   CORE::close IN;
   unless( $greeted ) {
     $self->say( $where, $nick . ", а выпить сегодня и не за что... :-(" );
   }
   return PCI_EAT_ALL;
 }


1;
