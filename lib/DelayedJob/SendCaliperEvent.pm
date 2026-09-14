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
	my $class                = shift;
	my TheSchwartz::Job $job = shift;
	my $args                 = decode_json($job->arg);

	my $courseName = $args->{courseName};
	$job->debug("Job: " . $job->jobid . ". Sending Caliper events for course_id: $courseName");

	my $ce = WeBWorK::CourseEnvironment->new({
		webwork_dir => $ENV{WEBWORK_ROOT},
		courseName  => $courseName,
	});
	# Caliper::Sensor encodes this inner payload with JSON::PP->new->canonical->encode, which returns a character
	# string, and the decode_json above has already turned the job argument back into characters. decode_json expects
	# UTF-8 bytes, so using it here dies on any non-ASCII character in the payload -- in practice the U+00A0 that
	# rendered problem HTML is full of. Decode with the character oriented decoder that matches the encoder.
	my $array_of_events = JSON->new->decode($args->{json_array_of_events});

	my $caliper_sensor = Caliper::Sensor->new($ce);
	$caliper_sensor->_sendEvents($ce, $array_of_events);
	$job->completed();
	$job->debug("Job: " . $job->jobid . ". Successfully sent Caliper events for course_id: $courseName");
}

1;
