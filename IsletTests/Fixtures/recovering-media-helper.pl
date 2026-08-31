#!/usr/bin/perl
use strict;
use warnings;

my ($kind) = @ARGV;
die "usage: recovering-media-helper.pl KIND\n" unless defined $kind;

select((select(STDOUT), $| = 1)[0]);
if ($kind eq "stream") {
  print STDOUT "{\"type\":\"data\",\"diff\":false,\"payload\":{}}\n";
  while (1) {
    select undef, undef, undef, 60;
  }
}

if ($kind eq "get") {
  print STDOUT '{"processIdentifier":15305,"bundleIdentifier":"company.thebrowser.Browser",'
    . '"title":"Recovered video","artist":"Sidemen","playing":false,"playbackRate":0}'
    . "\n";
  exit 0;
}

die "unsupported kind: $kind\n";
