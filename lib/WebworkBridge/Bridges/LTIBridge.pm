package WebworkBridge::Bridges::LTIBridge;
use base qw(WebworkBridge::Bridge);

##### Library Imports #####
use strict;
use warnings;

use Net::OAuth;
use HTTP::Request::Common;
use LWP::UserAgent;
use Data::Dumper;

use WeBWorK::CourseEnvironment;
use WeBWorK::DB;
use WeBWorK::Debug;

use WebworkBridge::Exporter::GradesExport;
use WebworkBridge::Importer::Error;
use WebworkBridge::Parser;
use WebworkBridge::Bridges::LTIParser;
use WebworkBridge::ExtraLog;

use WeBWorK::Authen::LTI;

# Constructor
sub new
{
	my ($class, $r) = @_;
	my $self = $class->SUPER::new($r);
	bless $self, $class;
	return $self;
}

sub accept
{
	my $self = shift;
	my $r = $self->{r};

	if ($r->param("lti_message_type"))
	{
		return 1;
	}

	return 0;
}

# In order to simplify, we use the Webwork root URL for all LTI actions,
# e.g.: http://137.82.12.77/webworkdev/
# Cases to handle:
# * The course does not yet exist
# ** If user is instructor, ask if want to create course
# ** If user is student, inform that course does not exist
# * The course exists
# ** SSO login

sub run
{
	my $self = shift;
	my $r = $self->{r};
	my $ce = $r->ce;
	$r->{db} = new WeBWorK::DB($ce->{dbLayout});
	my $db = $r->db;

	# check if user wants to go directly to an assignment
	my $hwset = $r->param("custom_homework_set");
	if ($hwset)
	{
		# not perfect sanitization, but need something
		$hwset = WebworkBridge::Parser::sanitizeCourseName($hwset);
		$self->{homeworkSet} = $hwset;
	}
	my $qset = $r->param("custom_quiz_set");
	if ($qset)
	{
		# not perfect sanitization, but need something
		$qset = WebworkBridge::Parser::sanitizeCourseName($qset);
		$self->{quizSet} = $qset;
	}

	my $parser = WebworkBridge::Bridges::LTIParser->new($r);
	my $oauth_consumer_key = $r->param('oauth_consumer_key');
	my $context_id = $r->param('context_id');
	my $courseID = $parser->getCourseName();

	# LTI processing
	if ($r->param("lti_message_type") && $oauth_consumer_key && $context_id && $courseID)
	{
		debug("LTI detected\n");

		# Check for course existence
		if($db->existsLTIContext($oauth_consumer_key, $context_id)) {
        	my $lti_context = $db->getLTIContext($oauth_consumer_key, $context_id);
			# over write course id with value stored in context table
			$courseID = $lti_context->course_id();
		}

		# setup tmp course ce and db
		my $tmpce = WeBWorK::CourseEnvironment->new({
			%WeBWorK::SeedCE,
			courseName => $courseID
		});

		if (-e $tmpce->{courseDirs}->{root}) {
			# course exists
			debug("We're trying to authenticate to an existing course.");
			if ($ce->{"courseName"} && $ce->{"courseName"} ne '___') {
				debug("CourseID " . $ce->{"courseName"} . " found.");

				$self->_updateLaunchUser();

				debug("Trying authentication\n");
				$self->{useAuthenModule} = 1;
				if (my $tmp = $self->_verifyMessage())
				{ # LTI OAuth verification failed
					return $tmp;
				}

				return $self->updateCourse();
			} else {
				debug("CourseID not found, trying workaround\n");
				# workaround is basically dump all our POST parameters into
				# GET and redirect to that url. This should work as long as
				# our url doesn't exceed 2000 characters.
				use URI::Escape;
				my @tmp;
				foreach my $key ($r->param)
				{
					my $val = $r->param($key);
					push(@tmp, "$key=" . uri_escape($val));
				}
				my $args = join('&', @tmp);

				# direct the student directly to a homework assignment or quiz
				# if needed
				my $redir = $r->uri . $courseID;
				if ($self->getHomeworkSet())
				{
					$redir .= "/" . $self->getHomeworkSet();
				}
				elsif ($self->getQuizSet())
				{
					$redir .= "/quiz_mode/" . $self->getQuizSet();
				}
				$redir .= "/?". $args;
				debug("Redirecting with url: $redir");
				use CGI;
				my $q = CGI->new();
				print $q->redirect($redir);
			}
		} else {
			# set request ce and db to courseID
			$r->{ce} = $tmpce;
			$r->{db} = new WeBWorK::DB($r->ce->{dbLayout});

			# course does not exist
			debug("Course does not exist, try LTI import.");
			$self->{useDisplayModule} = 1;
			if (my $tmp = $self->_verifyMessage())
			{
				return $tmp;
			}

			return $self->createCourse();
		}
	}
	else
	{
		debug("LTI detected but unable to proceed, missing parameter 'context_title'.\n");
	}

}

