#!/usr/bin/env perl

# DelayedJob::PushClassGrades must not ask TheSchwartz for a retry when every error in
# the push was a rejection only the LMS side can clear (see t/lti_ags_grade_responses.t).
# A retry re-runs the whole push, hours for a big course, and meets the same rejection.
# permanent_failure still writes the job's error row (so the LMS-rejection metrics and
# alerts see it) but removes the job instead of scheduling it again.
#
# The real dependencies only exist in the built image, so this stands in for them.

use strict;
use warnings;

use Test::More;
use FindBin;

BEGIN {
	# Loaded by DelayedJob::PushClassGrades but not installed in the test container.
	for my $module (qw(WeBWorK::CourseEnvironment WeBWorK::DB WeBWorK::Debug TheSchwartz::Job TheSchwartz::Worker
		LTI1p3::Service::AssignmentAndGradeService))
	{
		(my $file = "$module.pm") =~ s{::}{/}g;
		$INC{$file} = __FILE__;
	}
}

package WeBWorK::Debug {

	sub import {
		no strict 'refs';
		*{ caller() . '::debug' } = sub { }
	}
}

package TheSchwartz::Worker {
	# base.pm refuses a parent package with no symbols.
	our $VERSION = '0';
}

package WeBWorK::CourseEnvironment {
	sub new { return bless {}, shift }
}

package WeBWorK::DB {
	sub new { return bless {}, shift }
}

# What the push "found": set by each test before the job runs.
our %push_result;

package LTI1p3::Service::AssignmentAndGradeService {
	sub new                     { my $class = shift; return bless {%main::push_result}, $class }
	sub pushAllAssignmentGrades { }
}

package TheSchwartz::Job {
	sub new               { return bless { calls => [] }, shift }
	sub arg               { return { courseName => 'TEST_COURSE' } }
	sub jobid             {42}
	sub debug             { }
	sub completed         { push @{ $_[0]{calls} }, ['completed'] }
	sub failed            { push @{ $_[0]{calls} }, [ 'failed',            $_[1] ] }
	sub permanent_failure { push @{ $_[0]{calls} }, [ 'permanent_failure', $_[1] ] }
}

package main;

use lib "$FindBin::Bin/../lib";
require DelayedJob::PushClassGrades;

sub run_job {
	%push_result = @_;
	my $job = TheSchwartz::Job->new;
	DelayedJob::PushClassGrades->work($job);
	return $job->{calls};
}

my $calls = run_job(error => '');
is_deeply($calls, [ ['completed'] ], 'a clean push completes the job');

$calls = run_job(error => "Score POST request failed.\nStatus: 502 Bad Gateway", error_is_retryable => 1);
is(scalar(@$calls), 1,        'a retryable error ends the job once');
is($calls->[0][0],  'failed', '... with failed, so TheSchwartz retries it');
like($calls->[0][1], qr/TEST_COURSE.*Status: 502/s, '... and records the course and the LMS error');

$calls = run_job(
	error => "Score POST request failed.\nStatus: 422 Unprocessable Entity\nThis assignment is still unpublished",
	error_is_retryable => 0
);
is(scalar(@$calls), 1,                   'a permanent rejection ends the job once');
is($calls->[0][0],  'permanent_failure', '... with permanent_failure, so the whole push is not re-run');
like($calls->[0][1], qr/TEST_COURSE.*still unpublished/s, '... and still records the course and the LMS error');

done_testing();
