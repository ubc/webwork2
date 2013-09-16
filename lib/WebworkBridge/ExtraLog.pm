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

# Constructor
sub new 
{
	my ($class, $r) = @_;
	my $self = {
		r => $r
	};
	bless $self, $class;
	return $self;
}

sub logXML
{
	my ($self, $xml) = @_;
	my ($sec, $msec) = gettimeofday;
	my $date = time2str("%a %b %d %H:%M:%S.$msec %Y", $sec);

	my $msg = "[$date] $xml\n";

	my $logfile = $self->{r}->ce->{webworkDirs}{logs} . "/lti_xml.log";
	if (open my $f, ">>", $logfile)
	{
		print $f $msg;
		close $f;
	}
	else
	{
		debug("Error, unable to open lti xml log file '$logfile' in append mode: $!");
	}
}

1;