sub getAuthenModule
{
	my $self = shift;
	my $r = $self->{r};
	return WeBWorK::Authen::class($r->ce, "lti");
}

sub createCourse
{
	my $self = shift;
	my $r = $self->{r};
	my $ce = $r->ce;

	if (!$self->_isInstructor())
	{
		return error("Please ask your instructor to import this course into Webworks first.", "#e011");
	}

	my %course = ();
	my @users = ();

	my $ret = $self->_getAndParseRoster(\%course, \@users);
	if ($ret)
	{
		return error("Get roster failed: $ret", "#e009");
	}

	$ret = $self->SUPER::createCourse(\%course, \@users);
	if ($ret)
	{
		return error("Create course failed: $ret", "#e010");
	}

	# store LTI credentials for auto-update
	$self->updateLTISettings();

	return 0;
}

sub updateCourse
{
	my $self = shift;
	my $r = $self->{r};
	my $ce = $r->ce;

	debug("Checking to see if we can update the course.");
	# check roles to see if we can run update
	if (!defined($r->param('roles')))
	{
		return error("LTI launch missing roles, NOT updating course.", "#e025");
	}
	my @roles = split(/,/, $r->param("roles"));
	my $allowedUpdate = 0;
	foreach my $role (@roles)
	{
		if ($ce->{bridge}{roles_can_update} =~ /$role/)
		{
			debug("Role $role allowed to update course.");
			$allowedUpdate = 1;
			last;
		}
	}

	if (!$allowedUpdate)
	{
		debug("User not allowed to update course.");
		return 0;
	}

	# store LTI credentials for auto-update
	$self->updateLTISettings();

	my %course = ();
	my @users = ();

	# try to update course enrolment
	my $ret = $self->_updateCourseEnrolment(\%course, \@users);
	if ($ret)
	{ # failed to update course enrolment, stop here
		debug("Course enrolment update failed, bailing.");
		return $ret;
	}

	# try to push out grades back to the LMS
	$ret = $self->_pushGrades();

	return $ret;
}

sub updateLTISettings()
{
	my $self = shift;
	my $r = $self->{r};
	my $ce = $r->ce;
	my $db = $r->db;

	if (defined($r->param('ubc_auto_update'))) {
		# skip updating settings if automatic update
		return;
	}

	my $oauth_consumer_key = $r->param('oauth_consumer_key');
	my $context_id = $r->param('context_id');

	my $lti_context;
	my $exists = $db->existsLTIContext($oauth_consumer_key, $context_id);

	if($exists) {
        $lti_context = $db->getLTIContext($oauth_consumer_key, $context_id);
    } else {
        $lti_context = $db->newLTIContext();
		$lti_context->oauth_consumer_key($oauth_consumer_key);
		$lti_context->context_id($context_id);
		# only set course_title and automatic_updates are only set up new lti contexts
        $lti_context->course_id($ce->{"courseName"});
        $lti_context->automatic_updates(1);
	}

	$lti_context->ext_ims_lis_memberships_id($r->param('ext_ims_lis_memberships_id'));
	$lti_context->ext_ims_lis_memberships_url($r->param('ext_ims_lis_memberships_url'));
	$lti_context->ext_ims_lis_basic_outcome_url($r->param('ext_ims_lis_basic_outcome_url'));
	$lti_context->custom_context_memberships_url($r->param('custom_context_memberships_url'));

	if($exists) {
        $db->putLTIContext($lti_context);
    } else {
        $db->addLTIContext($lti_context);
	}
}

