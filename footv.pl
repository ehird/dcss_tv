#! /usr/bin/perl

use strict;
use warnings;

use Getopt::Long;
use CSplat::DB qw/open_db/;
use CSplat::Xlog qw/desc_game desc_game_brief xlog_hash xlog_str/;
use CSplat::Ttyrec qw/request_download/;
use CSplat::Select qw/filter_matches make_filter/;
use CSplat::Termcast;
use CSplat::Request;
use CSplat::ChannelMonitor;
use CSplat::Channel;
use Term::TtyRec::Plus;
use IO::Socket::INET;
use Date::Manip;
use Fcntl qw/SEEK_SET/;

use threads;
use threads::shared;

my %opt;

my @queued_fetch : shared;
my @queued_playback : shared;
my @stop_list : shared;

my @recently_played;
my $DUPE_SUPPRESSION_THRESHOLD = 5;

# Fetch mode by default.
GetOptions(\%opt, 'local', 'local-request',
           'simple', 'auto_channel=s') or die;

# An appropriately Crawlish number.
my $PLAYLIST_SIZE = 9;

# Socket for splat requests.
my $REQUEST_HOST = $ENV{PLAYLIST_HOST} || '127.0.0.1';
my $REQUEST_PORT = $ENV{PLAYLIST_PORT} || 21976;
my $TERMCAST_CHANNEL = $opt{auto_channel} || $ENV{TERMCAST_CHANNEL} || 'FooTV';
my $REQUEST_IRC_CHANNEL = $ENV{REQUEST_IRC_CHANNEL} || '##crawl';
my $AUTO_CHANNEL_DIR = 'channels';

$REQUEST_HOST = 'localhost' if $opt{'local-request'};

local $SIG{CHLD} = 'IGNORE';

sub get_game_matching {
  my $g = shift;
  download_game($g)
}

sub download_notifier {
  my $msg = shift;
  push @queued_fetch, "msg: $msg";
}

sub download_game {
  my $g = shift;

  my $start = $g->{start};
  warn "Downloading ttyrecs for ", desc_game($g), "\n";

  $g->{nocheck} = 'y';
  return undef unless request_download($g, \&download_notifier);
  delete @$g{qw/nostart nocheck/};
  $g
}

sub fetch_game_for_playback {
  my ($g, $verbose) = @_;

  push @queued_fetch, xlog_str($g);
  my $game = get_game_matching($g);
  if ($game) {
    $game->{req} = $g->{req};
    push @queued_playback, xlog_str($game, 1);
  } else {
    $g->{failed} = 1;
    push @queued_fetch, xlog_str($g);
  }
}

sub game_key {
  my $g = shift;
  "$$g{name}:$$g{src}:$$g{rstart}"
}

sub dedupe_auto_footv_game {
  my $game = shift;
  my $g = canonicalize_game(xlog_hash($game));
  my $game_key = game_key($g);
  return undef if (grep($_ eq $game_key, @recently_played));
  push @recently_played, $game_key;
  if (@recently_played > $DUPE_SUPPRESSION_THRESHOLD) {
    shift @recently_played;
  }
  $g
}

sub queue_games_automatically {
  while (1) {
    if (!CSplat::Channel::channel_exists($TERMCAST_CHANNEL)) {
      terminate_auto_footv();
    }

    my $def = CSplat::Channel::channel_def($TERMCAST_CHANNEL);
    my $list_attempts = 30;
    while (@queued_playback < 5 && $list_attempts-- > 0) {
      my $game = CSplat::ChannelServer::query_game($def);
      unless ($game) {
        print "Channel server provided no game for $def, will retry later\n";
        last;
      }

      my $nondupe_game = dedupe_auto_footv_game($game);
      if ($nondupe_game) {
        $$nondupe_game{req} = $TERMCAST_CHANNEL;
        fetch_game_for_playback($nondupe_game);
      }
    }
    sleep 3;
  }
}

sub canonicalize_game {
  my $g = shift;
  $g->{start} = $g->{rstart};
  $g->{end} = $g->{rend};
  $g->{time} = $g->{rtime};
  $g
}

sub next_request {
  my $REQ = shift;
  my $g;

  $g = canonicalize_game($REQ->next_request());

  $g->{cancel} = 'y' if ($g->{nuke} || '') eq 'y';

  if (($g->{cancel} || '') eq 'y') {
    my $filter = CSplat::Select::make_filter($g);
    $filter = { } if $g->{nuke};
    @queued_playback =
      grep(!CSplat::Select::filter_matches($filter, xlog_hash($_)),
           @queued_playback);

    warn "Adding ", desc_game($g), " to stop list\n";
    push @stop_list, xlog_str($g);
    push @queued_fetch, xlog_str($g);
  }
  else {
    fetch_game_for_playback($g, 'verbose');
  }
}

sub check_irc_requests {
  my $REQ = CSplat::Request->new(host => $REQUEST_HOST,
                                 port => $REQUEST_PORT);

  while (1) {
    next_request($REQ);
    sleep 1;
  }
}

sub terminate_auto_footv {
  print "Channel $TERMCAST_CHANNEL went away, exiting\n";
  exit 0;
}

sub check_requests {
  open_db();
  if ($opt{auto_channel} && !$opt{simple}) {
    queue_games_automatically();
  }
  else {
    check_irc_requests();
  }
}

