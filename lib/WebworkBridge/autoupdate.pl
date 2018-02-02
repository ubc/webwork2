#!/usr/bin/env perl

=head1 NAME

autoupdate - Will try to update all courses with lti_automatic_updates flag in course settings

=head1 SYNOPSIS

autoupdate [options]

 Options:
   -check       Only check to see if LTI roster requests are successful.
   -grade       Try to send grades to the LMS.
   -request_url Force using provided url when sending request to server

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

=item B<-request_url=s>

Force using url when sending request to server for class membership and grade updates.
Overrides url used by server_root_url

=back

=cut

use strict;
use warnings;

BEGIN
{
	die "WEBWORK_ROOT not found in environment.\n"
		unless exists $ENV{WEBWORK_ROOT};
}

use lib "$ENV{WEBWORK_ROOT}/lib";
use WeBWorK::CourseEnvironment;
use Getopt::Long;
use Pod::Usage;
use WeBWorK::DB;

# check params
my $check = '';

# if set to true, will try to send grades to the LMS
my $grade = '';

# force request url to use url (overrides server_root_url)
my $request_url = '';

my $man = 0;
my $help = 0;

GetOptions (
	"check" => \$check,
	"grade" => \$grade,
	"request_url" => \$request_url,
	'help|?' => \$help,
	man => \$man
);

pod2usage(1) if $help;

# bring up a minimal course environment
my $ce = WeBWorK::CourseEnvironment->new({
	webwork_dir => $ENV{WEBWORK_ROOT},
});
my $db = new WeBWorK::DB($ce->{dbLayout});

# LTI Update

my @ltiContexts = $db->getAllLTIContextsByAutomaticUpdates(1);

foreach my $ltiContext (@ltiContexts) {
	my $cmd;

	my $oauth_consumer_key = $ltiContext->oauth_consumer_key();
	my $context_id = $ltiContext->context_id();
	my $courseName = $ltiContext->course_id();

	if ($grade)
	{
		$grade = "true";
	}

	if ($check)
	{
		$cmd = $ENV{WEBWORK_ROOT} . "/lib/WebworkBridge/checkclass_lti.pl '$courseName' '$oauth_consumer_key' '$context_id'";
	}
	else
	{
		$cmd = $ENV{WEBWORK_ROOT} . "/lib/WebworkBridge/updateclass_lti.pl '$courseName' '$oauth_consumer_key' '$context_id' '$grade' '$request_url'";
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
}