# Sync course enrolment from the lms with Webwork
sub _updateCourseEnrolment()
{
	my ($self, $course, $users) = @_;

	debug("Trying to update course enrolment.");
	my $r = $self->{r};
	unless ($r->param("ext_ims_lis_memberships_url"))
	{
		debug("Server does not allow roster retrival.\n");
		return 0;
	}

	my $ret = $self->_getAndParseRoster($course, $users);
	if ($ret)
	{
		return error("Get roster failed: $ret", "#e009");
	}

	if (@$users)
	{
		$ret = $self->SUPER::updateCourse($course, $users);
		if ($ret)
		{
			return error("Update course failed: $ret", "#e010");
		}
	}
	return 0;
}

# Push grades from Webwork to the lms
sub _pushGrades()
{
	my $self = shift;
	my $r = $self->{r};
	unless ($r->param("ext_ims_lis_basic_outcome_url"))
	{
		debug("Server does not allow outcome submissions.\n");
		return 0;
	}

	# ensure that ratio is enabled if ext_ims_lis_resultvalue_sourcedids is sent
	# if ext_ims_lis_resultvalue_sourcedids is not sent, we must assume it is enabled
	if (defined($r->param('ext_ims_lis_resultvalue_sourcedids')))
	{
		unless ($r->param('ext_ims_lis_resultvalue_sourcedids') =~ /decimal/i)
		{
			return error("Grade update failed: no decimal result support.", "#e021");
		}
	}

	if (defined($r->param('custom_gradesync')))
	{
		my $extralog = WebworkBridge::ExtraLog->new($r);
		$extralog->logXML("--- " . $r->param('context_title') . " ---");
		debug("Allowed to do mass grade syncing.");

		my $grades = WebworkBridge::Exporter::GradesExport->new($r);
		my $scores = $grades->getGrades();
		while (my ($studentID, $records) = each(%$scores))
		{
			$extralog->logXML("Grade Sync for user $studentID");
			foreach my $record (@$records)
			{
				# send all scores, even if it's 0 or the user hasn't attempted it
				my $ret = $self->_ltiUpdateGrade($record);
				if ($ret)
				{
					return error("Grade update failed: $ret", "#e020");
				}
			}
		}
	}

	return 0;
}

