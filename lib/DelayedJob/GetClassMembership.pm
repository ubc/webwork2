package DelayedJob::GetClassMembership;
use base qw( DelayedJob::Worker );

##### Library Imports #####
use strict;
use warnings;
use WeBWorK::CourseEnvironment;
use WeBWorK::DB;
use WeBWorK::Debug;
use Data::Dumper;
use TheSchwartz::Job;
use LTI1p3::Service::NamesAndRoleService;
use LTI1p3::Importer::CourseUpdater;

sub grab_for {
	# How long before we assume a job failed and another worker retries it.
	# Came across a 5100+ student course that took ~4 hours (I think the fault
	# is inefficient code on our part). The job didn't fail, the worker
	# eventually finishes, but other workers picked up the job assuming it
	# failed and we ended up with a bunch of blocked workers as jobs piled up.
	return $ENV{DELAYED_JOB_NRPS_GRAB_FOR} // 60 * 60 * 8;    # defaults to 8 hours
}

sub work {
	my $class                = shift;
	my TheSchwartz::Job $job = shift;
	my $args                 = $job->arg;

	my $courseName = $args->{courseName};

	$job->debug("Job: " . $job->jobid . ". Fetching Course LTI Names and Roles for course_id: $courseName");

	my $ce = WeBWorK::CourseEnvironment->new({
		webwork_dir => $ENV{WEBWORK_ROOT},
		courseName  => $courseName,
	});
	my $db = new WeBWorK::DB($ce);

	my $names_and_roles_service = LTI1p3::Service::NamesAndRoleService->new($ce, $db);
	my $membership              = $names_and_roles_service->getAllNamesAndRole();
	unless ($membership) {
		my $error_msg = "There was an issue fetching the class roster for course_id: $courseName. "
			. $names_and_roles_service->{error};
		$job->debug($error_msg);
		$job->failed($error_msg);
		return;
	}
	my $updater = LTI1p3::Importer::CourseUpdater->new($ce, $db, $membership);
	my $ret     = $updater->updateCourse();
	if ($ret) {
		my $error_msg = "Update Class Roster failed for course_id: $courseName: $ret";
		$job->debug($error_msg);
		$job->failed($error_msg);
		return;
	}
	$job->debug("Job: " . $job->jobid . ". Successfully fetched LTI Names and Roles for course_id: $courseName");
	$job->completed();
}

1;
