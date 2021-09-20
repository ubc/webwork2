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
use LTIAdvantage::Service::AssignmentAndGradeService;

sub work {
    my $class = shift;
    my TheSchwartz::Job $job = shift;
    my $args = $job->arg;

    my $courseName = $args->{courseName};

    $job->debug("Job: " . $job->jobid . ". Sending Course LTI Assignment and Grades for course_id: $courseName");

    my $ce = WeBWorK::CourseEnvironment->new({
            webwork_dir => $ENV{WEBWORK_ROOT},
            courseName => $courseName,
        });
    my $db = new WeBWorK::DB($ce->{dbLayout});

    my $assignment_and_grade_service = LTIAdvantage::Service::AssignmentAndGradeService->new($ce, $db);
    $assignment_and_grade_service->pushAllAssignmentGrades();

    if ($assignment_and_grade_service->{error}) {
        my $error_msg = "There was an issue pushing the class grades for course_id: $courseName. ".$assignment_and_grade_service->{error};
        $job->debug($error_msg);
        $job->failed($error_msg);
    } else {
        $job->debug("Job: " . $job->jobid . ". Successfully sent LTI Assignment and Grades for course_id: $courseName");
            $job->completed();
        }
}

1;
