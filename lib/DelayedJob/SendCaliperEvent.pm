package DelayedJob::SendCaliperEvent;
use base qw( DelayedJob::Worker );

##### Library Imports #####
use strict;
use warnings;
use WeBWorK::CourseEnvironment;
use WeBWorK::DB;
use WeBWorK::Debug;
use Data::Dumper;
use TheSchwartz::Job;
use Caliper::Sensor;
use JSON;

sub work {
    my $class = shift;
    my TheSchwartz::Job $job = shift;
    my $args = $job->arg;

    my $courseName = $args->{courseName};
    my $ce = WeBWorK::CourseEnvironment->new({
            webwork_dir => $ENV{WEBWORK_ROOT},
            courseName => $courseName,
        });
    my $json_array_of_events = $args->{json_array_of_events};
    my $array_of_events = JSON->new->decode($json_array_of_events);

    $job->debug("Job: " . $job->jobid . ". "Sending Caliper events for course_id: $courseName");
        my $caliper_sensor = Caliper::Sensor->new($ce);
        $caliper_sensor->_sendEvents($array_of_events);
        $job->completed();
        $job->debug("Job: " . $job->jobid . ". Successfully sent Caliper events for course_id: $courseName");
}

1;
