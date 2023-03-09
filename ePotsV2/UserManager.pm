
package ePotsV2::UserManager;

use IRC::Utils qw( parse_user matches_mask );

sub new {
  my $package = shift;

  return bless {}, $package;
}

sub have_user {
  my $self = shift;
  my $who = shift;     # IRC usermask

#print "UserManager: have_user $who\n";
  return 1;
}

sub is_my_op {
  my $self = shift;
  my $who = shift;     # IRC usermask

#print "UserManager: is_my_op $who\n";
#print "UserManager: ".matches_mask( '*!boroda@gw.altitude-management.ru', $who )."\n";
  return 1 if matches_mask( '*!boroda@gw.altitude-management.ru', $who );
  return 0;
}


1;
