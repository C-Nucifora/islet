#!/usr/bin/perl
use strict;
use warnings;

my ($kind, $log_path) = @ARGV;
die "usage: hanging-media-helper.pl KIND LOG_PATH\n" unless defined $kind && defined $log_path;

my $lock_path = "$log_path.$kind.lock";
if (!mkdir $lock_path) {
  open my $overlap, ">>", $log_path or die "open $log_path: $!";
  print {$overlap} "overlap $kind $$\n";
  close $overlap;
}

open my $log, ">>", $log_path or die "open $log_path: $!";
select((select($log), $| = 1)[0]);
print {$log} "started $kind $$\n";
close $log;

my $cleanup = sub {
  rmdir $lock_path;
  exit 0;
};
$SIG{TERM} = $cleanup;
$SIG{INT} = $cleanup;

# Block in this process. Spawning sleep(1) here would leave a descendant holding inherited pipes
# after the test kills the helper, which is a different failure mode from the adapter stall.
while (1) {
  select undef, undef, undef, 60;
}
