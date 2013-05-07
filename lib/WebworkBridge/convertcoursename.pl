#!/usr/bin/env perl

use strict;
use warnings;

# import webwork libs
BEGIN {
	die "WEBWORK_ROOT not found in environment.\n"
		unless exists $ENV{WEBWORK_ROOT};
	my $webwork_dir = $ENV{WEBWORK_ROOT};

	$WeBWorK::Constants::WEBWORK_DIRECTORY = $ENV{WEBWORK_ROOT};
	# link to WeBWorK code libraries
	eval "use lib '$webwork_dir/lib'"; die $@ if $@;
	eval "use WeBWorK::CourseEnvironment"; die $@ if $@;
}

# import parser now that perl knows to search modules from webwork lib dir
use WebworkBridge::Parser;

if (scalar(@ARGV) != 1)
{
	print "convertcoursename [course name]\n\n";
	print "Converts the Connect course name into one suitable for Webwork.\n";
	print "This script runs through the same code that is used in course\n";
	print "import.\n\n";
	exit;
}

my $name = shift;

# initialize parser with dummy params cause we don't need them to call
# the course name parser
my $parser = WebworkBridge::Parser->new(1,1,1);
$name = $parser->_parseConnectCourse($name);

if ($name)
{
	$name = WebworkBridge::Parser::sanitizeCourseName($name);

	print $name . "\n";
}
else
{
	print "Course name not recognized as a Connect course name.\n";
	exit 1;
}

