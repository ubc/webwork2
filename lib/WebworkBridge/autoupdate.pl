#!/usr/bin/env perl

=head1 NAME

autoupdate - Will try to update all courses with lti_automatic_updates flag in course settings

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
use WeBWorK::Utils qw(readDirectory);
use WeBWorK::DB;

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

# LTI Update

# get course list
my $coursesDir = $ce->{webworkDirs}->{courses};
my @courses = grep { not (m/^\./ or m/^CVS$/) and -d "$coursesDir/$_" } readDirectory($coursesDir);

foreach my $courseName (@courses) {
	# bring up the full course environment
	my $ce2 = new WeBWorK::CourseEnvironment({
		webwork_dir => $ENV{WEBWORK_ROOT},
		courseName => $courseName,
	});
	my $db = new WeBWorK::DB($ce2->{dbLayout});

	my $lti_automatic_updates = $db->getSettingValue('lti_automatic_updates');
	if ($lti_automatic_updates) {
		my $cmd;

		if ($grade)
		{
			$grade = "true";
		}

		if ($check)
		{
			$cmd = $ENV{WEBWORK_ROOT} . "/lib/WebworkBridge/checkclass_lti.pl $courseName";
		}
		else
		{
			$cmd = $ENV{WEBWORK_ROOT} . "/lib/WebworkBridge/updateclass_lti.pl $courseName $grade";
		}

		my $ret = `$cmd\n`;
		if ($?)
		{
			print "Autoupdate failed for $courseName.\n";
		}
		else
		{
			print "Autoupdate for $courseName successful!\n";
		}
	} else {
		print "Autoupdate for $courseName disabled. Skipping!\n";
	}
}
