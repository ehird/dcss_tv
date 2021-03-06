#! /usr/bin/perl

# Fetch daemon.

use strict;
use warnings;

use threads;
use threads::shared;

use Fcntl qw/LOCK_EX/;
use IO::Socket::INET;
use IO::Handle;

use CSplat::Config qw/$FETCH_PORT/;
use CSplat::Ttyrec qw/clear_cached_urls fetch_ttyrecs/;
use CSplat::Seek qw/tty_frame_offset/;
use CSplat::Select qw/interesting_game/;
use CSplat::Xlog qw/xlog_hash xlog_str desc_game/;

use POSIX;

my $LOCK_FILE = '.fetch.lock';
my $LOG_FILE = '.fetch.log';
my $LOCK_HANDLE;

my $lastsync;

local $| = 1;

acquire_lock();
daemonize();
run_fetch();

sub daemonize {
  print "Starting fetch server\n";

  #my $pid = fork;
  #exit if $pid;
  #die "Failed to fork: $!\n" unless defined $pid;

  # [ds] Stay in the same session so that the fetch daemon is killed when the
  # parent process is killed.
  #setsid;
  open my $logf, '>', $LOG_FILE or die "Can't write $LOG_FILE: $!\n";
  $logf->autoflush;
  open STDOUT, '>&', $logf or die "Couldn't redirect stdout\n";
  open STDERR, '>&', $logf or die "Couldn't redirect stderr\n";
  STDOUT->autoflush;
  STDERR->autoflush;
}

sub acquire_lock {
  my $failmsg =
    "Failed to lock $LOCK_FILE: another fetch daemon may be running\n";
  eval {
    # local $SIG{ALRM} =
    #   sub {
    #     die "alarm\n";
    #   };
    # alarm 3;

    print "Trying to lock $LOCK_FILE\n";
    open $LOCK_HANDLE, '>', $LOCK_FILE or die "Couldn't open $LOCK_FILE: $!\n";
    flock $LOCK_HANDLE, LOCK_EX or die $failmsg;
    print "Locked $LOCK_FILE\n";
  };
  die $failmsg if $@ eq "alarm\n";
}

sub run_fetch {
  print "Starting fetch service\n";
  my $server = IO::Socket::INET->new(LocalPort => $FETCH_PORT,
                                     Type => SOCK_STREAM,
                                     Reuse => 1,
                                     Listen => 5)
    or die "Couldn't open server socket on $FETCH_PORT: $@\n";

  while (my $client = $server->accept()) {
    my $thread = threads->new(sub {
      eval {
        process_command($client);
      };
      warn "$@" if $@;
    });
    $thread->detach;
  }
}

sub process_command {
  my $client = shift;
  my $command = <$client>;
  chomp $command;
  my ($cmd) = $command =~ /^(\w+)/;
  return unless $cmd;

  if ($cmd eq 'G') {
    my ($game) = $command =~ /^\w+ (.*)/;

    my $g = xlog_hash($game);
    my $have_cache = CSplat::Ttyrec::have_cached_listing_for_game($g);

    my $res;
    eval {
      $res = fetch_game($client, $game)
    };
    warn "$@" if $@;
    if ($@ && $have_cache) {
      CSplat::Ttyrec::clear_cached_urls_for_game($g);
      eval {
        $res = fetch_game($client, $game);
      };
      warn "$@" if $@;
    }

    if ($@) {
      print $client "FAIL $@\n";
    }
    $res
  }
  elsif ($cmd eq 'CLEAR') {
    clear_cached_urls();
    print $client "OK\n";
  }
}

sub fetch_notifier {
  my ($client, $g, @event) = @_;
  my $text = join(" ", @event);
  eval {
    print $client "S $text\n";
  };
  warn $@ if $@;
}

sub fetch_game {
  my ($client, $g) = @_;

  print "Requested download: $g\n";

  my $listener = sub {
    fetch_notifier($client, $g, @_);
  };

  $g = xlog_hash($g);

  my $start = $g->{start};
  my $nocheck = $g->{nocheck};
  delete $g->{nocheck};
  delete @$g{qw/start nostart/} if $g->{nostart};
  my $result = fetch_ttyrecs($listener, $g, $nocheck);
  $g->{start} = $start;
  if ($result) {
    my $dejafait = $g->{id};
    if ($dejafait) {
      print "Not redownloading ttyrecs for ", desc_game($g), "\n";
    }
    else {
      print "Downloaded ttyrecs for ", desc_game($g), " ($g->{ttyrecs})\n";
    }

    if ($@) {
      warn $@;
      CSplat::DB::delete_game($g);
      print $client "FAIL $@\n";
    }
    else {
      print $client "OK " . xlog_str($g, 1) . "\n";
    }
  } else {
    print "Failed to download ", desc_game($g), "\n";
    die "Failed to download game\n";
  }
}
