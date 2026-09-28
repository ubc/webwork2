package DelayedJob::PushClassGrades;
use base qw( DelayedJob::Worker );

##### Library Imports #####
use strict;
use warnings;
use WeBWorK::CourseEnvironment;
use WeBWorK::DB;
use WeBWorK::Debug;
use Data::Dumper;
use TheSchwartz::Job;
use LTI1p3::Service::AssignmentAndGradeService;

sub grab_for {
	# How long before we assume a job failed and another worker retries it. A
	# whole-class push makes one AGS request per student per linked assignment,
	# so on a very large course it can outlive the 2 hour DelayedJob::Worker
	# default, and another worker would then start a second copy of a push that
	# is still running. GetClassMembership measured a 5,100-student course at
	# ~4 hours; UBC's largest (6,518 students, 56 links, 2026-09-28) is bigger.
	# TheSchwartz asks the worker class, not the job, so this cannot vary per
	# course; 8 hours matches DelayedJob::GetClassMembership.
	# Trade-off: if a worker really dies mid push, the class push waits up to
	# this long for a retry. Per-user pushes (PushUserGrades) keep 2 hours.
	return $ENV{DELAYED_JOB_CLASS_GRADES_GRAB_FOR} // 60 * 60 * 8;    # defaults to 8 hours
}

sub work {
	my $class                = shift;
	my TheSchwartz::Job $job = shift;
	my $args                 = $job->arg;

	my $courseName = $args->{courseName};

	$job->debug("Job: " . $job->jobid . ". Sending Course LTI Assignment and Grades for course_id: $courseName");

	my $ce = WeBWorK::CourseEnvironment->new({
		webwork_dir => $ENV{WEBWORK_ROOT},
		courseName  => $courseName,
	});
	my $db = new WeBWorK::DB($ce);

	my $assignment_and_grade_service = LTI1p3::Service::AssignmentAndGradeService->new($ce, $db);
	$assignment_and_grade_service->pushAllAssignmentGrades();

	if ($assignment_and_grade_service->{error}) {
		my $error_msg = "There was an issue pushing the class grades for course_id: $courseName. "
			. $assignment_and_grade_service->{error};
		$job->debug($error_msg);
		$job->failed($error_msg);
	} else {
		$job->debug("Job: " . $job->jobid . ". Successfully sent LTI Assignment and Grades for course_id: $courseName");
		$job->completed();
	}
}

1;
