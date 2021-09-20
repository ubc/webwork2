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
use LTIAdvantage::Service::NamesAndRoleService;
use LTIAdvantage::Importer::CourseUpdater;

sub work {
    my $class = shift;
    my TheSchwartz::Job $job = shift;
    my $args = $job->arg;

    my $courseName = $args->{courseName};
    my $ce = WeBWorK::CourseEnvironment->new({
            webwork_dir => $ENV{WEBWORK_ROOT},
            courseName => $courseName,
        });
    my $db = new WeBWorK::DB($ce->{dbLayout});

    $job->debug("Job: " . $job->jobid . ". Fetching Course LTI Names and Roles for course_id: $courseName");
    my $names_and_roles_service = LTIAdvantage::Service::NamesAndRoleService->new($ce, $db);
    my $membership = $names_and_roles_service->getAllNamesAndRole();
    unless ($membership) {
        my $error_msg = "There was an issue fetching the class roster for course_id: $courseName. ".$names_and_roles_service->{error};
        $job->debug($error_msg);
        $job->failed($error_msg);
        return;
    }
    my $updater = LTIAdvantage::Importer::CourseUpdater->new($ce, $db, $membership);
    my $ret = $updater->updateCourse();
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
