#!/usr/bin/perl

package ePotsV2::Weather;

use parent ePotsV2::Interactive;

use POE qw( Kernel Session Component::Client::HTTP );
use POE::Component::IRC::Plugin qw( :ALL );
use IRC::Utils qw( parse_user );
use Encode;
use utf8;
use Text::Unidecode;
use Text::Trim qw(trim);
use URI::Encode qw( uri_encode );

use Date::Parse;

use HTTP::Request;
use HTTP::Response;

use DB_File;
use Storable qw( freeze thaw );
use MLDBM qw( DB_File Storable );
use Fcntl;

use XML::Simple qw( XMLin );

# "http://api.openweathermap.org/data/2.5/weather?id=480562&mode=xml&units=metric&lang=ru&appid=...
# "http://api.openweathermap.org/data/2.5/forecast?id=480562&mode=xml&units=metric&lang=ru&appid=...


use Data::Dumper;

#######################
##
##  Plugin maintenance methods 
##

# Plugin object constructor
 sub new {
     my $package = shift;
     my $confdir = shift;

     $confdir = 'data/Weather' unless defined $confdir;
     $confdir = 'data/Weather' if $confdir eq '';
print "Weather: new\n";

     return bless {
         datadir => $confdir,
         pending => {},   # HTTP::Request => [ $channel, $nick, $city ]
         commands => {
                "ЗАПОМНИ(?:\\s+|,)(?:ЧТО)?"        => \&requested_alias,
                "ЗАБУДЬ\\s*(?:ПРО|ОБ|О)?\\s+"      => \&requested_forget,
                "ПЕРЕГРУЗИ"                        => \&requested_flush,
                "ПРОГНОЗ\\s*(?:(?:В|ДЛЯ|ЗА|НА|У)\\s+)?(?:\\s*(?:ГОРОДЕ|ГОРОДА|ГОРОДОМ)\\s+)?" => \&requested_forecast,
                "ПОГОД[АЕЫУ]\\s*(?:(?:В|ДЛЯ|ЗА|НА|У)\\s+)?(?:\\s*(?:ГОРОДЕ|ГОРОДА|ГОРОДОМ)\\s+)?" => \&requested_weather,
                     }, # $mask => \&coderef
#    formatting
         conditions => {
                200 => "гроза, слабый дождь",
                201 => "гроза, дождь",
                202 => "гроза, сильный дождь",
                210 => "легкая гроза",
                211 => "гроза",
                212 => "сильная гроза",
                221 => "гроза с перерывами",
                230 => "гроза, легкая изморось",
                231 => "гроза, изморось",
                232 => "гроза, сильная изморось",
                300 => "легкая изморось",
                301 => "изморось",
                302 => "сильная изморось",
                310 => "легкий моросящий дождь",
                311 => "моросящий дождь",
                312 => "сильный моросящий дождь",
                313 => "ливень и изморось",
                314 => "сильный ливень и изморось",
                321 => "ливень",
                500 => "слабый дождь",
                501 => "умеренный дождь",
                502 => "сильный дождь",
                503 => "очень сильный дождь",
                504 => "экстремальный дождь",
                511 => "ледяной дождь",
                520 => "слабый ливень",
                521 => "ливень",
                522 => "сильный ливень",
                531 => "прерывистый ливень",
                600 => "слабый снег",
                601 => "снег",
                602 => "сильный снег",
                611 => "мокрый снег",
                612 => "дождь со снегом",
                615 => "слабый дождь со снегом",
                616 => "дождь со снегом",
                620 => "слабая метель",
                621 => "метель",
                622 => "сильная метель",
                701 => "туман",
                711 => "дым",
                721 => "дымка",
                731 => "песчаная буря",
                741 => "сильный туман",
                751 => "песок",
                761 => "пыль",
                762 => "вулканический пепел",
                771 => "шквалистый ветер",
                781 => "торнадо",
                800 => "ясно",
                801 => "легкая облачность",
                802 => "облачно с прояснениями",
                803 => "облачно",
                804 => "сплошная облачность",
                900 => "торнадо",
                901 => "торпический шторм",
                902 => "ураган",
                903 => "мороз",
                904 => "жара",
                905 => "ветрено",
                906 => "град",
                951 => "штиль",
                952 => "легкий ветер",
                953 => "слабый ветер",
                954 => "умеренный ветер",
                955 => "свежий ветер",
                956 => "сильный ветер",
                957 => "сильный ветер, почти шторм",
                958 => "шторм",
                959 => "сильный шторм",
                960 => "сильный шторм",
                961 => "экстремальный шторм",
                962 => "ураган",
         },
	 precipitations => {
                'rain' => 'дождь',
                'snow' => 'снег',
         },
     }, $package;
 }

