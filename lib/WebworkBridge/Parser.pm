package WebworkBridge::Parser;

##### Library Imports #####
use strict;
use warnings;

use WeBWorK::Debug;

use WebworkBridge::Importer::Error;

# Constructor
sub new
{
	my ($class, $r, $course_ref, $users_ref) = @_;

	my $self = {
		r => $r,
		course => $course_ref,
		users => $users_ref
	};

	bless $self, $class;
	return $self;
}

sub parse
{
	my ($self, $param) = @_;
	die "Not implemented";
}

sub parseUser
{
	my ($self, $param) = @_;
	die "Not implemented";
}

sub parseCourse
{
	my ($self, $param) = @_;
	die "Not implemented";
}

sub getCourseName
{
	my $self = shift;
	my $r = $self->{r};
	my $ce = $r->ce;

	my $course_title;
	# Allow sites to customize the user
	if (defined($ce->{bridge}{custom_course_title_parser})) {
		$course_title = $ce->{bridge}{custom_course_title_parser}($r);
	} else {
		# default to context_id if custom_course_title_parser is not defined
		$course_title = $r->param("context_id");
	}

	$course_title = sanitizeCourseName($course_title);
	debug("Course name is: $course_title");
	return $course_title;
}

sub sanitizeCourseName
{
	my $course = shift;
	# replace spaces with underscores cause the addcourse script can't handle
	# spaces in course names and we want to keep the course name readable
	$course =~ s/ /_/g;
	$course =~ s/\./_/g;
	$course =~ s/[^a-zA-Z0-9_-]//g;
	$course = substr($course,0,40); # needs to fit mysql table name limits
	# max length of a mysql table name is 64 chars, however, webworks stick
	# additional characters after the course name, so, to be safe, we'll
	# have an error margin of 24 chars (currently the longest webwork table addition is 24 characters long).
	return $course;
}

1;
