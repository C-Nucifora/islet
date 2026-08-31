#!/usr/bin/perl
use strict;
use warnings;

my ($kind, $state_file, $wrong_limit, $idle_count) = @ARGV;
die "usage: wrong-app-recovery-helper.pl KIND STATE_FILE [WRONG_LIMIT] [IDLE_COUNT]\n"
  unless defined $kind && defined $state_file;
$wrong_limit = 1 unless defined $wrong_limit;
$idle_count = 1 unless defined $idle_count;
die "WRONG_LIMIT must be a non-negative integer\n" unless $wrong_limit =~ /^\d+$/;
die "IDLE_COUNT must be a positive integer\n" unless $idle_count =~ /^[1-9]\d*$/;

select((select(STDOUT), $| = 1)[0]);
if ($kind eq "stream") {
  print STDOUT "{\"type\":\"data\",\"diff\":false,\"payload\":{}}\n";
  if ($idle_count > 1) {
    for (1 .. 500) {
      my $attempt = 0;
      if (-e $state_file) {
        open my $state, '<', $state_file or die "cannot read $state_file: $!\n";
        my $value = <$state>;
        close $state;
        $attempt = $value if defined $value && $value =~ /^\d+$/;
      }
      last if $attempt >= 3;
      select undef, undef, undef, 0.01;
    }
    select undef, undef, undef, 0.1;
    print STDOUT "{\"type\":\"data\",\"diff\":false,\"payload\":{}}\n";
  }
  while (1) {
    select undef, undef, undef, 60;
  }
}

if ($kind eq "get") {
  my $attempt = 1;
  if (-e $state_file) {
    open my $state, '<', $state_file or die "cannot read $state_file: $!\n";
    my $previous = <$state>;
    close $state;
    chomp $previous;
    $attempt = $previous + 1;
  }
  open my $state, '>', $state_file or die "cannot create $state_file: $!\n";
  print {$state} "$attempt\n";
  close $state;

  if ($attempt <= $wrong_limit) {
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
