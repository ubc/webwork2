#!/usr/bin/env perl

BEGIN {
	# hide arguments (there could be passwords there!)
	$0 = "$0";
}

use strict;
use warnings;

use Net::OAuth;
use HTTP::Request::Common;
use LWP::UserAgent;
use URI::Escape;

BEGIN {
	die "WEBWORK_ROOT not found in environment.\n"
		unless exists $ENV{WEBWORK_ROOT};
	my $webwork_dir = $ENV{WEBWORK_ROOT};

	$WeBWorK::Constants::WEBWORK_DIRECTORY = $ENV{WEBWORK_ROOT};
	# link to WeBWorK code libraries
	eval "use lib '$webwork_dir/lib'"; die $@ if $@;
	eval "use WeBWorK::CourseEnvironment"; die $@ if $@;
}

if (scalar(@ARGV) < 5)
{
	print "Parameter count incorrect, please enter all parameters:";
	print "\nupdateclass UserID CourseName CourseID CourseURL Key\n";
	print "\nUserID - The instructor's user id in Webwork.";
	print "\nCourseName - The name of the course in Webwork.";
	print "\nCourseID - The course's ID in the site we're updating from.";
	print "\nCourseURL - The url we submit LTI membership requests to.";
	print "\nKey - The consumer key to use for calculation LTI OAuth hash.\n";
	print "\nGrades (Optional) - If given, will try to send grades to LMS.\n";
	print "\ne.g.: updateclass A1B2C3D4 Math100-100 _100_1 https://lms.ubc.ca/lti/membership LTISecret\n";
	exit();
}

my $user = shift;
my $courseName = shift;
my $courseID = shift;
my $courseURL = shift;
my $key = shift;
my $grade = shift;

# bring up a minimal course environment
my $ce = WeBWorK::CourseEnvironment->new({
	webwork_dir => $ENV{WEBWORK_ROOT},
	courseName => $courseName
});

unless (-e $ce->{courseDirs}->{root})
{ # required to prevent updater from creating new courses
	die "Course '$courseName' does not exist!";
}

# need to make sure request_urls are terminated with /
my $request_url = $ce->{server_root_url} . $ce->{webwork_url};
if (substr($request_url, -1, 1) ne "/")
{
	$request_url .= "/";
}

my %gradeParams;
if (defined($grade))
{
	$gradeParams{'ext_ims_lis_basic_outcome_url'} = $courseURL;
	$gradeParams{'ext_ims_lis_resultvalue_sourcedids'} = "ratio";
}

my $request = Net::OAuth->request("request token")->new(
	consumer_key => $key,
	consumer_secret => $ce->{bridge}{$key},
	protocol_version => Net::OAuth::PROTOCOL_VERSION_1_0A,
	request_url => $request_url,
	request_method => 'POST',
	signature_method => 'HMAC-SHA1',
	timestamp => time(),
	nonce => rand(),
	callback => 'about:blank',
	extra_params => {
		# required LTI params
		lti_version => 'LTI-1p0',
		lti_message_type => 'basic-lti-launch-request',
		resource_link_id => $courseName,# store
		# other params
		context_title => $courseName,# same as resource_link_id
		roles => 'instructor', # need, but can hard code
		# lis stuff
		lis_person_sourcedid => $user, # store
		# extension params
		ext_ims_lis_memberships_id => $courseID,# store
		ext_ims_lis_memberships_url => $courseURL, # store
        ubc_auto_update => 'true',
        roles => 'AutoUpdater',
		%gradeParams
	}
);
$request->sign;

my $ua = LWP::UserAgent->new;
push @{ $ua->requests_redirectable }, 'POST';

my $res = $ua->post($request_url . $courseName . "/", $request->to_hash);
if ($res->is_success)
{
	if ($res->content =~ /Invalid user ID or password/)
	{
		die "Course update failed, unable to authenticate.";
	}
}
else
{
    die "Course update failed, POST request failed." . $res->status_line;
}

