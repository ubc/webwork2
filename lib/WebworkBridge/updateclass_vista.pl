#!/usr/bin/env perl

BEGIN {
	# hide arguments (there could be passwords there!)
	$0 = "$0";
}

use strict;
use warnings;

BEGIN {
	die "WEBWORK_ROOT not found in environment.\n"
		unless exists $ENV{WEBWORK_ROOT};

  die "PG_ROOT not found in environment.\n"
    unless exists $ENV{PG_ROOT};
}

use lib "$ENV{WEBWORK_ROOT}/lib";
use lib "$ENV{PG_ROOT}/lib";
use WeBWorK::CourseEnvironment;
use WeBWorK::DB;
use WeBWorK::Utils qw(runtime_use readFile cryptPassword);

use WebworkBridge::Importer::Error;
use WebworkBridge::Importer::CourseUpdater;
use WebworkBridge::Importer::CourseCreator;
use WebworkBridge::Bridge;
use WebworkBridge::Bridges::VistaParser;
use Test::MockObject;

if (scalar(@ARGV) != 3) 
{
  print "\nSyntax is: updateclass UserID LCID Course";
  print "\n    (e.g.  updateclass c01234567 23152160021 Math100-100\n\n";
  exit();
}

my $user = shift;
my $courseid = shift;
my $course = shift;

# bring up a minimal course environment
my $ce = WeBWorK::CourseEnvironment->new({
	webwork_dir => $ENV{WEBWORK_ROOT},
	courseName => $course
});

unless (-e $ce->{courseDirs}->{root})
{ # required to prevent runVistaImport from creating new courses
	die "Course '$course' does not exist!";
}

my $jar = $ce->{bridge}{vista_importer};
my $cmd = "java -jar $jar $user $courseid";
my $data = "";
my $ret = WebworkBridge::Importer::CourseCreator::customExec($cmd, \$data);
if ($ret)
{
	die "Failed to run importer: $ret";
}

my $r = Test::MockObject->new();
$r->mock( ce => sub { return $ce; } );
my %course = ();
my @students = ();
my $parser = WebworkBridge::Bridges::VistaParser->new($r, \%course, \@students);
$ret = $parser->parse($data);
if ($ret)
{
	die "Parsing of Vista import failed: $ret";
}

$course{'name'} = $course;

my $updater = WebworkBridge::Bridge->new($r);
$ret = $updater->updateCourse(\%course, \@students);
if ($ret)
{
	die "Update Course failed: $ret";
}

