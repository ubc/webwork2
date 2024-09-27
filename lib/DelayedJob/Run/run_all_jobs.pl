#!/usr/bin/env perl

=head1 NAME

run_all_jobs - Script for all running delayed job workers

=head1 SYNOPSIS

run_all_jobs

=back

=cut

use strict;
use warnings;

BEGIN
{
    die "WEBWORK_ROOT not found in environment.\n" unless exists $ENV{WEBWORK_ROOT};
}

use lib "$ENV{WEBWORK_ROOT}/lib";
use WeBWorK::CourseEnvironment;
use Getopt::Long;
use Pod::Usage;
use WeBWorK::Debug;
use Data::Dumper;
use DelayedJob::Service;
use sigtrap qw(handler quitHandler QUIT);

use Config;
$Config{useithreads} or die('Recompile Perl with threads to run this program.');
use threads;
use threads::shared;

my $man = 0;
my $help = 0;

GetOptions (
    'help|?' => \$help,
    man => \$man
);

pod2usage(1) if $help;

my $canRun :shared = 1;

sub quitHandler {
	print("Signal QUIT received, will stop processing after current task.\n");
	{
		lock($canRun);
		$canRun = 0;
	}
}

sub workThread {
	# prevent the wait-for-buffer-full delay in the log output
	STDOUT->autoflush(1);
	STDERR->autoflush(1);
	my $ce = WeBWorK::CourseEnvironment->new({
				webwork_dir => $ENV{WEBWORK_ROOT},
			});
	my $delayed_job_service = DelayedJob::Service->new($ce);
	my $sleep = $ENV{DELAYED_JOB_SLEEP} // 10;
	my $numJobsDone = 0;
	# each thread will only do 10 jobs before being recreated
	while ($numJobsDone <= 10) {
		# work_once() returns 1 if it actually found a job to do, 0 otherwise
		my $didWork = $delayed_job_service->work_once();
		if ($didWork) { $numJobsDone++; }
		sleep($sleep);
		# check if we need to stop due to SIGQUIT
		if (!$canRun) { last; }
	}
}

while ($canRun) {
	print("*** Starting new thread\n");
	my $workThr = threads->create(\&workThread);
	# thread join is blocking, which delays handling of SIGQUIT until the
	# thread has finished. So we won't call it until we know the join call
	# won't block.
	while (!$workThr->is_joinable()) {
		sleep(1);
	}
	$workThr->join();
}
