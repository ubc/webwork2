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
	eval "use WeBWorK::DB"; die $@ if $@;
}

if (scalar(@ARGV) < 1)
{
	print "Parameter count incorrect, please enter all parameters:";
	print "\nupdateclass UserID CourseName CourseID CourseURL Key\n";
	print "\nGrades (Optional) - If given, will try to send grades to LMS.\n";
	print "\ne.g.: updateclass Math100-100\n";
	exit();
}

my $courseName = shift;
my $grade = shift;

# bring up a course environment
my $ce = WeBWorK::CourseEnvironment->new({
	webwork_dir => $ENV{WEBWORK_ROOT},
	courseName => $courseName
});
my $db = new WeBWorK::DB($ce->{dbLayout});

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

my $user_identifier = $db->getSettingValue('user_identifier');
my $ext_ims_lis_memberships_id = $db->getSettingValue('ext_ims_lis_memberships_id');
my $ext_ims_lis_memberships_url = $db->getSettingValue('ext_ims_lis_memberships_url');
my $oauth_consumer_key = $db->getSettingValue('oauth_consumer_key');
my $ext_ims_lis_basic_outcome_url = $db->getSettingValue('ext_ims_lis_basic_outcome_url');

my %gradeParams;
if (defined($grade))
{
	$gradeParams{'ext_ims_lis_resultvalue_sourcedids'} = 'decimal';
	$gradeParams{'custom_gradesync'} = '1';
}

my $request = Net::OAuth->request("request token")->new(
	consumer_key => $oauth_consumer_key,
	consumer_secret => $ce->{bridge}{$oauth_consumer_key},
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
		$ce->{bridge}{user_identifier_field} => $user_identifier , # store
		# extension params
		ext_ims_lis_basic_outcome_url => $ext_ims_lis_basic_outcome_url,
		ext_ims_lis_memberships_id => $ext_ims_lis_memberships_id,# store
		ext_ims_lis_memberships_url => $ext_ims_lis_memberships_url, # store
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