# Registering method
 sub PCI_register {
     my ($self, $irc) = @_[0 .. 1];
     $self->SUPER::PCI_register( @_[1 .. $#_] );

#print "Weather: reading config\n";
     $self->read_config();
#print "Weather: init DB\n";
     $self->init_cache_db();
#print "Weather: register plugin\n";
     $irc->plugin_register( $self, 'SERVER', qw( bot_mentioned ) );

     # session to talk with http requestor
     POE::Session->create(
        object_states => [ $self => [ qw( _start  _shutdown request_weather got_weather_reply ) ] ],
        heap => { irc => $irc, bot => $self },
     ) or print "Unable to create POE::Session object! $!";
     return 1;
 }

# Unregistering method
 sub PCI_unregister {
     my ($self, $irc) = @_[0 .. 1];

     # cleanup session. use call, not post because this object will be destroyed right after this sub returns
     $poe_kernel->call( $self->{session_id} => '_shutdown' );

     # close bases gracefully
     $self->{cacheref}->sync();
     delete $self->{cacheref};
     untie %{$self->{cache}};
     $self->SUPER::PCI_unregister( @_[1 .. $#_] );

     return 1;
 }

#######################
##
##  Session with HTTP Client 
##
 sub _start {
    my ($kernel, $self) = @_[KERNEL, OBJECT];

    $self->{session_id} = $_[SESSION]->ID();

    # prevent session to die if empty queue
    $kernel->refcount_increment( $self->{session_id}, __PACKAGE__ );

    # asynchronous requestor component
    $self->{http_client} =   POE::Component::Client::HTTP->spawn(
          # Agent     => 'SpiffCrawler/0.90',   # defaults to something long
          Alias     => 'weather_requestor',   # defaults to 'weeble'
          # From      => 'spiffster@perl.org',  # defaults to undef (no header)
          # Protocol  => 'HTTP/0.9',            # defaults to 'HTTP/1.1'
          # Timeout   => 60,                    # defaults to 180 seconds
          # MaxSize   => 16384,                 # defaults to entire response
          # Streaming => 4096,                  # defaults to 0 (off)
          FollowRedirects => 2,               # defaults to 0 (off)
          # Proxy     => "http://localhost:80", # defaults to HTTP_PROXY env. variable
          # NoProxy   => [ "localhost", "127.0.0.1" ], # defs to NO_PROXY env. variable
          # BindAddr  => "12.34.56.78",         # defaults to INADDR_ANY
        );

 }

 sub _shutdown {
    my ($kernel, $self, $term) = @_[KERNEL, OBJECT, ARG0];

    # gracefully destroy requestor object. 
    $kernel->post( 'weather_requestor', 'shutdown' );
    delete $self->{http_client};

    # let the kernel kill my session
    $kernel->refcount_decrement( $self->{session_id}, __PACKAGE__ );
    return;
 }


 # we are asked in irc, dispatch from here because callback should be here
 sub request_weather {
  my ($self, $kernel, $heap, $sender, $who, $where, $request) = @_[OBJECT, KERNEL, HEAP, SENDER, ARG0, ARG1, ARG2];

  $kernel->post( 'weather_requestor', 'request', 'got_weather_reply', $request );
 }

 # callback from requestor component, dispatch answer
 sub got_weather_reply {
  my ($self, $kernel, $heap, $sender, $request_packet, $response_packet) = @_[OBJECT, KERNEL, HEAP, SENDER, ARG0, ARG1];

  # callback convention is such
  my $request = $request_packet->[0];
  my $response = $response_packet->[0];

  # we should have request in our queue
print "Unmatched request ".$request->uri unless defined $self->{pending}->{$request};
  return unless defined $self->{pending}->{$request};

  if( $request->header('xx-requested') eq 'weather' ) {
    $self->process_weather_response( @{$self->{pending}->{$request}}, $response );
  } elsif( $request->header('xx-requested') eq 'forecast' ) {
    $self->process_forecast_response( @{$self->{pending}->{$request}}, $response );
  } else {
    print "Unknown request type [".$request->header('xx-requested')."]\n";
  }

  # remove processed request from queue
  delete $self->{pending}->{$request};
 }


##
##  END Session with HTTP Client 
##
#######################

#######################
##
##  irc interaction handlers 
##

# not need private handler
# sub S_msg_translated {
#    my ($self, $irc) = splice @_, 0 , 2;
#    my $who     = ${ $_[0] };
#    my $nick    = parse_user($who);
#    my $channel = ${ $_[1] }->[0];
#    my $command = ${ $_[2] };
#    my (@cmd)   = split(/ +/,$command);
#    my $cmd     = uc (shift @cmd);
#
#    return PCI_EAT_NONE unless $nick eq "boroda";
#    if( $cmd eq "TRYWEATHER" ) {
#       $self->process_request( $nick, $nick, $cmd[0] );
#       return PCI_EAT_ALL;
#    } elsif( $cmd eq "ALIAS" ) {
#       $self->process_alias( $nick, $nick, $cmd[0], $cmd[1] );
#       return PCI_EAT_ALL;
#    }
#
#    return PCI_EAT_NONE;
# }

 # запомни 
 sub requested_alias {
   my ( $self, $who, $where, $line, $i_called, $request_text, $trigger, $triggered, $before_trigger, $after_trigger ) = @_;
   my $nick    = parse_user($who);
   my ( $alias, $replacement );

   if( $after_trigger =~ /^\s*(.*?)\s*--\s*(.*?)\s*$/ ) {
     $alias = $1;
     $replacement = $2;
   } else {
     my (@cmd)   = split(/ +/,$after_trigger);
     shift @cmd while !$cmd[0];
     $alias = $cmd[0];
     $replacement = $cmd[1];
   }
print "Weather: запомни [$alias] -> [$replacement]\n";
   $self->process_alias( $where, $nick, $alias, $replacement ) if $alias && $replacement;
   return PCI_EAT_ALL;
 }

 # забудь
 sub requested_forget {
   my ( $self, $who, $where, $line, $i_called, $request_text, $trigger, $triggered, $before_trigger, $after_trigger ) = @_;
   my $nick    = parse_user($who);
   my (@cmd)   = split(/ +/,$after_trigger);

   shift @cmd while !$cmd[0];

print "Weather: забудь [$after_trigger]\n";
   $self->process_forget( $where, $nick, join( " ", @cmd ) );
   return PCI_EAT_ALL;
 }

 # перегрузи 
 sub requested_flush {
   my ( $self, $who, $where, $line, $i_called, $request_text, $trigger, $triggered, $before_trigger, $after_trigger ) = @_;
   my $nick    = parse_user($who);
   my $what    = trim($after_trigger);

   unless( $what ) {
      $self->say( $where, "$nick, перегрузить ЧТО?" );
      return PCI_EAT_ALL;
   }

print "Weather: перегрузи [$what]\n";
   $self->process_flush( $where, $nick, $what );
   return PCI_EAT_ALL;
 }

 # погода в ...
 sub requested_weather {
   my ( $self, $who, $where, $line, $i_called, $request_text, $trigger, $triggered, $before_trigger, $after_trigger ) = @_;
   my $nick    = parse_user($who);
#   my (@cmd)   = split(/ +/,$after_trigger);

#print "trigger $trigger\n triggered $triggered\n after $after_trigger\n";
#print Dumper( [ @cmd ] );
#   shift @cmd while !$cmd[0] && @cmd;
#print Dumper( [ @cmd ] );

print "Weather: погода в [$after_trigger]\n";
   $self->process_request( $where, $nick, $after_trigger );
   return PCI_EAT_ALL;
 }

 # прогноз в ...
 sub requested_forecast {
   my ( $self, $who, $where, $line, $i_called, $request_text, $trigger, $triggered, $before_trigger, $after_trigger ) = @_;
   my $nick    = parse_user($who);
#   my (@cmd)   = split(/ +/,$after_trigger);

#print "forecast: trigger $trigger\n triggered $triggered\n after $after_trigger\n";
#print Dumper( [ @cmd ] );
#   shift @cmd while !$cmd[0] && @cmd;
#print Dumper( [ @cmd ] );

print "Weather: прогноз в [$after_trigger]\n";
   $self->process_request_forecast( $where, $nick, $after_trigger );
   return PCI_EAT_ALL;
 }

##
##  end irc interaction handlers 
##
#######################

#######################
##
##  real logic here 
##
##  init
##
 sub read_config {
   my $self=shift;
   my $datadir=$self->{datadir};
   my $conffile="$datadir/Weather.conf";

   open( IN, "<:encoding(UTF-8)", $conffile) or print "Unable to open config file $conffile: $!\n";
   while(<IN>) {
     chomp;
     if( /^apikey\s+(.*)$/ ) {
       $self->{apikey} = $1;
     } elsif( /^baseurl\s+(.*)$/ ) {
       $self->{baseurl} = $1;
     }
   }
   CORE::close IN;
 }

 sub init_cache_db {
   my $self=shift;
   my $datadir=$self->{datadir};

   my %weather;

#print ref \%weather;
#print Dumper( \%weather );
   $self->{cacheref} = tie(%weather, 'MLDBM', "$datadir/weather.db", O_RDWR | O_CREAT, 0644) or die "Unable to tie $datadir/weather.db: .$!";
#   my $ref = eval { tie(%weather, 'DB_File', "$datadir/weather.db", O_RDWR | O_CREAT, 0644, $DB_HASH); };
#print "$@\n";
#print Dumper( $self->{cacheref} );
#my %empty = {};
#$weather{prognosis} = freeze \%empty;
#$weather{forecast} = freeze \%empty;
#$ref->sync();
#untie %weather;
#eval { print Dumper( thaw $weather{transforms} ) };
#print "$@\n";
#die;
#print "Dumping\n";
#eval { print ref $weather{prognosis} };
#print "$@\n";
#   die unless $self->{cacheref};
#print "tie still OK\n";
   $self->{cacheref}->{DB}->Filter_Push( 'encode', 'utf-8' );
#print "filter push OK\n";
   $self->{cache} = \%weather;
#print "save ref OK\n";
#print Dumper( %weather );
   $self->{cache}->{towns} = {}      unless defined $self->{cache}->{towns};
   $self->{cache}->{forecast} = {}   unless defined $self->{cache}->{forecast};
   $self->{cache}->{prognosis} = {}  unless defined $self->{cache}->{prognosis};
   $self->{cache}->{transforms} = {} unless defined $self->{cache}->{transforms};
   $self->{cacheref}->sync();
#print "cache init OK\n";
 }

##  request processing

 sub build_http_request {
   my ( $self, $what, $mode, $arg ) = @_;

   my $url = sprintf( "%s/%s?mode=xml&type=like&units=metric&appid=%s&%s=%s",
                    $self->{baseurl}, $what, $self->{apikey}, lc($mode), uri_encode( $arg, { encode_reserved => 1 } ) );
print "$url\n";
   return new HTTP::Request( GET => $url, [ 'xx-requested' => $what ] );
 }

 sub process_request {
   my ( $self, $where, $who, $city ) = @_;

   my $request = undef;

   # 1. if it is transform, use it
   $city=$self->{cache}->{transforms}->{$city} if defined $self->{cache}->{transforms}->{$city};

print "Will look for $city\n";

   # 2. if there is cached answer
   if( defined( $self->{cache}->{prognosis}->{$city} ) &&                              # record in cache
       ( ( time() - $self->{cache}->{prognosis}->{$city}->{timestamp} < 7200 )   &&    # 2-hours and
         $self->{cache}->{prognosis}->{$city}->{result} ) )                            # not unknown error
   {
       # send cached reply so be it
print "Sending cached: ",  time() - $self->{cache}->{prognosis}->{$city}->{timestamp}, " seconds ago\n";
print "Result: ", $self->{cache}->{prognosis}->{$city}->{result}, "\n";

       $self->deliver_answer( $where, $who, $city, $self->{cache}->{prognosis}->{$city}, 1, 0 );
       return;
   }

   # 3. find town ID if any
   my $town_id = undef;
   $town_id = $self->{cache}->{towns}->{$city} if defined $self->{cache}->{towns}->{$city};

   unless( defined $town_id ) {   # no id == not in cache

print "No town_id found\n";

      $request = $self->build_http_request( 'weather', 'q', $city );
   } else {

print "Found town_id: $town_id\n";

      # let's check first cache by id
      if( defined( $self->{cache}->{prognosis}->{$town_id} ) &&                        # record in cache
       ( ( time() - $self->{cache}->{prognosis}->{$town_id}->{timestamp} < 7200 ) &&   # 2-hours and
         $self->{cache}->{prognosis}->{$town_id}->{result} ) )                         # not unknown error
       {
          # send cached reply so be it
print "Sending cached by town id: ",  time() - $self->{cache}->{prognosis}->{$town_id}->{timestamp}, " seconds ago\n";
          $self->deliver_answer( $where, $who, $city, $self->{cache}->{prognosis}->{$town_id}, 1, 0 );
          return;
       } else {
          $request = $self->build_http_request( 'weather', 'id', $town_id );
       }
   }

   if( defined $request ) {
print "Built request, dispatching\n";

      $self->{pending}->{$request} = [ $where, $who, $city ];
      $poe_kernel->post( $self->{session_id}, 'request_weather', $where, $who, $request );
      $self->action( $where, "полез смотреть погоду в $city для $who" );
   }
 }

 sub process_request_forecast {
   my ( $self, $where, $who, $city ) = @_;

   my $request = undef;

   # 1. if it is transform, use it
   $city=$self->{cache}->{transforms}->{$city} if defined $self->{cache}->{transforms}->{$city};

   # 2. if there is cached answer
   if( defined( $self->{cache}->{forecast}->{$city} ) &&                              # record in cache
       ( ( time() - $self->{cache}->{forecast}->{$city}->{timestamp} < 7200 )   &&    # 2-hours and
         $self->{cache}->{forecast}->{$city}->{result} ) )                            # not unknown error
   {
#print "forecast: found\n";
#print Dumper( $self->{cache}->{forecast}->{$city} );
       # send cached reply so be it
       $self->deliver_answer( $where, $who, $city, $self->{cache}->{forecast}->{$city}, 1, 1 );
       return;
   }

   # 3. find town ID if any
   my $town_id = undef;
   $town_id = $self->{cache}->{towns}->{$city} if defined $self->{cache}->{towns}->{$city};

   unless( defined $town_id ) {   # no id == not in cache
      $request = $self->build_http_request( 'forecast', 'q', $city );
#print "forecast:",$request->uri, "\n";
   } else {
#print "forecast: found Id\n";
      # let's check first cache by id
      if( defined( $self->{cache}->{forecast}->{$town_id} ) &&                        # record in cache
       ( ( time() - $self->{cache}->{forecast}->{$town_id}->{timestamp} < 7200 ) &&   # 2-hours and
         $self->{cache}->{forecast}->{$town_id}->{result} ) )                         # not unknown error
       {
          # send cached reply so be it
#print "forecast: found by Id\n";
#print Dumper( $self->{cache}->{forecast}->{$town_id} );
          $self->deliver_answer_forecast( $where, $who, $city, $self->{cache}->{forecast}->{$town_id}, 1, 1 );
          return;
       } else {
#print "forecast: not found \n";
          $request = $self->build_http_request( 'forecast', 'id', $town_id );
       }
   }

#print "forecast ", $request->uri, "\n";

   if( defined $request ) {
      $self->{pending}->{$request} = [ $where, $who, $city ];
      $poe_kernel->post( $self->{session_id}, 'request_weather', $where, $who, $request );
      $self->action( $where, "полез смотреть прогноз в $city для $who" );
   }
 }


 sub process_alias {
   my ( $self, $where, $who, $alias, $city ) = @_;

   # 1. if target is transform, resolve it
   $city=$self->{cache}->{transforms}->{$city} if defined $self->{cache}->{transforms}->{$city};

   # 2. checking current transforms
   if( defined($self->{cache}->{transforms}->{$alias}) ) {
      if(uc($self->{cache}->{transforms}->{$alias}) eq uc($city)) {
        $self->action($where, sprintf("и так знает, что по запросу %s надо искать погоду в городе %s", $alias, $city ));
      } else {
        $self->say($where,sprintf("%s, ты гонишь, по запросу %s надо искать погоду в городе %s, а не %s", 
                                             $who, $alias, $self->{cache}->{transforms}->{$alias}, $city ));
      }
    } else {
    # 3. new transform
      my $tmp = $self->{cache}->{transforms};
      $tmp->{$alias} = $city;
      $self->{cache}->{transforms} = $tmp;
      $self->{cacheref}->sync();
      $self->action($where,sprintf("запомнил, что по запросу %s надо искать погоду в городе %s", $alias, $city ));
    }

 }

 sub process_forget {
   my ( $self, $where, $who, $alias ) =  @_;

   if( defined($self->{cache}->{transforms}->{$alias}) ) {
     $tmp = $self->{cache}->{transforms};
     delete $tmp->{$alias};
     $self->{cache}->{transforms} = $tmp;
     $self->action($where,sprintf("забыл про %s", $alias ));
   } else {
     $self->say($where,sprintf("%s, а у меня и не было замены %s", $who, $alias ));
   }
   if( defined($self->{cache}->{towns}->{$alias}) ) {
     $tmp = $self->{cache}->{towns};
     delete $tmp->{$alias};
     $self->{cache}->{towns} = $tmp;
   }
   $self->{cacheref}->sync();
 }

 sub process_flush {
   my ( $self, $where, $who, $alias ) =  @_;

   my $tmp;
   my $count = 0;

print "Flush [$alias]\n";

   if( defined($self->{cache}->{prognosis}->{$alias}) ) {
     $tmp = $self->{cache}->{prognosis};
     delete $tmp->{$alias};
     $self->{cache}->{prognosis} = $tmp;
     $count++;
   }
   if( defined($self->{cache}->{forecast}->{$alias}) ) {
     $tmp = $self->{cache}->{forecast};
     delete $tmp->{$alias};
     $self->{cache}->{forecast} = $tmp;
     $count++;
   }
   my $id = $self->{cache}->{towns}->{$alias};
   if( defined($self->{cache}->{prognosis}->{$id}) ) {
     $tmp = $self->{cache}->{prognosis};
     delete $tmp->{$id};
     $self->{cache}->{prognosis} = $tmp;
     $count++;
   }
   if( defined($self->{cache}->{forecast}->{$id}) ) {
     $tmp = $self->{cache}->{forecast};
     delete $tmp->{$id};
     $self->{cache}->{forecast} = $tmp;
     $count++;
   }
   my $city=$self->{cache}->{transforms}->{$alias};
   if( defined($self->{cache}->{prognosis}->{$city}) ) {
     $tmp = $self->{cache}->{prognosis};
     delete $tmp->{$city};
     $self->{cache}->{prognosis} = $tmp;
     $count++;
   }
   if( defined($self->{cache}->{forecast}->{$city}) ) {
     $tmp = $self->{cache}->{forecast};
     delete $tmp->{$city};
     $self->{cache}->{forecast} = $tmp;
     $count++;
   }
   $self->{cacheref}->sync();
   if( $count ) {
     $self->action($where,sprintf("сбросил все кэши для %s (%d шт)", $alias, $count ));
   } else {
     $self->action($where,sprintf("не держал кэш для %s", $alias ));
   }
 }


##  response processing

 sub process_weather_response {
    my ( $self, $where, $who, $city, $response ) = @_;
    my $result = undef;

    my $xml;
    if( $response->is_success ) {
       $result = { result => 1, xml => XMLin( $response->decoded_content, ForceArray => [ 'weather' ] ), error => "" };
#print "Weather: success ", $response->decoded_content, "\n";
       if( defined( $result->{xml}->{city} ) ) {
#print "Weather: have city in answer\n";
          # cache city ID
          # MLDBM quirk
          my $tmp = $self->{cache}->{towns};
          $tmp->{$city} = $result->{xml}->{city}->{id};
          $self->{cache}->{towns} = $tmp;
          $self->{cacheref}->sync();
       } else {
          # empty answer, city not found!
#print "Weather: NO city in answer\n";
          $result->{result} = -1;
       }
    } else {
       if( $response->code == 404 && 
          ( $xml = XMLin( $response->decoded_content ) ) &&
          $xml->{cod} == 404 ) {
print "404: ", $response->decoded_content, "\n";
          $result = { result => -1, xml => $xml, error => "City $city not found" };
       } elsif( $response->code == 502 && 
                  $response->decoded_content eq "{\"cod\":\"502\",\"message\":\"Error: Not found city\"}" ) {
print "404: ", $response->decoded_content, "\n";
          $result = { result => -1, xml => {}, error => "City $city not found" };
       } else {
print "!404: ", $response->decoded_content, "\n";
          $result = { result => 0, xml => {}, error => $response->status_line };
       }
print "Weather: error ", $response->status_line, "\n";
    }


    # cache result
    $result->{timestamp} = time();
    # MLDBM quirk
    my $tmp = $self->{cache}->{prognosis};
    $tmp->{$city} = $result;
    if( defined( $result->{xml}->{city} ) ) {
       $tmp->{$result->{xml}->{city}->{id}} = $result;
    }
    $self->{cache}->{prognosis} = $tmp;

    $self->{cacheref}->sync();

    $self->deliver_answer( $where, $who, $city, $result, 0, 0 );
 }

 sub process_forecast_response {
    my ( $self, $where, $who, $city, $response ) = @_;
    my $result = undef;

    my $xml;
    if( $response->is_success ) {
       $result = { result => 1, xml => XMLin( $response->decoded_content, ForceArray => [ 'weather' ] ), error => "" };
       unless( defined( $result->{xml}->{location} ) ) {
          # empty answer, city not found!
print "Weather(forecast): NO city in answer\n";
          $result->{result} = -1;
       }
    } else {
       if( $response->code == 404 && 
          ( $xml = XMLin( $response->decoded_content ) ) &&
          $xml->{cod} == 404 ) {
print "404: ", $response->decoded_content, "\n";
          $result = { result => -1, xml => $xml, error => "City $city not found" };
       } elsif( $response->code == 502 && 
                  $response->decoded_content eq "{\"cod\":\"502\",\"message\":\"Error: Not found city\"}" ) {
print "404: ", $response->decoded_content, "\n";
          $result = { result => -1, xml => {}, error => "City $city not found" };
       } else {
print "!404: ", $response->decoded_content, "\n";
          $result = { result => 0, xml => {}, error => $response->status_line };
       }
print "Weather: error ", $response->status_line, "\n";
    }


    # cache result
    $result->{timestamp} = time();
    # MLDBM quirk
    my $tmp = $self->{cache}->{forecast};
    $tmp->{$city} = $result;
#   todo - seek id using {towns}->{name,location} and add forecast there
#          in process_weather_response create record in {towns} if need
#    if( defined( $self->{towns}->{$result->{xml}->{city}} ) ) {
#       $tmp->{$self->{towns}->{$result->{xml}->{city}}} = $result;
#    }
    $self->{cache}->{forecast} = $tmp;
    $self->{cacheref}->sync();

    $self->deliver_answer( $where, $who, $city, $result, 0, 1 );
 }


##  answer delivering

 sub deliver_answer {
    my ( $self, $where, $who, $city, $answer, $is_cached, $is_forecast ) = @_;

    my $reply = "$who, ".($is_cached ? "(из кэша) ":"");

    if( $answer->{result} == -1 ) {
       # negative answer
       $reply .= "город $city не найден. Попробуй написать его по-английски и указать страну, например [Bangkok,TH].";
    } elsif( $answer->{result} != 1 ) {
       # request error
       $reply .= "Что-то не так: ".$answer->{error};
    } else {
       # positive answer
       if( $is_forecast ) {
          $reply .= $self->parse_forecast($answer->{xml});
       } else {
          $reply .= $self->parse_weather($answer->{xml});
       }
    }
    my @reply = split( '//', $reply );
    $self->say( $where, @reply );
 }

sub parse_weather {
    my ( $self, $xml ) = @_;

#print Dumper( $xml ), "\n";

    my $reply = "";

    $reply .= sprintf( "погода в %s(%s): %s, температура %s C, влажность %s%%, давление %s гПа, ветер %s %s м/с",
             unidecode( $xml->{city}->{name} ),
             $xml->{city}->{country},
             join( "/", 
                   map( 
                        { $self->{conditions}->{$_->{'number'}} || 
                          $_->{value}."(".$_->{'number'}.")" 
                        }  @{$xml->{weather}} 
                      ) 
             ),
             $xml->{temperature}->{value},
             $xml->{humidity}->{value},
             $xml->{pressure}->{value},
             $xml->{wind}->{direction}->{code} =~ tr/NSWE/СЮЗВ/r,
             $xml->{wind}->{speed}->{value} );
    if( defined $xml->{wind}->{gusts}->{value} ) {
       $reply .= sprintf( ", порывами до %s м/с", $xml->{wind}->{gusts}->{value} );
    }
    $reply .= sprintf( ", облачность %s%%", $xml->{clouds}->{value} );
    if( defined $xml->{visibility}->{value} ) {
       $reply .= sprintf( ", видимость %s м", $xml->{visibility}->{value} );
    }
    unless( $xml->{precipitation}->{mode} eq 'no' ) {
       $reply .= sprintf( ", %s %s мм", 
                $self->{precipitations}->{$xml->{precipitation}->{mode}} || $xml->{precipitation}->{mode},
                $xml->{precipitation}->{value} );
    }

    return $reply;
 }


sub parse_forecast {
    my ( $self, $xml ) = @_;

    my $reply = "";

    # $xml->{forecast}->{time}->[]->
    #        {from,to,symbol{number},temperature{min,max,value},windDirection{code},pressure{value},
    #        clouds{all},windSpeed{mps},percipitation{<empty>},humidity{value}}
    # $xml->{location}->{name,country} No ID!
    # {from, to}: use Date::Parse; str2time(value);

    $reply .= sprintf( "прогноз погоды в %s,%s: (время московское)",
             unidecode( $xml->{location}->{name} ),
             $xml->{location}->{country} );

    my $now = time() + 3 * 60 * 60;   # TZ offset
    my $current = int( $now / ( 60 * 60 * 6 ) ) * 60 * 60 * 6;  # 6 hours interval

    my @names = ( 'ночью', 'утром', 'днем', 'вечером' );
    my @daynames = ( '//  сегодня', '//  завтра' );

    my $lasname = '';
    my $lastcond = '';
    foreach $piece ( sort( { str2time($a->{from}) <=> str2time($b->{from}) } @{$xml->{forecast}->{time}} ) ) {
      next unless  str2time( $piece->{from} ) <= $current && str2time( $piece->{to} ) >= $current;
      my $name_index = ( $current % ( 60 * 60 * 24 ) ) / ( 60 * 60 * 6 );
      shift @daynames if $name_index == 1;
      $lastcond = '' if $name_index == 1;
      last unless @daynames;
      $current += 60 * 60 * 6;

      $reply .= $daynames[0] unless $daynames[0] eq $lastname;
      $lastname = $daynames[0];
      $reply .= " " . $names[$name_index] . ": ";
      $reply .= $self->{conditions}->{$piece->{symbol}->{number}} . ", " unless
                                                 $piece->{symbol}->{number} eq $lastcond;
      $lastcond = $piece->{symbol}->{number};
      $reply .= $piece->{temperature}->{value} . " C;";

#print $piece->{from}, " < ", $current % ( 60 * 60 * 24 ), " > ", $piece->{to}, "\n";
#print $daynames[0], " ", $names[$name_index], "\n";
#      $reply .= "//".str2time( $piece->{from} ) . ": " .$self->{conditions}->{$piece->{symbol}->{number}};
#print str2time( $piece->{from} ), " ";
#print $self->{conditions}->{$piece->{symbol}->{number}}, " ";
#print $piece->{temperature}->{min},"/",$piece->{temperature}->{max},"/",$piece->{temperature}->{value}," ";
#print $piece->{windDirection}->{code} =~ tr/NSWE/СЮЗВ/r," ";
#print $piece->{windSpeed}->{mps}," ";
#print $piece->{clouds}->{all}," ";
#print $piece->{humidity}->{value},"%\n";
print Dumper( $piece->{percipitation} ) if $piece->{percipitation};
    }

#    $reply .= "//извинитя, парселка в процессе";
    return $reply;
 }


1;
