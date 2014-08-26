package WebworkBridge::Parser;

##### Library Imports #####
use strict;
use warnings;

use WeBWorK::Debug;

use WebworkBridge::Importer::Error;

# Constructor
sub new
{
	my ($class, $r, $course_ref, $students_ref) = @_;

	my $self = {
		r => $r,
		course => $course_ref,
		students => $students_ref
	};

	bless $self, $class;
	return $self;
}

sub parse
{
	my ($self, $param) = @_;
	die "Not implemented";
}

sub parseStudent
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
	my ($self, $course, $section) = @_;
	my $r = $self->{r};
	my $ce = $r->ce;

	# Read configuration to see if there are any custom mappings we should use.
	# Course name mapping has two levels, start from highest priority.
	# 1. course mapping rules
	# 2. using the name as it is
	for my $href (@{$ce->{bridge}{course_mapping_rules}})
	{
		for my $key ( keys %$href )
		{
			my $regex = qr/$key/;
			my $need_eval = ($href->{$key} =~ /\$/);
			if ($course =~ $regex)
			{
				# get the actual value of mapping if we don't need to eval it
				my $cname = ($need_eval) ? eval($href->{$key}) : $href->{$key};
				my $ret = sanitizeCourseName($cname);
				debug("Using mapping '$key' for course '$course' to '$ret'");
				return $ret;
			}
		}
	}

	my $ret = $course; # If nothing matches, fall back to using the course as is

	# Try to parse course name in the Connect format
	my $res = $self->_parseConnectCourse($course);
	if ($res)
	{
		$ret = $res;
	}

	$ret = sanitizeCourseName($ret);
	debug("Course name is: $ret");
	return $ret;
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
	# have an error margin of 24 chars.
	return $course;
}

# Create course names from the course name in Connect
# 
# Note that we need to save space in the course id. The course id is used
# as a prefix for webwork to create MySQL tables. There's a limit to the
# length of table names. So we'll disregard title and instructor.
# 
# There's a weakness in this implementation where if there's a typo
# in one of the course name that makes it unrecognizable as a course, e.g.:
# 'CPS100' instead of 'CPSC100', we'll still accept the whole string
# as long as there was at least one course before it that was validly 
# formatted.
#
# We expect the courses to be in the format: Term-Course-Section,
# with the Course-Section part being repeatable if it's a crosslisted course:
# E.g.: Term-Course1-Section1-Course2-Section2
# Section can be composed of section numbers, e.g.: 100
# Section can have multiple section numbers, e.g.: 100, 101a, 102b, etc.
# Section can also start with a character, e.g.: V01
#
# There is one exception to - delimiting in that a course which spans
# 2 terms will have the terms delimited by a - too, e.g.: 2012W1-2
sub _parseConnectCourse
{
	my ($self, $input) = @_;
	my @parts = split('-', $input);
	debug("Connect course name parsing start with: $input");

	# Assuming that there are at least 4 parts in all course names.
	# Note that there might be an optional Instructors part. This is only
	# sometimes present and might have more than 1 instructor.
	# Term-Course-Section-Title
	if (@parts < 4) 
	{
		debug("Unrecognized course format.");
		return 0;
	}

	# Parse Term
	my $term = shift(@parts);
	# special case handling for courses that span 2 terms, e.g.: 2012W1-2
	if ($parts[0] =~ /^\d$/)
	{
		$term .= shift(@parts);
	}

	# Parser Course & Section
	my @courses = ();
	my @sections = ();

	while (scalar @parts > 0)
	{
		my $next = shift(@parts);
		if ($next =~ /^[A-Za-z]{4}\d+/) 
		{ # matches the course format
			# Fix case when there's a slash in the course name, e.g.:
			# MATH101/103
			# Which indicates that both Math101 and Math103 uses this course.
			$next =~ s/\//-/g;

			push(@courses, $next);
			my $section = shift(@parts); # course is always followed by section
			if ($section =~ /^all/i)
			{
				$section = 'ALL';
			}
			elsif ($section !~ /^\d\d\d/ and $section !~ /^[A-Z]\d\d/)
			{ # section isn't in the expected format, bail
				last;
			}
			push(@sections, $section);
		}
	}

	# Find out if parsing encountered any difficulties
	if (!@courses) 
	{
		debug("No courses found.");
		return 0;
	}
	elsif (!@sections)
	{
		debug("No sections found.");
		return 0;
	}
	elsif (@courses != @sections)
	{
		debug("Mismatched course and sections.");
		return 0;
	}

	# Create the final course name string
	my $ret = "";
	for (my $i = 0; $i < @courses; $i++)
	{ # pair up section and course
		$sections[$i] =~ s/ //g;
		$sections[$i] =~ s/,/-/g;
		$ret .= $courses[$i] . "-" . $sections[$i] . "_";
	}
	$ret .= $term;
	debug("Connect course name parsing success: $ret");


	return $ret;
}

1;
