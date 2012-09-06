#!/usr/bin/env perl

use strict;
use warnings;

BEGIN
{
	$ENV{WEBWORK_ROOT} = "/home/john/webwork/ubc_dev/webwork2"
		unless exists $ENV{WEBWORK_ROOT};
	die "WEBWORK_ROOT not found in environment.\n"
		unless exists $ENV{WEBWORK_ROOT};
}

use lib "$ENV{WEBWORK_ROOT}/lib";
use WeBWorK::CourseEnvironment;

# bring up a minimal course environment
my $ce = WeBWorK::CourseEnvironment->new({
	webwork_dir => $ENV{WEBWORK_ROOT},
});

# Vista Update
my $loginlistdir = $ce->{bridge}{vista_loginlist};
open FILE, $loginlistdir or die "Cannot open Vista loginlist file! $!\n";

my @lines = <FILE>;
foreach (@lines)
{
	my @line = split(/\t/, $_);
	
	if (scalar @line != 5)
	{
		print "Warning, line with unexpected format, skipping '$_' \n";
		next;
	}

	my $userid = $line[0];
	my $lcid = $line[1];
	my $course = $line[2];

	my $cmd = $ENV{WEBWORK_ROOT} . "/lib/WebworkBridge/updateclass_vista.pl $userid $lcid $course";
	my $ret = `$cmd\n`;
	if ($?)
	{
		die "Autoupdate failed for $course.\n";
	}
	print "Autoupdate for $course done!\n";
}

# LTI Update

$loginlistdir = $ce->{bridge}{lti_loginlist};
open FILE, $loginlistdir or die "Cannot open LTI loginlist file! $!\n";

@lines = <FILE>;
foreach (@lines)
{
	my @line = split(/\t/, $_);
	 
	if (scalar @line != 7)
	{
		print "Warning, line with unexpected format, skipping '$_' \n";
		next;
	}

	my $user = $line[0];
	my $courseName = $line[1];
	my $courseID = $line[2];
	my $courseURL = $line[3];
	my $key = $line[4];

	my $cmd = $ENV{WEBWORK_ROOT} . "/lib/WebworkBridge/updateclass_lti.pl $user $courseName $courseID $courseURL $key";
	my $ret = `$cmd\n`;
	if ($?)
	{
		die "Autoupdate failed for $courseName.\n";
	}
	print "Autoupdate for $courseName done!\n";
}

close FILE;
