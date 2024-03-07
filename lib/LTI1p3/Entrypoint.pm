package LTI1p3::Entrypoint;

use Mojo::Base 'WeBWorK::Controller', -strict, -signatures, -async_await;

##### Library Imports #####
use WeBWorK::CourseEnvironment;
use WeBWorK::DB;
use WeBWorK::Debug;

use LTI1p3::Importer::Error;
use LTI1p3::Importer::CourseCreator;
use LTI1p3::Importer::CourseUpdater;

sub getSetId
{
	my $self = shift;
	return $self->{setId};
}

sub createCourse
{
	my ($self, $courseID, $courseTitle) = @_;
	my $c = $self->{c};
	my $ce = $c->ce;
	my $db = $c->db;

	my $creator = LTI1p3::Importer::CourseCreator->new($ce, $db, $courseID, $courseTitle);
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

	my $creator = LTI1p3::Importer::CourseUpdater->new($ce, $db, $users);
	my $ret = $creator->updateCourse();
	if ($ret)
	{
		return error("Failed to update course: $ret", "#e004");
	}

	return 0;
}

1;
