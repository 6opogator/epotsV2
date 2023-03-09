#!/usr/bin/perl

package ePotsV2::Asker;

use POE::Component::IRC::Plugin qw( :ALL );
use Encode;
use utf8;
use Data::Dumper;

# Plugin object constructor
 sub new {
     my $package = shift;
     return bless { 
          asking => [ 
                 [ "Дайте опа, плиз!\n", 300 ],
                 [ "Ну дайте же мне опа, плизик!\n", 900 ],
                 [ "Я так понимаю, опа мне не дадут?\n", 3600 ],
                 [ "Буду краток. Хачю опа.\n", 18000 ],
                 [ "Вот уже который день жду опа :(\n", 43200 ]
          ], 
          curasking => {}
     }, $package;
 }

 sub PCI_register {
     my ($self, $irc) = splice @_, 0, 2;

     $irc->plugin_register( $self, 'SERVER', qw( chan_mode chan_sync ) );
     $irc->plugin_register( $self, 'USER', qw(ask_for_op) );
     $self->{irc} = $irc;
     return 1;
 }

 # This is method is mandatory but we don't actually have anything to do.
 sub PCI_unregister {
     return 1;
 }


 sub S_chan_mode {
     my ($self, $irc) = splice @_, 0, 2;

     my $nick    = ( split /!/, ${ $_[0] } )[0];
     my $channel = ${ $_[1] };
     my $mode    = ${ $_[2] };
     my $whom    = ${ $_[3] };

     if( $whom eq $irc->nick_name ) {
        if( $mode eq "+o" ) {
          # somebody gives me op!
          $self->say( $channel => "Спасибки, $nick!" ) unless $nick eq 'ChanServ';
        } elsif( $mode eq "-o" ) {
          # grr somebody takes op from me!
          $self->say( $channel => ":(" );
          $self->reset_asking($channel);
          $self->plan_to_ask( $channel, $self->{curasking}->{$channel}->[0]->[1] / 2 );
        }
     }
     return PCI_EAT_NONE;
 }

 sub S_chan_sync {
     my ($self, $irc) = splice @_, 0, 2;

     my $channel = ${ $_[0] };
     $self->reset_asking($channel);
     $self->plan_to_ask( $channel, $self->{curasking}->{$channel}->[0]->[1] / 2 );

     return PCI_EAT_NONE;
 }


 sub U_ask_for_op {
     my ($self, $irc) = splice @_, 0, 2;

     my $channel = ${ $_[0] };

#     $self->say( "#ePotsV2" => split( "\n", Dumper( $self->{curasking}->{$channel} ) ) );

     if( $irc->is_channel_operator( $channel, $irc->nick_name ) ) {
       # i'm already op, no need to ask
       $self->reset_asking($channel);
     } else {
       my $whattoask = shift( @{$self->{curasking}->{$channel}} );
       # repeat last asking next time again if it was really last one
       if( $#{$self->{curasking}->{$channel}} < 0 ) {
          unshift( @{$self->{curasking}->{$channel}}, $whattoask );
       }
       $self->say( $channel => $whattoask->[0] );
       $self->plan_to_ask( $channel, $whattoask->[1] );
     }
     return PCI_EAT_ALL;

 }

 sub reset_asking {
     my $self = shift;
     my $channel = shift;
     $self->{curasking}->{$channel} = [ @{$self->{asking}} ];
 }

 sub plan_to_ask {
     my $self = shift;
     my $irc  = $self->{irc};
print "No irc inside myself!\n" unless $irc;
     return unless $irc;

     my ( $channel, $delay ) = splice @_, 0, 2;
#     $self->say( "#ePotsV2" => "Will ask in $delay sec" );
     $irc->delay( [ ask_for_op => $channel ], $delay );
 }

 sub say {
     my $self = shift;
     my $irc  = $self->{irc};
print "No irc inside myself!\n" unless $irc;
     return unless $irc;

     my $target = shift;

     foreach $line ( @_ ) {
#print "---->$line\n";
       $irc->send_event( irc_bot_say => $target => $line );
     }
 }

1;
