#!/usr/bin/perl
use strict;
use warnings;

my ($kind, $state_file) = @ARGV;
die "usage: wrong-app-recovery-helper.pl KIND STATE_FILE\n" unless defined $kind && defined $state_file;

select((select(STDOUT), $| = 1)[0]);
if ($kind eq "stream") {
  print STDOUT "{\"type\":\"data\",\"diff\":false,\"payload\":{}}\n";
  while (1) {
    select undef, undef, undef, 60;
  }
}

if ($kind eq "get") {
  if (!-e $state_file) {
    open my $state, '>', $state_file or die "cannot create $state_file: $!\n";
    close $state;
    print STDOUT '{"processIdentifier":15305,"bundleIdentifier":"com.apple.Music",'
      . '"title":"Wrong app","artist":"Someone else","playing":false,"playbackRate":0}'
      . "\n";
  } else {
    print STDOUT '{"processIdentifier":15306,"bundleIdentifier":"company.thebrowser.Browser",'
      . '"title":"Recovered video","artist":"Sidemen","playing":false,"playbackRate":0}'
      . "\n";
  }
  exit 0;
}

die "unsupported kind: $kind\n";
