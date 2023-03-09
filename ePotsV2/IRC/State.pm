
package ePotsV2::IRC::State;

use POE;
use POE::Component::IRC::Constants qw(:ALL);
use POE::Component::IRC::Plugin qw(:ALL);
use base POE::Component::IRC::State;

#sub spawn {
#  my $package = shift;
#  my $irc = POE::Component::IRC::State->spawn( @_ ) or return undef;
#  return bless $irc, $package;
#}

# Prioritized sl().  This keeps the queue ordered by priority, low to
# high in the UNIX tradition.  It also throttles transmission
# following the hybrid ircd's algorithm, so you can't accidentally
# flood yourself off.  Thanks to Raistlin for explaining how ircd
# throttles messages.
sub sl_prioritized {
    my ($kernel, $self, $priority, @args) = @_[KERNEL, OBJECT, ARG0, ARG1];

    if (my ($event) = $args[0] =~ /^(\w+)/ ) {
        # Let the plugin system process this
        return 1 if $self->send_user_event($event, \@args) == PCI_EAT_ALL;
    }
    else {
        warn "Unable to extract the event name from '$args[0]'\n";
    }

    my $msg = $args[0];
    my $now = time();
    $self->{send_time} = $now if $self->{send_time} < $now;

    # if we find a newline in the message, take that to be the end of it
    $msg =~ s/[\015\012].*//s;

    if (bytes::length($msg) > $self->{msg_length} - bytes::length($self->nick_name())) {
        $msg = bytes::substr($msg, 0, $self->{msg_length} - bytes::length($self->nick_name()));
    }

    if (@{ $self->{send_queue} }) {
        my $i = @{ $self->{send_queue} };
        $i-- while ($i && $priority < $self->{send_queue}->[$i-1]->[MSG_PRI]);
        splice( @{ $self->{send_queue} }, $i, 0, [ $priority, $msg ] );
    }
    elsif ( !$self->{flood} && $self->{send_time} - $now >= $self->{flood_delay}
        || !defined $self->{socket} ) {
        push( @{$self->{send_queue}}, [ $priority, $msg ] );
        $kernel->delay( sl_delayed => $self->{send_time} - $now - $self->{flood_delay} );
    }
    else {
        warn ">>> $msg\n" if $self->{debug};
        $self->send_event(irc_raw_out => $msg) if $self->{raw};
        $self->{send_time} += 1 + length($msg) / $self->{flood_cps};
        $self->{socket}->put($msg);
    }

    return;
}

# Send delayed lines to the ircd.  We manage a virtual "send time"
# that progresses into the future based on hybrid ircd's rules every
# time a message is sent.  Once we find it ten or more seconds into
# the future, we wait for the realtime clock to catch up.
sub sl_delayed {
    my ($kernel, $self) = @_[KERNEL, OBJECT];

    return if !defined $self->{socket};

    my $now = time();
    $self->{send_time} = $now if $self->{send_time} < $now;

    while (@{ $self->{send_queue} } && ($self->{send_time} - $now < $self->{flood_delay})) {
        my $arg = (shift @{$self->{send_queue}})->[MSG_TEXT];
        warn ">>> $arg\n" if $self->{debug};
        $self->send_event(irc_raw_out => $arg) if $self->{raw};
        $self->{send_time} += 1 + length($arg) / $self->{flood_cps};
        $self->{socket}->put($arg);
    }

    if (@{ $self->{send_queue} }) {
        $kernel->delay( sl_delayed => $self->{send_time} - $now - $self->{flood_delay} );
    }

    return;
}

1;
