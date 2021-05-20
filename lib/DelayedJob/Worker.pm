package DelayedJob::Worker;
use base qw( TheSchwartz::Worker );

##### Library Imports #####
use strict;
use warnings;
use WeBWorK::Debug;
use Data::Dumper;

sub max_retries {
	return 3;
}

sub retry_delay {
    my $class = shift;
    my $num_failures = shift;

	return $num_failures * 30;
}

1;
