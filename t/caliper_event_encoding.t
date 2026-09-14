#!/usr/bin/env perl

# Caliper events reach the job queue as JSON nested inside JSON:
#
#   Caliper::Sensor        encodes the event array   -> character string
#   DelayedJob::Service    wraps it in the job arg   -> UTF-8 bytes
#   DelayedJob::SendCaliperEvent  unwraps both       -> event array
#
# Decoding the inner payload with decode_json (which expects UTF-8 bytes) died on
# every event batch containing a non-ASCII character, dropping those Caliper
# events. This locks the contract between the three.

use strict;
use warnings;

use Test::More;
use FindBin;
use JSON::PP ();
use Storable ();

# Exercise whichever decoders are installed. The worker says "use JSON", which
# resolves to JSON::XS or JSON::PP depending on the image; the character oriented
# decode works the same on both.
my @backends = ('JSON::PP');
push(@backends, 'JSON') if eval { require JSON; 1 };

# U+00A0 (non breaking space) is what rendered problem HTML actually contains.
my $events = [ { id => 'urn:uuid:one', body => "Consider\x{a0}the table" } ];
my $ascii  = [ { id => 'urn:uuid:two', body => 'Consider the table' } ];

# Caliper::Sensor followed by DelayedJob::Service, verbatim.
sub job_argument_for {
	my ($array_of_events) = @_;
	my $json_array_of_events = JSON::PP->new->canonical->encode($array_of_events);
	return JSON::PP::encode_json({
		courseName           => 'MATH_V_100_2026W1',
		json_array_of_events => $json_array_of_events
	});
}

for my $backend (@backends) {
	my $decode_json = $backend->can('decode_json');

	# DelayedJob::SendCaliperEvent, first decode.
	my $args = $decode_json->(job_argument_for($events));
	is($args->{courseName}, 'MATH_V_100_2026W1', "$backend: job argument decodes");

	# DelayedJob::SendCaliperEvent, second decode.
	my $decoded = eval { $backend->new->decode($args->{json_array_of_events}) };
	is($@, '', "$backend: inner payload with non-ASCII decodes");
	is_deeply($decoded, $events, "$backend: non-ASCII event survives the round trip");

	# Guard against reintroducing the bug.
	ok(
		!eval { $decode_json->($args->{json_array_of_events}); 1 },
		"$backend: decode_json rejects the already decoded payload"
	);
	like($@, qr/malformed UTF-8/, "$backend: and fails the way production did");

	# ASCII only payloads decoded either way, which is why this went unnoticed.
	my $plain = $decode_json->(job_argument_for($ascii));
	is_deeply($backend->new->decode($plain->{json_array_of_events}),
		$ascii, "$backend: ASCII event survives the round trip");
}

# The producer is moving to passing a plain hashref, which TheSchwartz::Job freezes with Storable into the MEDIUMBLOB
# arg column and thaws back on read. Wide characters have to survive that for the JSON layer to be safe to drop; the
# three job classes that already pass hashrefs only carry ASCII, so they do not prove it on their own.
my $thawed = Storable::thaw(Storable::nfreeze({ courseName => 'MATH_V_100_2026W1', events => $events }));
is(ref $thawed->{events}, 'ARRAY', 'Storable round trip returns the events as an array reference');
is_deeply($thawed->{events}, $events, 'Storable round trip keeps the non-ASCII payload intact');
is($thawed->{events}[0]{body}, "Consider\x{a0}the table", 'the non breaking space survives as one character');

# The module itself cannot be loaded here: it pulls in WeBWorK::CourseEnvironment,
# WeBWorK::DB and TheSchwartz, none of which exist outside the built image. Check
# the call site directly instead so that going back to decode_json fails the build.
my $worker = "$FindBin::Bin/../lib/DelayedJob/SendCaliperEvent.pm";
open(my $fh, '<', $worker) or die "Cannot read $worker: $!";
my $source = do { local $/; <$fh> };
close($fh);

like(
	$source,
	qr/JSON->new->decode\(\$args->\{json_array_of_events\}\)/,
	'worker decodes the nested payload as a character string'
);
unlike(
	$source,
	qr/decode_json\(\$args->\{json_array_of_events\}\)/,
	'worker does not decode the nested payload as UTF-8 bytes'
);
like($source, qr/ref\(\$job->arg\) eq 'HASH'/,          'worker accepts a hashref job argument');
like($source, qr/ref\(\$args->\{events\}\) eq 'ARRAY'/, 'worker accepts events passed as an array reference');
like($source, qr/json_array_of_events/,                 'worker still accepts the JSON form while old jobs are queued');

done_testing;
