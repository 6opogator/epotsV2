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

package ePotsV2::Translit;

use ePotsV2::Interactive;

@ISA = qw(ePotsV2::Interactive);

use POE::Component::IRC::Plugin qw( :ALL );
use IRC::Utils qw( parse_user );
use Encode;
use utf8;

# Plugin object constructor
 sub new {
     my $package = shift;
     return bless {
         triggers => { 
             "translit" => sub { translit( @_ ) },
             "екфтыдше" => sub { translit( @_ ) },
         }
     }, $package;
 }

 sub PCI_register {
     my ($self, $irc) = @_[0 .. 1];
     $self->SUPER::PCI_register( @_[1 .. $#_] );

     $irc->plugin_register( $self, 'SERVER', qw( public_translated  ) );

     return 1;
 }

 # This is method is mandatory but we don't actually have anything to do.
# actually it is inherited
# sub PCI_unregister {
#     return 1;
# }

 sub translit {
   my ( $self, $who, $where, $line, $trigger, $triggered, $before_trigger, $after_trigger ) = @_;

   my $nick = parse_user( $who );

   my $trlat = ";~\`qwertyuiop[]QWERTYUIOP{}asdfghjkl\'ASDFGHJKL:\"zxcvbnm,.ZXCVBNM<>";
   my $trrus = "жЁёйцукенгшщзхъЙЦУКЕНГШЩЗХЪфывапролдэФЫВАПРОЛДЖЭячсмитьбюЯЧСМИТЬБЮ";
   my $fro = $trrus . $trlat;
   my $to = $trlat . $trrus;

   eval "\$after_trigger =~ tr/$fro/$to/, 1" or return PCI_EAT_ALL;

   $self->say( $where, "$nick:$after_trigger" );

   return PCI_EAT_ALL;
 }

1;
