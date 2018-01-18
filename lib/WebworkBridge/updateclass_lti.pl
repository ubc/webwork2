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

if (scalar(@ARGV) < 3)
{
	print "Parameter count incorrect, please enter all parameters:";
	print "\updateclass_lti CourseName oauthConsumerKey contextId\n";
	print "\nGrades (Optional) - If given, will try to send grades to LMS.\n";
	print "\ne.g.: updateclass_lti Math100-100 consumerKey 123abc123abc\n";
	exit();
}

my $courseName = shift;
my $oauth_consumer_key = shift;
my $context_id = shift;
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

my $ltiContext = $db->getLTIContext($oauth_consumer_key, $context_id);

my $ext_ims_lis_memberships_id = $ltiContext->ext_ims_lis_memberships_id;
my $ext_ims_lis_memberships_url = $ltiContext->ext_ims_lis_memberships_url;
my $ext_ims_lis_basic_outcome_url = $ltiContext->ext_ims_lis_basic_outcome_url;
my $custom_context_memberships_url = $ltiContext->custom_context_memberships_url;

my %gradeParams;
if (defined($grade))
{
	$gradeParams{'ext_ims_lis_resultvalue_sourcedids'} = 'decimal';
	$gradeParams{'custom_gradesync'} = '1';
}

my $request = Net::OAuth->request("request token")->new(
	consumer_key => $oauth_consumer_key,
	consumer_secret => $ce->{bridge}{lti_secrets}{$oauth_consumer_key},
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
		context_id => $context_id,
		context_title => $courseName,# same as resource_link_id
		context_label => $courseName,
		# lis stuff
		$ce->{bridge}{user_identifier_fields}[0] => 'admin', # store
		# extension params
		ext_ims_lis_basic_outcome_url => $ext_ims_lis_basic_outcome_url,
		ext_ims_lis_memberships_id => $ext_ims_lis_memberships_id,# store
		ext_ims_lis_memberships_url => $ext_ims_lis_memberships_url, # store
		custom_context_memberships_url => $custom_context_memberships_url, # store
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

