#!/usr/bin/perl
use strict;
use warnings;

my ($kind, $state_file, $failure_mode) = @ARGV;
die "usage: recovery-failure-helper.pl KIND STATE_FILE MODE\n"
  unless defined $kind && defined $state_file && defined $failure_mode;
die "MODE must be invalid or timeout\n"
  unless $failure_mode eq "invalid" || $failure_mode eq "timeout";

select((select(STDOUT), $| = 1)[0]);
if ($kind eq "stream") {
  # Force the startup snapshot to run before the first live record. The test clears this marker at
  # the live idle barrier so recovery still begins with fixture attempt one.
  my $startup_seen = 0;
  for (1 .. 200) {
    if (-e $state_file) {
      $startup_seen = 1;
      last;
    }
    select undef, undef, undef, 0.01;
  }
  die "startup snapshot did not run\n" unless $startup_seen;
  print STDOUT "{\"type\":\"data\",\"diff\":false,\"payload\":{}}\n";
  while (1) {
    select undef, undef, undef, 60;
  }
}

if ($kind eq "get") {
  my $attempt = 1;
  if (-e $state_file) {
    open my $state, "<", $state_file or die "cannot read $state_file: $!\n";
    my $previous = <$state>;
    close $state;
    chomp $previous;
    $attempt = $previous + 1;
  }
  open my $state, ">", $state_file or die "cannot create $state_file: $!\n";
  print {$state} "$attempt\n";
  close $state;

  if ($attempt == 1) {
    print STDOUT '{"processIdentifier":15305,'
      . '"bundleIdentifier":"company.thebrowser.Browser",'
      . '"title":"Cached video","artist":"Sidemen","album":"Videos",'
      . '"duration":120,"elapsedTime":40,"playing":false}'
      . "\n";
    exit 0;
  }
  if ($failure_mode eq "invalid") {
    print STDOUT "not json\n";
    exit 0;
  }

  print STDOUT " ";
  $SIG{TERM} = sub { exit 0 };
  $SIG{INT} = sub { exit 0 };
  while (1) {
    select undef, undef, undef, 60;
  }
}

die "unsupported kind: $kind\n";
