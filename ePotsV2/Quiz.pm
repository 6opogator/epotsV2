#!/usr/bin/perl

# TODO:
#   1. Принудительные подсказки (по просьбе)
#   2. Ставки
#

# subscribe to public_translated for UTF8 encoded messages
# subscribe to action_translated for UTF8 CTCP ACTION message
# subscribe to bot_mentioned for UTF8 public messages where bot is addressed
# fill $self->{triggers}->{$pattern}->{$coderef} to authomatically get callback when pattern is mentioned
# fill $self->{commands}->{$pattern}->{$coderef} to authomatically get callback when bot AND pattern is mentioned
# use $self->say($channel, @lines) to encoding-safe speak on channel (multilines OK, lines should be UTF8)
# use $self->action($channel, $action) to encoding-safe CTCP ACTION on channel (should be UTF8)
# don't forget to do  $self->SUPER::PCI_register( @_[1 .. $#_] );

package ePotsV2::Quiz;

use parent ePotsV2::Interactive;

use POE::Component::IRC::Plugin qw( :ALL );
use IRC::Utils qw( parse_user );
use Encode;
use utf8;

# Quiz bot.
# Config file: 
#  players       файл с базой игроков
#  questions     файл с вопросами викторины
#  alias   []    на что откликаться -- не работает, сломалось TODO!
#  times N N N   время (сек) до 1-й..2-й..3-й..подсказки... никто не угадал
#  scores N N N  очков за ответ сразу 1-й 2-й... подсказки
#  rest N        время (сек) паузы между вопросами и стопом/стартом автомата
#  auto MIN MAX  время (сек) между загадками автоматом
#  channel []    канал на котором играть
#
# Quiz Database:
#  DB_File DB_RECNO
#   ($question,$answer) = split( '|', $record );
# Players Database
#  MLDBM qw( DB_File Storable );
#   { nick => score }
#

