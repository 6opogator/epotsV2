#!/usr/bin/perl

# base class for interactive bot plugin
# subscribe to irc_public_translated for UTF8 encoded messages
# subscribe to irc_action_translated for UTF8 CTCP ACTION message
# subscribe to irc_bot_mentioned for UTF8 public messages where bot is addressed
# fill $self->{triggers}->{$pattern}->{$coderef} to authomatically get callback when pattern is mentioned
# fill $self->{commands}->{$pattern}->{$coderef} to authomatically get callback when bot AND pattern is mentioned
# use $self->say($channel, @lines) to encoding-safe speak on channel (multilines OK, lines should be UTF8)
# use $self->action($channel, $action) to encoding-safe CTCP ACTION on channel (should be UTF8)

package ePotsV2::Interactive;


use POE::Component::IRC::Plugin qw( :ALL );
use Encode;
use utf8;
use Data::Dumper;

# Plugin object constructor
 sub new {
     my $package = shift;
     return bless {}, $package;
 }

 sub PCI_register {
     my ($self, $irc) = @_[0 .. 1];

#     $irc->plugin_register( $self, 'SERVER', qw( public chan_mode chan_sync ) );
#     $irc->plugin_register( $self, 'USER', qw(ask_for_op) );
#     $irc->plugin_register( $self, 'USER', qw(public_decoded) );
     $self->{irc} = $irc;

     return 1;
 }

 # This is method is mandatory but we don't actually have anything to do.
 sub PCI_unregister {
     my ($self, $irc) = @_[0 .. 1];
     # Plugin is dying make sure our POE session does as well.
     delete $self->{irc};
     return 1;
 }


 sub S_public_translated {
     my ($self, $irc) = splice @_, 0, 2;
     # Parameters are passed as scalar-refs including arrayrefs.
#print ref $self, " public_translated called\n";
     my ($who, $channel, $what)  = splice @_, 0, 3;
     return PCI_EAT_NONE unless defined $self->{triggers};
     foreach $trigger ( keys %{$self->{triggers}} ) {
        my $pattern = "^(.*)($trigger)(.*)\$";
        if( $$what =~ /$pattern/i ) {
#print "Triggered $pattern\n";
           return &{ $self->{triggers}->{$trigger} }( $self, $$who, $$channel->[0], $$what, $trigger, $2, $1, $3 );
        }
     }
     return PCI_EAT_NONE;
 }

 sub S_bot_mentioned {
     my ($self, $irc) = splice @_, 0, 2;
     # Parameters are passed as scalar-refs including arrayrefs.
#print ref $self, " bot_mentioned called\n";
     my ($who, $channel, $bot_nick, $line_rest, $what)  = splice @_, 0, 5;
     return PCI_EAT_NONE unless defined $self->{commands};
     foreach $trigger ( keys %{$self->{commands}} ) {
        my $pattern = "^(.*)($trigger)(.*)\$";
        if( $$line_rest =~ /$pattern/i ) {
#print "Triggered $pattern\n";
           return &{ $self->{commands}->{$trigger} }( $self, $$who, $$channel->[0], $$what, $$bot_nick, $$line_rest, $trigger, $2, $1, $3 );
        }
     }
     return PCI_EAT_NONE;
 }

 sub say {
     my $self = shift;
     my $irc  = $self->{irc};
print "No irc inside myself!\n" unless $irc;
     return unless $irc;

     my $target = shift;

     foreach $line ( @_ ) {
       $irc->send_event( irc_bot_say => $target => $line );
     }
 }

 sub action {
     my $self = shift;
     my $irc  = $self->{irc};
print "No irc inside myself!\n" unless $irc;
     return unless $irc;

     my $target = shift;

     foreach $line ( @_ ) {
       $irc->send_event( irc_bot_action => $target => $line );
     }
 }


1;
