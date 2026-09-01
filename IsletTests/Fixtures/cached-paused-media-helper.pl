#!/usr/bin/perl
use strict;
use warnings;

my ($kind, $state_file) = @ARGV;
die "usage: cached-paused-media-helper.pl KIND STATE_FILE\n"
  unless defined $kind && defined $state_file;

select((select(STDOUT), $| = 1)[0]);
if ($kind eq "stream") {
  print STDOUT "{\"type\":\"data\",\"diff\":false,\"payload\":{}}\n";
  while (1) {
    select undef, undef, undef, 60;
  }
}

if ($kind eq "get") {
  print STDOUT '{"processIdentifier":15305,"bundleIdentifier":"company.thebrowser.Browser",'
    . '"title":"Cached video","artist":"Sidemen","album":"Videos",'
    . '"duration":120,"elapsedTime":40,"playing":false,"playbackRate":0}'
    . "\n";
  close STDOUT or die "close stdout: $!";
  open my $state, ">>", $state_file or die "open state file: $!";
  print {$state} "get\n";
  close $state or die "close state file: $!";
  exit 0;
}

die "unsupported kind: $kind\n";
