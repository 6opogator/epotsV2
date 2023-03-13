# epotsV2
Simple IRC bot based on [POE::Component](https://metacpan.org/pod/POE::Component) framework.

Spoken language is Russian, sometimes right in code.

To run on fresh Debian-like install you need prerequisites:
```
apt install libpoe-component-irc-perl libpoe-component-sslify-perl libhdate-perl libpoe-component-client-http-perl
apt install libtext-unidecode-perl libtext-trim-perl liburi-encode-perl libxml-simple-perl libmldbm-perl
```
Supplied addons include:
* Weather state and forecast (you need API key from https://openweathermap.org)
* Quiz with scoring system
* Collect and present random $topic from channel's history
* Just telling random stuff from text files (jokes, anecdotes, limerics etc.)
* `calendar` integration
* Hebrew calendar and holydays tracker with parshot and Shabbat times

This is a pet project, please use only as reference.
