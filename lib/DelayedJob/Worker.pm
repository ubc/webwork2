package DelayedJob::Worker;
use base qw( TheSchwartz::Worker );

##### Library Imports #####
use strict;
use warnings;
use WeBWorK::Debug;
use Data::Dumper;

sub grab_for {
	# How long a worker can monopolize a job, after this time, the job will
	# be available for another worker to grab on the assumption that something
	# went wrong and the job failed without being marked as failed.
	return $ENV{DELAYED_JOB_GRAB_FOR} // 60*60*2; # defaults to 2 hours
}

sub max_retries {
    return 1;
}

sub retry_delay {
    my $class = shift;
    my $num_failures = shift;
	my $delaySeconds = $ENV{DELAYED_JOB_RETRY_DELAY} // 60*15; # default 15 min

    return $num_failures * $delaySeconds + 1;
}

1;
