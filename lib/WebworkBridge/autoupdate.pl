#!/usr/bin/env perl

=head1 NAME

autoupdate - Will try to update all known courses from classlist/loginlist files

=head1 SYNOPSIS

autoupdate [options]

 Options:
   -check	Only check to see if LTI roster requests are successful.
   -grade	Try to send grades to the LMS.

=head1 OPTIONS

=over 8

=item B<-check>

LTI auto-updates are regular HTTP requests, there is no way
to know if it failed since the response we get back is just the Webwork
page. So we have this separate param to call another script that checks
if the LTI roster requests are actually successful. 

=item B<-grade>

Enables additional parameters in the LTI launch request that tells
Webwork to try sending grades to the LMS.

=back

=cut

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
use Getopt::Long;
use Pod::Usage;

# check params
my $check = '';

# if set to true, will try to send grades to the LMS
my $grade = '';

my $man = 0;
my $help = 0;

GetOptions (
	"check" => \$check,
	"grade" => \$grade,
	'help|?' => \$help,
	man => \$man
); 

pod2usage(1) if $help;

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

	my $cmd;

	if ($grade)
	{
		$grade = "true";
	}

	if ($check)
	{
		$cmd = $ENV{WEBWORK_ROOT} . "/lib/WebworkBridge/checkclass_lti.pl $user $courseName $courseID $courseURL $key";
	}
	else
	{
		$cmd = $ENV{WEBWORK_ROOT} . "/lib/WebworkBridge/updateclass_lti.pl $user $courseName $courseID $courseURL $key $grade";
	}
	my $ret = `$cmd\n`;
	if ($?)
	{
		die "Autoupdate failed for $courseName.\n";
	}
	print "Autoupdate for $courseName successful!\n";
}

close FILE;