sub tv_show_playlist {
  my ($TV, $rplay, $prev) = @_;

  $TV->clear();
  if ($prev) {
    $prev = desc_game_brief($prev);
    $TV->write("\e[1H\e[1;37mLast game played:\e[0m\e[2H\e[1;33m$prev.\e[0m");
  }

  my $pos = 1 + ($prev ? 3 : 0);
  $TV->write("\e[$pos;1H\e[1;37mComing up:\e[0m");
  $pos++;

  my $first = 1;
  my @display = @$rplay;
  if (@display > $PLAYLIST_SIZE) {
    @display = @display[0 .. ($PLAYLIST_SIZE - 1)];
  }
  for my $game (@display) {
    # Move to right position:
    $TV->write("\e[$pos;1H",
               $first? "\e[1;34m" : "\e[0m",
               desc_game_brief($game));
    $TV->write("\e[0m") if $first;
    undef $first;
    ++$pos;
  }
}

sub cancel_playing_games {
  if (@stop_list) {
    my @stop = @stop_list;
    @stop_list = ();

    my $g = shift;

    if (grep /nuke=y/, @stop) {
      return 'stop';
    }

    my @filters = map(CSplat::Select::make_filter(xlog_hash($_)), @stop);

    if (grep(CSplat::Select::filter_matches($_, $g), @filters)) {
      return 'stop';
    }
  }
}

sub update_status {
  my ($TV, $line, $rlmsg, $slept, $rcountup) = @_;
  my $xlog = $line !~ /^msg: /;

  if ($xlog) {
    my $f = xlog_hash($line);
    $$f{req} ||= $TERMCAST_CHANNEL;
    if (($f->{cancel} || '') eq 'y') {
      if ($f->{nuke}) {
        $TV->write("\e[1;35mPlaylist clear by $f->{req}\e[0m\r\n");
      } else {
        $TV->write("\e[1;35mCancel by $f->{req}\e[0m\r\n",
                   desc_game_brief($f), "\r\n");
      }
      $$rlmsg = $slept + 1;
    } elsif ($f->{failed}) {
      $TV->write("\e[1;31mFailed to fetch game:\e[0m\r\n",
                 desc_game_brief($f), "\r\n");
      $$rlmsg = $slept + 1;
    } else {
      $TV->write("\e[1;34mRequest by $$f{req}:\e[0m\r\n",
                 desc_game_brief($f), "\r\n");
      $TV->write("\r\nPlease wait, fetching game...\r\n");
      undef $$rlmsg;
    }
    $$rcountup = 1;
  }
  else {
    ($line) = $line =~ /^msg: (.*)/;
    $TV->write("$line\r\n");
  }
}

sub exec_channel_player {
  my $channel = shift;
  exec("perl $0 --auto_channel \Q$channel")
}

sub channel_player {
  my $channel = shift;
  my $player_pid = fork();
  if (!$player_pid) {
    exec_channel_player($channel);
    exit;
  }
  $player_pid
}

sub channel_monitor {
  my $channel_monitor = CSplat::ChannelMonitor->new(\&channel_player);
  $channel_monitor->run;
}

# Starts the thread to monitor for custom channels.
sub start_channel_monitor {
  my $channel_monitor = threads->new(\&channel_monitor);
  $channel_monitor->detach;
  $channel_monitor
}

sub channel_password_file {
  if ($opt{auto_channel}) {
    CSplat::Channel::generate_password_file($TERMCAST_CHANNEL)
  }
  else {
    "$TERMCAST_CHANNEL.pwd"
  }
}

sub request_tv {
  print("Connecting to TV: name: $TERMCAST_CHANNEL, passfile: ", channel_password_file(), "\n");
  my $TV = CSplat::Termcast->new(name => $TERMCAST_CHANNEL,
                                 passfile => channel_password_file(),
                                 local => $opt{local});

  my $last_game;

  open_db();

  if (!$opt{local} && !$opt{auto_channel} && !$opt{simple}) {
    start_channel_monitor();
  }

  my $rcheck = threads->new(\&check_requests);
  $rcheck->detach;

  $TV->callback(\&cancel_playing_games);

 RELOOP:
  while (1) {
    $TV->clear();
    $TV->write("\e[1H");
    if ($last_game) {
      $TV->clear();
      $TV->write("\e[1H");
      $TV->write("\e[1;37mThat was:\e[0m\r\n\e[1;33m");
      $TV->write(desc_game_brief($last_game));
      $TV->write("\e[0m\r\n\r\n");
    }

    unless ($opt{auto_channel}) {
      $TV->write("Waiting for requests (use !tv on $REQUEST_IRC_CHANNEL to request a game).");
      $TV->write("\r\n\r\n");
    }

    my $slept = 0;
    my $last_msg = 0;
    my $countup;
    while (1) {
      while (@queued_fetch) {
        update_status($TV, shift(@queued_fetch), \$last_msg, $slept, \$countup);
      }

      if (@queued_playback) {
        my @copy = map(xlog_hash($_), @queued_playback);
        tv_show_playlist($TV, \@copy, $last_game);
        sleep 4 if $slept == 0;
        last;
      }

      ++$slept if $countup;
      next RELOOP if $last_msg && $slept - $last_msg > 20;
      sleep 1;
    }

    my $line = shift(@queued_playback);
    if ($line) {
      my $g = xlog_hash($line);
      warn "Playing ttyrec for ", desc_game($g), " for $TERMCAST_CHANNEL\n";
      $TV->play_game($g);
      $last_game = $g;
    }
  }
}

request_tv();
