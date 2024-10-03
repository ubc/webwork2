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
use POSIX ":sys_wait_h"; # for WNOHANG

my $man = 0;
my $help = 0;

GetOptions (
    'help|?' => \$help,
    man => \$man
);

pod2usage(1) if $help;

my $canRun = 1;

sub quitHandler {
	print("Signal QUIT received, stopping processing.\n");
	$canRun = 0;
}

sub processJobs {
	my $ce = WeBWorK::CourseEnvironment->new({
				webwork_dir => $ENV{WEBWORK_ROOT},
			});
	my $delayed_job_service = DelayedJob::Service->new($ce);
	my $sleep = $ENV{DELAYED_JOB_SLEEP} // 10;
	my $numJobsDone = 0;
	# each thread will do 100 jobs before being recreated
	while ($numJobsDone < 100) {
		# work_once() returns 1 if it actually found a job to do, 0 otherwise
		my $didWork = $delayed_job_service->work_once();
		if ($didWork) { $numJobsDone++; }
		sleep($sleep);
		# check if we need to stop due to SIGQUIT
		if (!$canRun) { last; }
	}
}

my $numCycles = 0;
my $pid = 0;
while ($canRun) {
	print("*** Starting new fork $numCycles\n");
	$pid = fork;
	if (!defined $pid) {
		warn "Failed to fork: $!";
		exit;
	}
	elsif ($pid == 0) { # we're the child pid actually processing jobs
		processJobs();
		exit;
	}
	# nonblocking wait so we can propagate the quit signal to child
	while (waitpid($pid, WNOHANG) == 0) {
		if (!$canRun) { kill('QUIT', $pid); }
		sleep(1);
	}
	undef($pid);
	$numCycles++;
}
