package WebworkBridge::Bridge;

##### Library Imports #####
use strict;
use warnings;
use WeBWorK::CourseEnvironment;
use WeBWorK::DB;
use WeBWorK::Debug;

use WebworkBridge::Importer::Error;
use WebworkBridge::Importer::CourseCreator;
use WebworkBridge::Importer::CourseUpdater;

# Constructor
sub new
{
	my ($class, $r) = @_;
	my $self = {
		r => $r,
		useAuthenModule => 0,
		setId => 0,
		useRedirect => 0,
		redirect => ""
	};
	bless $self, $class;
	return $self;
}

sub accept
{
	my $self = shift;
	return 0;
}

sub run
{
	my $self = shift;
	die "Not implemented";
}

# Returns whether this module requires the use of a custom authen module
sub useAuthenModule
{
	my $self = shift;
	return $self->{useAuthenModule};
}

sub getErrorDisplayModule
{
	my $self = shift;
	return "WeBWorK::ContentGenerator::WebworkBridgeStatus";
}

sub getAuthenModule
{
	my $self = shift;
	die "Not implemented";
}

sub getSetId
{
	my $self = shift;
	return $self->{setId};
}

sub createCourse
{
	my ($self, $courseID, $courseTitle) = @_;
	my $r = $self->{r};
	my $ce = $r->ce;
	my $db = $r->db;

	my $creator = WebworkBridge::Importer::CourseCreator->new($ce, $db, $courseID, $courseTitle);
	my $ret = $creator->createCourse();
	if ($ret)
	{
		return error("Failed to create course: $ret", "#e004");
	}

	return 0;
}

sub updateCourse
{
	my ($self, $ce, $db, $users) = @_;

	my $creator = WebworkBridge::Importer::CourseUpdater->new($ce, $db, $users);
	my $ret = $creator->updateCourse();
	if ($ret)
	{
		return error("Failed to update course: $ret", "#e004");
	}

	return 0;
}

sub useRedirect
{
	my $self = shift;
	return $self->{useRedirect};
}

sub getRedirect
{
	my $self = shift;
	return $self->{redirect};
}

1;
