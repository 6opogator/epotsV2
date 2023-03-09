#!/usr/bin/perl

use MLDBM qw( DB_File Storable );
use DB_File;
use DBM_Filter;
use Data::Dumper;

my $filename = $ARGV[0];

rename $filename, "$filename.1251" or die $!;

my %cdbin;
my $tiedin = tie %cdbin, 'MLDBM', "$filename.1251", O_CREAT|O_RDWR, 0644;
#$tiedin -> {DB} -> Filter_Push( 'encode', 'CP1251' );

my %cdbout;
my $tiedout = tie %cdbout, 'MLDBM', "$filename", O_CREAT|O_RDWR, 0644;
#$tiedout -> {DB} -> Filter_Push( 'encode', 'utf-8' );

foreach $rec ( keys %cdbin ) {
  $cdbout{$rec} = $cdbin{$rec};
print Dumper(  [ $rec, $cdbin{$rec} ] );
}

untie %cdbin;
untie %cdbout;
