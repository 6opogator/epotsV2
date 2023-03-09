#!/usr/bin/perl

# base class for interactive bot plugin
# subscribe to public_translated for UTF8 encoded messages
# subscribe to action_translated for UTF8 CTCP ACTION message
# subscribe to bot_mentioned for UTF8 public messages where bot is addressed
# fill $self->{triggers}->{$pattern}->{$coderef} to authomatically get callback when pattern is mentioned
# fill $self->{commands}->{$pattern}->{$coderef} to authomatically get callback when bot AND pattern is mentioned
# use $self->say($channel, @lines) to encoding-safe speak on channel (multilines OK, lines should be UTF8)
# use $self->action($channel, $action) to encoding-safe CTCP ACTION on channel (should be UTF8)
# don't forget to SUPER::PCI_register

package ePotsV2::TestInteract;

use ePotsV2::Interactive;

@ISA = qw(ePotsV2::Interactive);

use POE::Component::IRC::Plugin qw( :ALL );
use Encode;
use utf8;

# Plugin object constructor
 sub new {
     my $package = shift;
     return bless {
         commands => { 
             "скажи" => sub { do_something( @_ ) }
         }
     }, $package;
 }

 sub PCI_register {
#     $self->SUPER::PCI_register( @_ );

     my ($self, $irc) = splice @_, 0, 2;

     $irc->plugin_register( $self, 'SERVER', qw( bot_mentioned ) );
#     $irc->plugin_register( $self, 'USER', qw(ask_for_op) );
#     $irc->plugin_register( $self, 'USER', qw(public_decoded) );
     $self->{irc} = $irc;

     return 1;
 }

 # This is method is mandatory but we don't actually have anything to do.
# actually it is inherited
# sub PCI_unregister {
#     return 1;
# }

 sub do_something {
   my $self = shift;
   my $param1 = shift;
   my $trigger = shift;
   my $rest = join(", ", @_ );

   $self->action( "#ePotsV2", "has called do_something with params: [$param1] [$trigger] [$rest]" );
   $self->say( "#ePotsV2", "has called do_something with params: [$param1] [$trigger] [$rest]" );
   print( "#ePotsV2", "has called do_something with params: [$param1] [$trigger] [$rest]\n" );
   return PCI_EAT_ALL;
 }

1;