# Perform the actual LTI request to send a grade to the LMS
sub _ltiUpdateGrade()
{
	my ($self, $record) = @_;
	my $r = $self->{r};
	my $ce = $r->ce;

	my $key = $r->param("oauth_consumer_key");
	my $lis_source_did = $record->{lis_source_did};
	my $score = $record->{score};

	my $extralog = WebworkBridge::ExtraLog->new($r);
	$extralog->logXML("fetching score for lis_source_did $lis_source_did");

	# read current score from tool consumer
	my $read_request = Net::OAuth->request("request token")->new(
		consumer_key => $key,
		consumer_secret => $ce->{bridge}{lti_secrets}{$key},
		protocol_version => Net::OAuth::PROTOCOL_VERSION_1_0A,
		request_url => $r->param("ext_ims_lis_basic_outcome_url"),
		request_method => 'POST',
		signature_method => 'HMAC-SHA1',
		timestamp => time(),
		nonce => rand(),
		callback => 'about:blank',
		extra_params => {
			lti_version => 'LTI-1p0',
			lti_message_type => 'basic-lis-readresult',
			sourcedid => $lis_source_did,
		}
	);
	$read_request->sign;

	my $ua = LWP::UserAgent->new;
	push @{ $ua->requests_redirectable }, 'POST';

	my $read_res = $ua->post($r->param("ext_ims_lis_basic_outcome_url"), $read_request->to_hash);
	if ($read_res->is_success)
	{
		debug($read_res->content);
		if ($read_res->content =~ /codemajor>Failure/i)
		{
			$extralog->logXML("Grade read failed for $lis_source_did, unable to authenticate.");
			return "Grade read failed for $lis_source_did, unable to authenticate.";
		}
		elsif ($read_res->content =~ /codeminor>User not found/i)
		{
			$extralog->logXML("Grade read failed for $lis_source_did, can't find user.");
			return "Grade read failed for $lis_source_did, can't find user.";
		}
		elsif ($read_res->content =~ /textString>(.*)<\/textString/i) {
			if ("$score" eq $1) {
				$extralog->logXML("Current Grade ($score) matches Tool Consumer ($1). Update not neccissary.");
				debug("Grade read successful for $lis_source_did. Update not neccissary.");
				return "";
			}
			else
			{
				$extralog->logXML("Current Grade ($score) does not match Tool Consumer ($1). Update neccissary.");
				debug("Grade read successful for $lis_source_did. Update nessicary. ($1)->($score)");
				#no return, only way to continue
			}
		}
		else
		{
			$extralog->logXML("Grade read error for $lis_source_did. no grade textString returned");
			return "Grade read error for $lis_source_did. no grade textString returned";
		}
	}
	else
	{
		$extralog->logXML("Grade read failed, POST request failed. ". $read_res->message);
		return "Grade read failed, POST request failed.";
	}

	$extralog->logXML("Updating score for lis_source_did $lis_source_did to score $score");

	my $request = Net::OAuth->request("request token")->new(
		consumer_key => $key,
		consumer_secret => $ce->{bridge}{lti_secrets}{$key},
		protocol_version => Net::OAuth::PROTOCOL_VERSION_1_0A,
		request_url => $r->param("ext_ims_lis_basic_outcome_url"),
		request_method => 'POST',
		signature_method => 'HMAC-SHA1',
		timestamp => time(),
		nonce => rand(),
		callback => 'about:blank',
		extra_params => {
			lti_version => 'LTI-1p0',
			lti_message_type => 'basic-lis-updateresult',
			sourcedid => $lis_source_did,
			result_resultscore_textstring => $score,
			result_resultvaluesourcedid => 'decimal',
			# Optional parameters, may not be supported
			#result_resultscore_language => 'en_US',
			#result_statusofresult => 'final',
			#result_date => strftime("%Y-%m-%dT%H:%M:%S", gmtime(time())) . 'Z',
			#result_datasource => 'blah'
		}
	);
	$request->sign;

	my $res = $ua->post($r->param("ext_ims_lis_basic_outcome_url"), $request->to_hash);
	if ($res->is_success)
	{
		debug($res->content);
		if ($res->content =~ /codemajor>Failure/i)
		{
			$extralog->logXML("Grade update failed for $lis_source_did, unable to authenticate.");
			return "Grade update failed for $lis_source_did, unable to authenticate.";
		}
		elsif ($res->content =~ /codeminor>User not found/i)
		{
			$extralog->logXML("Grade update failed for $lis_source_did, can't find user.");
			return "Grade update failed for $lis_source_did, can't find user.";
		}
		else
		{
			$extralog->logXML("Grade update successful for $lis_source_did.");
			debug("Grade update successful for $lis_source_did.");
			return "";
		}
	}
	else
	{
		$extralog->logXML("Grade update failed, POST request failed. ". $res->message);
		return "Grade update failed, POST request failed.";
	}
}

sub _isInstructor
{
	my $self = shift;
	my $r = $self->{r};

	if ($r->param('roles') =~ /instructor/i ||
		$r->param('roles') =~ /contentdeveloper/i)
	{
		return 1;
	}
	return 0;
}

sub _getAndParseRoster
{
	my ($self, $course_ref, $users_ref) = @_;
	my $r = $self->{r};
	my $parser = WebworkBridge::Bridges::LTIParser->new($r, $course_ref, $users_ref);


	if (defined($r->param("ext_ims_lis_memberships_url")))
	{
		my $xml;
		my $ret = $self->_getRoster(\$xml);
		if ($ret)
		{
			return error("Unable to connect to roster server: $ret", "#e003");
		}

		$ret = $parser->parse($xml);
		if ($ret)
		{
			return error("XML response received, but access denied.", "#e005");
		}
	}

	$course_ref->{name} = $parser->getCourseName();
	$course_ref->{title} = $r->param("context_title");
	$course_ref->{id} = $r->param("resource_link_id");

	return 0;
}