use MLDBM qw( DB_File Storable );
use DB_File;
use DBM_Filter;
use Data::Dumper;

 sub new {
     my $package = shift;
     my $confdir = shift;

     $confdir = 'data/Quiz' unless defined $confdir;
     $confdir = 'data/Quiz' if $confdir eq '';

     return bless {
         datadir => $confdir,
         commands => {
             "СКОЛЬКО" => \&player_report,
             "ЧЕМПИОН" => \&champions_report,
             "З[АО]ГА[ДТ][АК]" => \&quiz_requested,
             "ПОЕХАЛИ" => \&autorun_requested,
             "СТОЯТЬ" => \&stop_autorun_requested,
         }                             ,  # $mask => \&coderef
         triggers => {
             ".*" => \&channel_chat,
         }                             ,  # $mask => \&coderef
         players => {}                 ,  # nick => score, tied hashref
         playersref => undef           ,  # tied object for sync() and close()
         playersfile => 
             "$confdir/players.db"     ,  # config
         times => []                   ,  # config
         scores => []                  ,  # config
         state => {}                   ,  # channel => state : -1=wait, >=0 number of hints used
         dbfile => "$confdir/quiz.db"  ,  # questions filename
         rest => 0                     ,  # delay between quiz requests
         auto => [-1, -1]              ,  # config
         count => 0                    ,  # No of lines in quiz db
         nextrun => {}                 ,  # channel => (time() when allowed to request new question)
         syntax => [ "", "", "" ]      ,  # score names (russian style: \d*[2-9]?1, \d*[2-9]?[2-4], .*)
         delay => undef                ,  # between quiz request and question
         dmessage => ""                ,  # warning message after quiz request
         autorun => {}                    # use autorun
     }, $package;
 }

 sub PCI_register {
     my ($self, $irc) = @_[0 .. 1];
     $self->SUPER::PCI_register( @_[1 .. $#_] );

     $self->read_config();

     $irc->plugin_register( $self, 'SERVER', qw( bot_mentioned public_translated ) );
     $irc->plugin_register( $self, 'USER',   qw( quiz_delayed_start quiz_auto_run quiz_tick ) );

     return 1;
 }

 sub PCI_unregister {
     my ($self, $irc) = @_[0 .. 1];
     $self->SUPER::PCI_unregister( @_[1 .. $#_] );

     # gracefully close players db
     if( defined( $self->{playersref} ) ) {
        $self->{playersref}->sync();
        $self->{playersref}->undef;
        untie %{$self->{players}};
     }

     return 1;
 }


 sub read_config {
     my $self=shift;
     my $datadir=$self->{datadir};
     my $conffile="$datadir/Quiz.conf";
     open( IN, "<:encoding(UTF-8)", $conffile) or print "Unable to open config file $conffile: $!\n";
     while(<IN>) {
       chomp;
       if( /^players\s+(.*)$/ ) {
         $self->{playersfile} = "$datadir/$1";
       } elsif( /^questions\s+(.*)$/ ) {
         $self->{dbfile} = "$datadir/$1";
       } elsif( /^rest\s+(.*)$/ ) {
         $self->{rest} = $1;
       } elsif( /^times\s+(.*)$/ ) {
         $self->{times} = [ split(/\s+/, $1) ];
       } elsif( /^scores\s+(.*)$/ ) {
         $self->{scores} = [ split(/\s+/, $1) ];
       } elsif( /^channel\s+(.*)$/ ) {
         my $chan = $1;
         $chan = lc($chan);
         $self->{state}->{$chan} = -1;
         $self->{nextrun}->{$chan} = 0;
       } elsif( /^auto\s+(\S+)\s+(\S+)$/ ) {
         $self->{auto} = [ $1, $2 ];
       } elsif( /^scorenames\s+(.*)$/ ) {
         $self->{syntax} = [ split(/\s+/, $1) ];
       } elsif( /^delay\s+(\S+)$/ ) {
         $self->{delay} = $1;
       } elsif( /^delaymessage\s+(.*)$/ ) {
         $self->{dmessage} = $1;
       }
     }
     CORE::close IN;
     
     my @base;
     my $ref = tie @base, 'DB_File', $self->{dbfile}, O_RDONLY, 0644, $DB_RECNO;
     # we are unicode-ready!
     $ref->Filter_Push( 'encode', 'utf-8' );
     $self->{count} = scalar(@base);
     untie @base;

     $self->{playersref} = tie %{$self->{players}}, 'MLDBM', $self->{playersfile},  O_CREAT|O_RDWR, 0644;
     
     return undef;
 }    

 # Nobody knows
 sub noWinners {
     my $self = shift;
     my $chan = shift;

     $self->say( $chan, "Не угадал никто. Правильный ответ: ".
        join(' ',split('',$self->{current}->{$chan}->{answer})) );

     $self->endOfQuestion($chan);
 }

 # we have winner( where, no-of-hints-used, who )
 sub winner {
    my $self = shift;
    my $chan = shift;
    my $hints = shift;
    my $player = shift;
    
    $self->endOfQuestion($chan);
    return if $hints == -1;

    my $msg;
    if( $hints == 0 ) {
      $msg = "без подсказок";
    } elsif( $hints == 1 ) {
      $msg = "c одной подсказкой";
    } else {
      $msg = "c ".$hints." подсказками";
    }
    $self->say( $chan, $player.", правильно! За ответ $msg ты получаешь ".$self->syntax($self->{scores}->[$hints])."." );
    $self->{players}->{$player} = 0 unless defined $self->{players}->{$player};
    $self->{players}->{$player} += $self->{scores}->[$hints];
    $self->{playersref}->sync();
 }

 # finish this round
 sub endOfQuestion {
    my $self = shift;
    my $chan = shift;

    $self->{state}->{$chan} = -1;
    $self->{nextrun}->{$chan} = time() + $self->{rest} - 1;
 }

 ##### timed event handlers ######
 #
 # called from scheduler
 sub U_quiz_auto_run {
    my ($self, $irc) = splice @_, 0, 2;

    my $chan = ${ $_[0] };
  
    my $state = $self->{state}->{$chan};
    return undef unless defined( $self->{state}->{$chan} ) && $self->{state}->{$chan} == -1;
    return undef unless defined( $self->{autorun}->{$chan} );
  
    $self->startQuiz($chan,1);
    my $timer = $self->{auto}->[0] + int( rand($self->{auto}->[1] - $self->{auto}->[0]) );
    $irc->delay( [ quiz_auto_run => $chan ], $timer );
    return PCI_EAT_ALL;
 }

 # scheduled worker for start quiz (if delay is defined)
 sub U_quiz_delayed_start {
    my ($self, $irc) = splice @_, 0, 2;

    my $chan = ${ $_[0] };

    my $state = $self->{state}->{$chan};
    return undef unless $state == -1;

    if( $irc->{bot}->{sleepmode} ) {
      $self->action( $chan, "всхрапнул и перевернулся на другой бок" );
    } else {
      $self->startQuiz($chan,1);
    }
    return PCI_EAT_ALL;
  }

 # scheduled worker for one round (next hint or nobody wins)
 sub U_quiz_tick {
    my ($self, $irc) = splice @_, 0, 2;

    my $chan = ${ $_[0] };

    my $state = $self->{state}->{$chan};
    return PCI_EAT_ALL if $state == -1;

    if( $irc->{bot}->{sleepmode} ) {
      $self->action($chan,"во сне пробормотал, что правильный ответ: ".
              join(' ',split('',$self->{current}->{$chan}->{answer})) );
      $self->endOfQuestion($chan);
      return PCI_EAT_ALL;
    }

    if( ++$state >= @{$self->{times}} ) {
      # no more tries
      $self->noWinners($chan);
    } else {
      # giving hint
      if( $state == 1 ) {
        # 1st hint
        $self->{current}->{$chan}->{hint} = 
           "_" x length( $self->{current}->{$chan}->{answer} );
      } else {
        # calculate number of chars shown on this hint
        my $nchars = int( length( $self->{current}->{$chan}->{answer} ) * ( $state - 1 ) / 5 );
        $nchars = $state - 1 if $nchars < $state - 1;
        my $oldchars = int( length( $self->{current}->{$chan}->{answer} ) * ( $state - 2 ) / 5 );
        $oldchars = $state - 2 if $oldchars < $state - 2;

        # we should add ( $nchars - $oldchars ) chars to hint.
        # extreme case - all chars should be in hint
        if( $nchars >= length( $self->{current}->{$chan}->{answer} ) ) {
          $self->noWinners($chan);
          return PCI_EAT_ALL;
        }

        my @hint = split( '', $self->{current}->{$chan}->{hint} );
        for( my $i = 0; $i < ($nchars - $oldchars); $i++ ) {
          my $k;
          do {
            $k = int(rand( scalar @hint ) );
          } while( $hint[$k] ne "_" );
          $hint[$k] = substr( $self->{current}->{$chan}->{answer}, $k, 1 );
        }
        $self->{current}->{$chan}->{hint} = join( '', @hint );
      }

      $self->say( $chan, "Подсказка ".$state.": ". join(' ', split('',$self->{current}->{$chan}->{hint}) ) );
      $self->{state}->{$chan} = $state;
      $irc->delay( [ quiz_tick => $chan ], $self->{times}->[$state] );
      return PCI_EAT_ALL;
    }
    return PCI_EAT_NONE;  # never happens
 }

 #
 ##### timed event handlers end ######

 # try to start round if time limit permits
 sub startQuiz {
    my $self = shift;
    my $chan = shift;
    my $force = shift;

    if( time() < $self->{nextrun}->{$chan} && ! $force ) {
      $self->say( $chan, "Никаких загадок, иди работай!" );
      return;
    }

    $self->{nextrun}->{$chan} = time() + $self->{rest} - 1;

    if( ! $force && $self->{delay} ) {
      $self->{irc}->delay( [ quiz_delayed_start => $chan ], $self->{delay} );
      $self->say( $chan, $self->{dmessage} );
      return;
    }

    my $ind = int( rand $self->{count} );

    my @base;
    my $ref = tie @base, 'DB_File', $self->{dbfile}, O_RDONLY, 0644, $DB_RECNO;
    # we are unicode-ready!
    $ref->Filter_Push( 'encode', 'utf-8' );
    my ($q,$a) = split( '\|', $base[$ind] );
    untie @base;

    $a = uc( $a );  # unicode!

    $self->{current}->{$chan} = {
              question => $q,
              answer   => $a,
              hint     => undef 
              };

    # schedule 1st hint
    $self->{irc}->delay( [ quiz_tick => $chan ], $self->{times}->[0] );

    $self->say( $chan, "ЗАГАДКА: ".$q );
    $self->{state}->{$chan} = 0;
 }

 ##### channel interaction handlers ######
 #
 # players status report 
 sub player_report {
   my ( $self, $who, $where, $line, $i_called, $request_text, $trigger, $triggered, $before_trigger, $after_trigger ) = @_;

   my $chan = lc($where);
   my $nick = parse_user( $who );

   if( defined( $self->{players}->{$nick} ) ) {
     $self->say( $chan, $nick.", у тебя ".$self->syntax($self->{players}->{$nick}) );
   } else {
     $self->say( $chan, "Да нисколько, ".$nick.", тебя еще нет в базе." );
   }
   return PCI_EAT_ALL;
 }

 # champions report , shows only top 3
 sub champions_report {
   my ( $self, $who, $where, $line, $i_called, $request_text, $trigger, $triggered, $before_trigger, $after_trigger ) = @_;

   my $chan = lc($where);
   my $count = 0;
   my @roman = ( "I", "II", "III" );
   foreach $key ( sort({$self->{players}->{$b}<=>$self->{players}->{$a}} keys(%{$self->{players}})) ) {
     last if ++$count > 3;
     $self->say( $chan, $roman[$count-1]." место: ".$key.", ".$self->syntax($self->{players}->{$key}) );
   }
   return PCI_EAT_ALL;
 }

 sub quiz_requested {
   my ( $self, $who, $where, $line, $i_called, $request_text, $trigger, $triggered, $before_trigger, $after_trigger ) = @_;

   my $chan = lc($where);
   return PCI_EAT_ALL unless $self->{state}->{$chan} == -1;

   $self->startQuiz( $chan, 0 );
   return PCI_EAT_ALL;
 }

 sub autorun_requested {
   my ( $self, $who, $where, $line, $i_called, $request_text, $trigger, $triggered, $before_trigger, $after_trigger ) = @_;

   my $chan = lc($where);
   return PCI_EAT_ALL unless $self->{state}->{$chan} == -1;  # no start autorun in the middle of question
   return PCI_EAT_ALL if defined $self->{autorun}->{$chan};  # already autorunning
   my $nick = parse_user( $who );

   if( time() < $self->{nextrun}->{$chan} ) {  # no autorun when cooling off after last quiz
      $self->say( $chan, $nick.", да ты охренел!" );
      return PCI_EAT_ALL;
   }

   $self->say( $chan, "Начинаю автоматический режим. Интервал от ".
                        $self->{auto}->[0] . " до ". $self->{auto}->[1] );
   $self->{autorun}->{$chan} = 1;
   $self->{irc}->delay( [ quiz_auto_run => $chan ], 1 );
   return PCI_EAT_ALL;
 }

 sub stop_autorun_requested {
   my ( $self, $who, $where, $line, $i_called, $request_text, $trigger, $triggered, $before_trigger, $after_trigger ) = @_;

   my $chan = lc($where);
   return PCI_EAT_ALL unless defined $self->{autorun}->{$chan};

   $self->say( $chan, "Автоматический режим отменен." );
   $self->{autorun}->{$chan} = undef;
   $self->{nextrun}->{$chan} = time() + $self->{rest} - 1;
   return PCI_EAT_ALL;
 }

 # this one monitors ALL public messages return ASAP
 sub channel_chat {
   my ( $self, $who, $where, $line, $trigger, $triggered, $before_trigger, $after_trigger ) = @_;

   my $chan = lc($where);
   return PCI_EAT_NONE if $self->{state}->{$chan} == -1;  # return ASAP if no quiz on the go

   if( uc($line) eq $self->{current}->{$chan}->{answer} ) {
     my $nick = parse_user( $who );
     $self->winner( $chan, $self->{state}->{$chan}, $nick );
     return PCI_EAT_ALL;
   }

   return PCI_EAT_NONE;
 }

 #
 ##### channel interaction handlers end ######


 ##### utility ######
 # return correct form of numerical (with numerical itself)
 sub syntax {
   my $self = shift;
   my $num  = shift;

   my $restnum = $num % 100;

   return $num . " " . $self->{syntax}->[
      ( $restnum > 20 || $restnum < 10 ) ? (
        $restnum % 10 == 1 ? 0 : (
          ($restnum % 10) =~ /2|3|4/ ? 1 : 2
        )
      ) : 2 
   ];
 }

1;
