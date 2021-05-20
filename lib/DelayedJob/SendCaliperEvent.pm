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

sub work {
    my $class = shift;
    my TheSchwartz::Job $job = shift;
	my $args = $job->arg;

	my $courseName = $args->{courseName};
	my $ce = WeBWorK::CourseEnvironment->new({
		webwork_dir => $ENV{WEBWORK_ROOT},
		courseName => $courseName,
	});
	my $array_of_events = $args->{array_of_events};

	print "Sending Caliper events for course_id: $courseName\n";
	my $caliper_sensor = Caliper::Sensor->new($ce);
	$caliper_sensor->_sendEvents($array_of_events);
	$job->completed();
	print "Successfully sent Caliper events for course_id: $courseName\n";
}

1;
