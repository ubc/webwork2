package WebworkBridge::ExtraLog;

# This is additional debug logging separate from the normal debug.
# Meant for use on production where turning on the normal debug
# consumes a lot of space.

##### Library Imports #####
use strict;
use warnings;
use Time::HiRes qw/gettimeofday/;
use Date::Format;
use WeBWorK::CourseEnvironment;
use WeBWorK::Debug;

# Constructor
sub new
{
	my ($class, $ce) = @_;
	my $self = {
		ce => $ce
	};
	bless $self, $class;
	return $self;
}

sub logLTIRequest
{
	my ($self, $service_name, $text) = @_;
	my ($sec, $msec) = gettimeofday;
	my $date = time2str("%a %b %d %H:%M:%S.$msec %Y", $sec);
	my $filename_date = time2str("%Y\_%m", $sec); #time2str("%Y\_%m\_%d", $sec);

	my $msg = "[$date] $text\n";

	my $logfile = $self->{ce}->{webworkDirs}{logs} . "/lti_". $service_name . "_" . $filename_date . ".log";
	if (open my $f, ">>", $logfile) {
		print $f $msg;
		close $f;
	} else {
		debug("Error, unable to open lti request log file '$logfile' in append mode: $!");
	}

}

sub logNRPSRequest
{
	my ($self, $text) = @_;
	$self->logLTIRequest('nrps_request', $text);
}

sub logAGSRequest
{
	my ($self, $text) = @_;
	$self->logLTIRequest('ags_request', $text);
}

sub logAccessTokenRequest
{
	my ($self, $text) = @_;
	$self->logLTIRequest('access_token_request', $text);
}

1;

