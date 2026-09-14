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

	# TheSchwartz::Job freezes a reference argument with Storable and thaws it back on read, so a job enqueued with a
	# hashref argument arrives here as a hashref, the way the other DelayedJob classes already pass theirs. Jobs
	# enqueued as a JSON string are still accepted so that the producer can move to a hashref in a later release
	# without dropping whatever is already queued while both versions are running.
	my $args = ref($job->arg) eq 'HASH' ? $job->arg : decode_json($job->arg);

	my $courseName = $args->{courseName};
	$job->debug("Job: " . $job->jobid . ". Sending Caliper events for course_id: $courseName");

	my $ce = WeBWorK::CourseEnvironment->new({
		webwork_dir => $ENV{WEBWORK_ROOT},
		courseName  => $courseName,
	});
	# A hashref argument carries the events directly. In the JSON form the payload is a nested JSON string that
	# Caliper::Sensor encoded with JSON::PP->new->canonical->encode, so it is a character string by the time the
	# decode above has run; decode_json expects UTF-8 bytes and dies on any non-ASCII character in it, in practice the
	# U+00A0 that rendered problem HTML is full of. Decode that with the character oriented decoder instead.
	my $array_of_events =
		ref($args->{events}) eq 'ARRAY' ? $args->{events} : JSON->new->decode($args->{json_array_of_events});

	my $caliper_sensor = Caliper::Sensor->new($ce);
	$caliper_sensor->_sendEvents($ce, $array_of_events);
	$job->completed();
	$job->debug("Job: " . $job->jobid . ". Successfully sent Caliper events for course_id: $courseName");
}

1;
