package LTIAdvantage::Entrypoint::Launch;
use base qw(LTIAdvantage::Entrypoint);

##### Library Imports #####
use strict;
use warnings;

use Data::Dumper;
use URI::Escape;
use CGI;
use WeBWorK::Utils qw(before after between formatDateTime);
use WeBWorK::CourseEnvironment;
use WeBWorK::DB;
use WeBWorK::Debug;

use LTIAdvantage::Importer::Error;
use LTIAdvantage::Parser::LaunchParser;
use WeBWorK::Authen::LTIAdvantage;
use LTIAdvantage::Service::NamesAndRoleService;

#$WeBWorK::Debug::Enabled = 1;

# Constructor
sub new
{
	my ($class, $r) = @_;
	my $self = $class->SUPER::new($r);
	my $ce = $r->ce;
	$self->{parser} = LTIAdvantage::Parser::LaunchParser->new($ce, $r->param("id_token"));
	bless $self, $class;
	return $self;
}

sub accept
{
	my $self = shift;
	my $r = $self->{r};
	if ($r->param("id_token") && $r->param("state")) {
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
	my $parser = $self->{parser};

	if ($parser->{error}) {
		debug("parser error: ". $parser->{error});
		my $error_message = CGI::h2("LTI Launch Failed");
		if ($parser->{error} =~ m/^JWT: exp claim check failed/) {
			$error_message .= CGI::div({class=>"ResultsWithError"}, CGI::pre("Your launch request has expired. Please click on the LTI link again.") );
		} else {
			$error_message .= CGI::p("Unfortunately, the LTI launch failed. This might be a temporary condition. If it persists, please mail an error report with the time that the error occured and the exact error message below:");
			$error_message .= CGI::div({class=>"ResultsWithError"}, CGI::pre($parser->{error}) );
		}
		return $error_message;
	}

	# check if user wants to go directly to an assignment/quiz
	my $set_id_custom_claim = $parser->get_claim_param("custom", "set");
	if ($set_id_custom_claim) {
		# not perfect sanitization, but need something
		$set_id_custom_claim = $parser->sanitizeSetName($set_id_custom_claim);
		$self->{setId} = $set_id_custom_claim;
	} else {
		# check query string for set id
		my @query_params = ('set', 'custom_set', 'homework_set', 'custom_homework_set', 'quiz_set', 'custom_quiz_set');
		foreach my $query_param (@query_params) {
			my $set_id_query_param = $r->param($query_param);
			if ($set_id_query_param) {
				# not perfect sanitization, but need something
				$set_id_query_param = $parser->sanitizeSetName($set_id_query_param);
				$self->{setId} = $set_id_query_param;
				last;
			}
		}
	}

	my $client_id = $parser->get_param("aud");
	my $context_id = $parser->get_claim_param("context", "id");
	my $course_id = $parser->getCourseName();

	# LTI processing
	if ($client_id && $context_id && $course_id)
	{
		debug("LTI detected\n");

		# verify message
		my $ret = $self->_verifyMessage();
		if ($ret) {
			debug("_verifyMessage error: ". $ret);
			my $error_message = CGI::h2("LTI Launch Failed");
			$error_message .= CGI::p("Unfortunately, the LTI launch failed. This might be a temporary condition. If it persists, please mail an error report with the time that the error occured and the exact error message below:");
			$error_message .= CGI::div({class=>"ResultsWithError"}, CGI::pre($ret) );
			return $error_message;
		}

		# Check for course existence
		if($db->existsLTIContext($client_id, $context_id)) {
        	my $lti_context = $db->getLTIContext($client_id, $context_id);
			# over write course id with value stored in context table
			$course_id = $lti_context->course_id();
		}

		# setup tmp course ce and db
		my $tmpce = WeBWorK::CourseEnvironment->new({
			%WeBWorK::SeedCE,
			courseName => $course_id,
			apache_hostname => $ce->{apache_hostname},
			apache_port => $ce->{apache_port},
			apache_is_ssl => $ce->{apache_is_ssl},
			apache_root_url => $ce->{apache_root_url},
		});

		# set request ce and db to courseID
		$r->{ce} = $tmpce;
		$r->{db} = new WeBWorK::DB($r->ce->{dbLayout});
		$db = $r->db;

		# direct the student directly to a homework assignment or quiz if needed
		my $redir = $r->uri . $course_id;
		my $status_message = "";

		if ($self->getSetId()) {
			my %user = $parser->get_user_info();
			my $user_id = $user{'loginid'};
			my $set = $db->getMergedSet($user_id, $self->getSetId());

			if ($set && defined( $set->assignment_type() ) ) {
				my @allVersionIds = $db->listSetVersions($user_id , $self->getSetId());
				my $latest_version = (@allVersionIds ? $allVersionIds[-1] : 0);

				if (before($set->open_date)) {
					my $display_name = $self->getSetId();
					$display_name =~ s/_/ /g;
					$status_message = CGI::div(
						{class=>"ResultsWithoutError"},
						$display_name." will open on " . formatDateTime($set->open_date, undef, $tmpce->{studentDateDisplayFormat})
					);
				} elsif ( $set->assignment_type() eq 'proctored_gateway' ) {
					$redir .= "/proctored_quiz_mode/" . $self->getSetId() . ($latest_version ? ",v$latest_version" : "");
				} elsif ( $set->assignment_type() eq 'gateway' ) {
					$redir .= "/quiz_mode/" . $self->getSetId() . ($latest_version ? ",v$latest_version" : "");
				} else {
					$redir .= "/" . $self->getSetId();
				}
			}
		}
		if (-e $tmpce->{courseDirs}->{root}) {
			# course exists
			$self->_updateLTISettings();
			$self->_updateLaunchUser();
		} else {
			# course does not exist
			debug("Course does not exist, try LTI import.");

			$ret = $self->createCourse();
			if ($ret) {
				debug("createCourse error: ". $ret);
				my $error_message = CGI::h2("LTI Launch Failed");
				$error_message .= CGI::p("Unfortunately, import failed. This might be a temporary condition. If it persists, please mail an error report with the time that the error occured and the exact error message below:");
				$error_message .= CGI::div({class=>"ResultsWithError"}, CGI::pre($ret) );
				return $error_message;
			}

			# ensure current user can access even if membership fails
			$self->_updateLaunchUser();

			$status_message = CGI::div(
				{class=>"ResultsWithoutError"},
				"The course was successfully imported into Webwork."
			);
		}
		# ensure authentification module is used
		$self->{useAuthenModule} = 1;
		$self->{useRedirect} = 1;
		$self->{redirect} = $redir."?lti=1&status_message=".uri_escape_utf8($status_message);
	}

	return 0;
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
	my $db = $r->db;
	my $parser = $self->{parser};

	my $permissions = $parser->get_permissions();
	if ($permissions < $ce->{userRoles}{professor}) {
		return error("Please ask your instructor to import this course into Webworks first.", "#e011");
	}

	my $ret = $self->SUPER::createCourse($parser->getCourseName(), $parser->get_claim_param("context", "title"));
	if ($ret) {
		return error("Create course failed: $ret", "#e010");
	}

	# store LTI credentials for auto-update
	$self->_updateLTISettings();

	# add current user to the course
	$self->_updateLaunchUser();

	# try to update roster if names and role service enabled
	$self->_updateClassRoster();

	return 0;
}

sub _updateLTISettings()
{
	my $self = shift;
	my $r = $self->{r};
	my $ce = $r->ce;
	my $db = $r->db;
	my $parser = $self->{parser};

	my $client_id = $parser->get_param("aud");
	my $context_id = $parser->get_claim_param("context", "id");
	my $resource_link_id = $parser->get_claim_param("resource_link", "id");

	my $lti_context;
	my $exists = $db->existsLTIContext($client_id, $context_id);

	if($exists) {
        $lti_context = $db->getLTIContext($client_id, $context_id);
    } else {
        $lti_context = $db->newLTIContext(
			client_id => $client_id,
			context_id => $context_id,
			# course_title is only set up new for lti contexts
			course_id => $ce->{courseName}
		);
	}

	if ($parser->get_nrps_claim()) {
		$lti_context->context_memberships_url($parser->get_nrps_claim_param("context_memberships_url"));
	} else {
		$lti_context->context_memberships_url("");
	}

	if($exists) {
        $db->putLTIContext($lti_context);
    } else {
        $db->addLTIContext($lti_context);
	}

	# only if resource_link_id is present
	if ($resource_link_id) {
		my $lti_resource_link;
		$exists = $db->existsLTIResourceLink($client_id, $context_id, $resource_link_id);

		if($exists) {
			$lti_resource_link = $db->getLTIResourceLink($client_id, $context_id, $resource_link_id);
		} else {
			$lti_resource_link = $db->newLTIResourceLink(
				client_id => $client_id,
				context_id => $context_id,
				resource_link_id => $resource_link_id,
			);
		}

		if ($self->getSetId()) {
			$lti_resource_link->set_id($self->getSetId());
		} else {
			$lti_resource_link->set_id("");
		}

		my $resource_link_id = $parser->get_claim_param("resource_link", "id");

		if ($parser->get_ags_claim()) {
			$lti_resource_link->lineitems_url($parser->get_ags_claim_param("lineitems"));
			$lti_resource_link->lineitem_url($parser->get_ags_claim_param("lineitem"));
			$lti_resource_link->scope_lineitem($parser->has_ags_claim_scope("lineitem"));
			$lti_resource_link->scope_lineitem_read_only($parser->has_ags_claim_scope("lineitem.readonly"));
			$lti_resource_link->scope_result_readonly($parser->has_ags_claim_scope("result.readonly"));
			$lti_resource_link->scope_result_score($parser->has_ags_claim_scope("score"));
		} else {
			$lti_resource_link->lineitems_url("");
			$lti_resource_link->lineitem_url("");
			$lti_resource_link->scope_lineitem("");
			$lti_resource_link->scope_lineitem_read_only("");
			$lti_resource_link->scope_result_readonly("");
			$lti_resource_link->scope_result_score("");
		}

		$lti_resource_link->is_valid(1);
		if($exists) {
			$db->putLTIResourceLink($lti_resource_link);
		} else {
			$db->addLTIResourceLink($lti_resource_link);
		}
	}
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
	my $parser = $self->{parser};

	debug("Parsing user information.");
	# parse user from launch request
	my %user = $parser->get_user_info();

	debug(Dumper(\%user));

	my $updater = LTIAdvantage::Importer::CourseUpdater->new($ce, $db, '');
	# check if user exists
	if ($db->existsUser($user{'loginid'})) {
		debug("Attempt to update user & assign assignments.");
		my $oldUser = $db->getUser($user{'loginid'});
		my $oldPermission = $db->getPermissionLevel($user{'loginid'});
		$updater->updateUser($oldUser, \%user, $oldPermission);
	} else {
		debug("Attempt to create user & assign assignments.");
		$updater->addUser(\%user);
	}

	debug("Done.");
}

# Automatically add new users to course or update existing user information on launch.
# assign users to all the available assignments.
sub _updateClassRoster()
{
	my $self = shift;
	my $r = $self->{r};
	my $ce = $r->ce;
	my $db = $r->db;
	my $parser = $self->{parser};

	debug("Update class roster if available.");

	# try to update course enrolment
	if ($parser->get_nrps_claim()) {
		my $names_and_roles_service = LTIAdvantage::Service::NamesAndRoleService->new($ce, $db);
		my $membership = $names_and_roles_service->getAllNamesAndRole();
		unless ($membership) {
			debug("There was an issue fetching the class roster. ".$names_and_roles_service->{error});
			return error("There was an issue fetching the class roster. ".$names_and_roles_service->{error}, "#e016");
		}
		my $ret = $self->SUPER::updateCourse($ce, $db, $membership);
		if ($ret) {
			return error("Update Class Roster failed: $ret", "#e010");
		}
	}

	debug("Done.");
	return 0;
}

sub _verifyMessage()
{
	my $self = shift;
	my $r = $self->{r};
	# verify that the message hasn't been tampered with
	my $ltiauthen = WeBWorK::Authen::LTIAdvantage->new($r);
	my $ret = $ltiauthen->authenticate();
	if (!$ret) {
		return error("Error: LTI message integrity could not be verified. Check if the LTI launch URL has a trailing slash.","#e015");
	}
	return 0;
}

1;
