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
	print "\checkclass_lti CourseName oauthConsumerKey contextId\n";
	print "\ne.g.: checkclass_lti Math100-100 consumerKey 123abc123abc\n";
	exit();
}

my $courseName = shift;
my $oauth_consumer_key = shift;
my $context_id = shift;

# bring up a course environment
my $ce = WeBWorK::CourseEnvironment->new({
	webwork_dir => $ENV{WEBWORK_ROOT},
	courseName => $courseName
});
my $db = new WeBWorK::DB($ce->{dbLayout});

my $ltiContext = $db->getLTIContext($oauth_consumer_key, $context_id);

my $ext_ims_lis_memberships_id = $ltiContext->ext_ims_lis_memberships_id();
my $ext_ims_lis_memberships_url = $ltiContext->ext_ims_lis_memberships_url();

unless (-e $ce->{courseDirs}->{root})
{ # required to prevent updater from creating new courses
	die "Course '$courseName' does not exist!";
}
if (!$ext_ims_lis_memberships_url)
{
	die "Course '$courseName' has no ext_ims_lis_memberships_url";
}
if (!$ext_ims_lis_memberships_id)
{
	die "Course '$courseName' has no ext_ims_lis_memberships_id";
}

my $request = Net::OAuth->request("request token")->new(
	consumer_key => $oauth_consumer_key,
	consumer_secret => $ce->{bridge}{lti_secrets}{$oauth_consumer_key},
	protocol_version => Net::OAuth::PROTOCOL_VERSION_1_0A,
	request_url => $ext_ims_lis_memberships_url,
	request_method => 'POST',
	signature_method => 'HMAC-SHA1',
	timestamp => time(),
	nonce => rand(),
	callback => 'about:blank',
	extra_params => {
		lti_version => 'LTI-1p0',
		lti_message_type => 'basic-lis-readmembershipsforcontext',
		id => $ext_ims_lis_memberships_id,
	}
);
$request->sign;

my $ua = LWP::UserAgent->new;
push @{ $ua->requests_redirectable }, 'POST';

my $res = $ua->post($ext_ims_lis_memberships_url, $request->to_hash);
if ($res->is_success)
{
	if ($res->content =~ /codemajor>Failure/i)
	{
		die "Course update failed, unable to authenticate.";
	}
}
else
{
	die "Course update failed, POST request failed.";
}

