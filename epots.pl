#!/usr/bin/perl

use lib ".";

use POSIX 'setsid';
use ePotsV2;

$botname=$0;
$botname=~s/\.pl$//;
$botname=~s/^.*\/([^\/]+)$/$1/;
$|=1;

unless( $ARGV[0] eq "nofork" ) {
  open STDIN, '</dev/null' or die "Can't read /dev/null: $!";
  open STDOUT, ">>$botname.log"
                        or die "Can't open $botname.log to write: $!";
  defined(my $pid = fork) or die "Can't fork: $!";
  if( $pid ) {
    $SIG{CHLD}='IGNORE';
    exit;
  }

  setsid                  or die "Can't start a new session: $!";
  print STDERR "forked, messages continued in $botname.log\n";
  open STDERR, '>&STDOUT' or die "Can't dup stdout: $!";
}

my $bot = new ePotsV2();
$bot->run;
