#!/usr/bin/perl

use DB_File;
use DBM_Filter;


my $filename = $ARGV[0];

rename $filename, "$filename.1251" or die $!;

my @cdbin;
my $tiedin = tie @cdbin, 'DB_File', "$filename.1251", O_CREAT|O_RDWR, 0644, $DB_RECNO;
$tiedin -> Filter_Push( 'encode', 'CP1251' );

my @cdbout;
my $tiedout = tie @cdbout, 'DB_File', "$filename", O_CREAT|O_RDWR, 0644, $DB_RECNO;
$tiedout -> Filter_Push( 'encode', 'utf-8' );

foreach $rec ( @cdbin ) {
  push @cdbout, $rec;
}

untie @cdbin;
untie @cdbout;