sub _getRoster
{
	my ($self, $xml) = @_;
	my $r = $self->{r};

	my $ua = LWP::UserAgent->new;
	my $key = $r->param('oauth_consumer_key');
	if (!defined($r->ce->{bridge}{lti_secrets}{$key}))
	{
		return error("Unknown secret key '$key', is there a typo?", "#e006");
	}
	my $request = Net::OAuth->request("request token")->new(
		consumer_key => $key,
		consumer_secret => $r->ce->{bridge}{lti_secrets}{$key},
		protocol_version => Net::OAuth::PROTOCOL_VERSION_1_0A,
		request_url => $r->param('ext_ims_lis_memberships_url'),
		request_method => 'POST',
		signature_method => 'HMAC-SHA1',
		timestamp => time(),
		nonce => rand(),
		callback => 'about:blank',
		extra_params => {
			lti_version => 'LTI-1p0',
			lti_message_type => 'basic-lis-readmembershipsforcontext',
			id => $r->param('ext_ims_lis_memberships_id'),
		}
	);
	$request->sign;

	# remove the params in URL from post body so that they will not be sent twice
	my @params = split('&', uri_unescape($request->to_post_body));
	my $url = URI->new($request->request_url);
	foreach my $k ($url->query_param) {
		@params = grep {$_ ne $k.'='.$url->query_param($k)} @params;
	}

	# have to generate the post parameters ourselves because of the way blti building block check the hash (memberships_id)
	my %p = map { (split('=', $_, 2))[0] => (split('=', $_, 2))[1] } @params;
	# extra prod logging when debug is disabled
	my $extralog = WebworkBridge::ExtraLog->new($r);
	$extralog->logXML("--- " . $r->param('context_title') . " ---");
	$extralog->logXML("LTI ID is " . $r->param('ext_ims_lis_memberships_id'));
	$extralog->logXML("User role: " . $r->param('roles'));
	# attempt actual request
	my $res = $ua->request((POST $request->request_url, \%p));
	if ($res->is_success)
	{
		$$xml = $res->content;
		debug("LTI Get Roster Success! \n" . $$xml . "\n");
		$extralog->logXML("Successfully retrieved roster: \n" . $$xml);
		return 0;
	}
	else
	{
		$extralog->logXML("Roster retrival failed, unable to connect.");
		return error("Unable to perform OAuth request.","#e007");
	}
}

sub _verifyMessage()
{
	my $self = shift;
	my $r = $self->{r};
	# verify that the message hasn't been tampered with
	my $ltiauthen = WeBWorK::Authen::LTI->new($r);
	my $ret = $ltiauthen->authenticate();
	if (!$ret)
	{
		return error("Error: LTI message integrity could not be verified. Check if the LTI launch URL has a trailing slash.","#e015");
	}
	return 0;
}

# Automatically add new users to course or update existing user information on launch.
# assign users to all the available assignments.
sub _updateLaunchUser()
{
	debug("Manage LTI Launch user account.");

	my $self = shift;
	my $r = $self->{r};
	my $ce = $r->ce;
	my $db = $r->db;

	if (defined($r->param('ubc_auto_update'))) {
		# skip _updateLaunchUser if automatic update
		debug("Skip updating Launch user for automatic update.");
		return;
	}

	debug("Parsing user information.");

	# parse user from launch request
	my $parser = WebworkBridge::Bridges::LTIParser->new($r);
	my %user = $parser->parseLaunchUser();

	debug(Dumper(\%user));

	my $course = ();
	$course->{name} = $ce->{"courseName"};
	my $updater = WebworkBridge::Importer::CourseUpdater->new($r, $course, "");

	# check if user exists
	if ($db->existsUser($user{'loginid'})) {
		debug("Attempt to update user & assign assignments.");
		my $oldUser = $db->getUser($user{'loginid'});
		my $oldPermission = $db->getPermissionLevel($user{'loginid'});
		$updater->updateUser($oldUser, \%user, $oldPermission, $db);
		# assign all visible homeworks to students
		if ($oldPermission->permission() <= $ce->{userRoles}{student}) {
			$updater->assignAllVisibleSetsToUser($user{'loginid'}, $db);
		}
	}
	else {
		debug("Attempt to create user & assign assignments.");
		$updater->addUser(\%user, $db, "");
	}

	# update user homework set lis_source_did if quiz or homework set
	if (($self->getHomeworkSet() || $self->getQuizSet()))
	{
		debug("Setting lis_source_did for user homeworkset context");
		my $setId = $self->getHomeworkSet() ? $self->getHomeworkSet() : $self->getQuizSet();

		if ($db->existsUserSet($user{'loginid'}, $setId))
		{
			my $userSet = $db->getUserSet($user{'loginid'}, $setId);
			$userSet->lis_source_did($r->param('lis_result_sourcedid'));
			$db->putUserSet($userSet);
		}
	}

	debug("Done.");
}

1;
