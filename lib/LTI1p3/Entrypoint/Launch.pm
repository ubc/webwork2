package LTI1p3::Entrypoint::Launch;
use Mojo::Base 'LTI1p3::Entrypoint', -strict, -signatures, -async_await;

##### Library Imports #####

use Data::Dumper;
use URI::Escape;
use WeBWorK::Utils qw(before after between formatDateTime);
use WeBWorK::CourseEnvironment;
use WeBWorK::DB;
use WeBWorK::Debug;

use LTI1p3::Importer::Error;
use LTI1p3::Parser::LaunchParser;
use WeBWorK::Authen::LTI1p3;
use LTI1p3::Service::NamesAndRoleService;

use Mojo::URL;

#$WeBWorK::Debug::Enabled = 1;

sub accept ($c)
{
	if ($c->param("id_token") && $c->param("state")) {
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

async sub run ($c)
{
	debug("LTI1p3 Start Processing Redirect");
	# no actual course yet, create an empty course environment
	my $ce = $c->ce(WeBWorK::CourseEnvironment->new({
		webwork_dir => $ENV{WEBWORK_ROOT},
	}));
	my $db = $c->db(new WeBWorK::DB($ce->{dbLayout}));
	# in case we were sent a CORS request, add appropriate response headers
	$c->_addCorsHeaders($ce);

	$c->{parser} = LTI1p3::Parser::LaunchParser->new($ce, $c->param("id_token"));
	my $parser = $c->{parser};

	if ($parser->{error}) {
		debug("parser error: ". $parser->{error});
		if ($parser->{error} =~ m/^JWT: exp claim check failed/) {
			return $c->reply->exception($c->maketext("Your launch request has expired. Please click on the LTI link again."))->rendered(400);
		} else {
			return $c->reply->exception($c->maketext("Unfortunately, the LTI launch failed. This might be a temporary condition. If it persists, please mail an error report with the time that the error occured and the exact error message below:" . $parser->{error}))->rendered(400);
		}
	}

	# check if user wants to go directly to an assignment/quiz
	my $set_id_custom_claim = $parser->get_claim_param("custom", "set");
	if ($set_id_custom_claim) {
		# not perfect sanitization, but need something
		$set_id_custom_claim = $parser->sanitizeSetName($set_id_custom_claim);
		$c->{setId} = $set_id_custom_claim;
	} else {
		# ubc's Canvas Instructor Guide procedure modifies the target_link_uri
		# to put the set id at the end in the query section of the uri
		my $targetLinkUriClaim = $parser->get_claim('target_link_uri');
		# check query string for set id
		my @query_params = ('set', 'custom_set', 'homework_set', 'custom_homework_set', 'quiz_set', 'custom_quiz_set');
		foreach my $query_param (@query_params) {
			if (!$targetLinkUriClaim) { last; }
			my $targetLinkUri = Mojo::URL->new($targetLinkUriClaim);
			my $uriQueries = $targetLinkUri->query;
			my $set_id_query_param = $uriQueries->param($query_param);
			if ($set_id_query_param) {
				debug('User wants to go directly to set: ' . $set_id_query_param);
				# not perfect sanitization, but need something
				$set_id_query_param = $parser->sanitizeSetName($set_id_query_param);
				$c->{setId} = $set_id_query_param;
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

		# Check for course existence
		if($db->existsLTIContext($client_id, $context_id)) {
        	my $lti_context = $db->getLTIContext($client_id, $context_id);
			# over write course id with value stored in context table
			$course_id = $lti_context->course_id();
		}

		# setup tmp course ce and db
		my $tmpce = WeBWorK::CourseEnvironment->new({
			courseName => $course_id,
		});

		# set request ce and db to courseID
		$c->stash('courseID', $course_id);
		$c->ce($tmpce);
		$c->db(new WeBWorK::DB($c->ce->{dbLayout}));
		$db = $c->db;

		my $authz = WeBWorK::Authz->new($c);
		$c->authz($authz);
		# verify message
		my $ret = $c->_verifyMessage();
		if ($ret) {
			debug("_verifyMessage error: ". $ret);
			return $c->reply->exception($c->maketext("Unfortunately, the LTI launch failed. This might be a temporary condition. If it persists, please mail an error report with the time that the error occured and the exact error message below: $ret"))->rendered(400);
		}

		# direct the student directly to a homework assignment or quiz if needed
		my $redir = $c->url_for('set_list', courseID => $course_id);
		unless (-e $tmpce->{courseDirs}->{root}) {
			# course does not exist
			debug("Course does not exist, try LTI import.");

			$ret = $c->createCourse();
			if ($ret) {
				debug("createCourse error: ". $ret);
				return $c->reply->exception($c->maketext("Unfortunately, the LTI launch failed. This might be a temporary condition. If it persists, please mail an error report with the time that the error occured and the exact error message below: $ret"))->rendered(400);
			}

			$c->flash(lti1p3good => $c->maketext(
				"The course was successfully imported into Webwork."));
		}
		$c->_updateLTISettings();
		$c->_updateLaunchUser();

		# now we can log the user in, before this point, the course might not
		# have existed and thus the user might not have existed
		$ret = $c->_verifyUser();
		if ($ret) {
			debug("_verifyUser error: ". $ret);
			return $c->reply->exception($c->maketext("Unfortunately, the LTI launch failed. This might be a temporary condition. If it persists, please mail an error report with the time that the error occured and the exact error message below: $ret"))->rendered(400);
		}

		if ($c->getSetId()) {
			my %user = $parser->get_user_info();
			my $user_id = $user{'loginid'};
			my $set = $db->getMergedSet($user_id, $c->getSetId());

			if ($set && defined( $set->assignment_type() ) ) {
				my @allVersionIds = $db->listSetVersions($user_id , $c->getSetId());
				my $latest_version = (@allVersionIds ? $allVersionIds[-1] : 0);

				if (before($set->open_date)) {
					my $display_name = $c->getSetId();
					$display_name =~ s/_/ /g;
					$c->flash(lti1p3bad =>  
						$display_name." not open yet, will open on " . formatDateTime($set->open_date, $tmpce->{siteDefaults}{timezone}, $tmpce->{studentDateDisplayFormat})
					);
				} elsif ( $set->assignment_type() eq 'proctored_gateway' ) {
					$redir .= "/proctored_test_mode/" . $c->getSetId() . ($latest_version ? ",v$latest_version" : "");
				} elsif ( $set->assignment_type() eq 'gateway' ) {
					$redir .= "/test_mode/" . $c->getSetId() . ($latest_version ? ",v$latest_version" : "");
				} else {
					$redir .= "/" . $c->getSetId();
				}
			}
		}
		# ensure authentification module is used
		$c->{useAuthenModule} = 1;
		$c->{useRedirect} = 1;
		$c->{redirect} = $redir;
	}
	$c->redirect_to($c->{redirect});

	return 0;
}

sub getAuthenModule ($c)
{
	return WeBWorK::Authen::class($c->ce, "lti");
}

sub createCourse ($c)
{
	my $ce = $c->ce;
	my $db = $c->db;
	my $parser = $c->{parser};

	my $permissions = $parser->get_permissions();
	if ($permissions < $ce->{userRoles}{designer}) {
		return error("Please ask your instructor to import this course into Webworks first.", "#e011");
	}

	my $ret = $c->SUPER::createCourse($parser->getCourseName(), $parser->get_claim_param("context", "title"));
	if ($ret) {
		return error("Create course failed: $ret", "#e010");
	}

	# store LTI credentials for auto-update
	$c->_updateLTISettings();

	# add current user to the course
	$c->_updateLaunchUser();

	# try to update roster if names and role service enabled
	$c->_updateClassRoster();

	return 0;
}

sub _updateLTISettings ($c)
{
	debug("Update LTI Settings");
	my $ce = $c->ce;
	my $db = $c->db;
	my $parser = $c->{parser};

	my $client_id = $parser->get_param("aud");
	my $context_id = $parser->get_claim_param("context", "id");
	my $resource_link_id = $parser->get_claim_param("resource_link", "id");

	my $lti_context;
	my $exists = $db->existsLTIContext($client_id, $context_id);

	if($exists) {
        $lti_context = $db->getLTIContext($client_id, $context_id);
		# turn autosync back on for courses that had it off, assuming that
		# people launching into the course means it needs to be active again
		$lti_context->can_auto_sync(1);
    } else {
        $lti_context = $db->newLTIContext(
			client_id => $client_id,
			context_id => $context_id,
			# course_title is only set up new for lti contexts
			course_id => $ce->{courseName},
			can_auto_sync => 1
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

		if ($c->getSetId()) {
			$lti_resource_link->set_id($c->getSetId());
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
			# defaults to valid for new resources, for existing resources, this
			# reactivates a deleted resource that seems have been restored
			$lti_resource_link->is_valid(1);
		} else {
			$lti_resource_link->lineitems_url("");
			$lti_resource_link->lineitem_url("");
			$lti_resource_link->scope_lineitem("");
			$lti_resource_link->scope_lineitem_read_only("");
			$lti_resource_link->scope_result_readonly("");
			$lti_resource_link->scope_result_score("");
		}

		if($exists) {
			$db->putLTIResourceLink($lti_resource_link);
		} else {
			$db->addLTIResourceLink($lti_resource_link);
		}
	}
}

# Automatically add new users to course or update existing user information on launch.
# assign users to all the available assignments.
sub _updateLaunchUser ($c)
{
	debug("Manage LTI Launch user account.");

	my $ce = $c->ce;
	my $db = $c->db;
	my $parser = $c->{parser};

	debug("Parsing user information.");
	# parse user from launch request
	my %user = $parser->get_user_info();

	debug(Dumper(\%user));

	my $updater = LTI1p3::Importer::CourseUpdater->new($ce, $db, '');
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
sub _updateClassRoster ($c)
{
	my $ce = $c->ce;
	my $db = $c->db;
	my $parser = $c->{parser};

	debug("Update class roster if available.");

	# try to update course enrolment
	if ($parser->get_nrps_claim()) {
		my $names_and_roles_service = LTI1p3::Service::NamesAndRoleService->new($ce, $db);
		my $membership = $names_and_roles_service->getAllNamesAndRole();
		unless ($membership) {
			debug("There was an issue fetching the class roster. ".$names_and_roles_service->{error});
			return error("There was an issue fetching the class roster. ".$names_and_roles_service->{error}, "#e016");
		}
		my $ret = $c->SUPER::updateCourse($ce, $db, $membership);
		if ($ret) {
			return error("Update Class Roster failed: $ret", "#e010");
		}
	}

	debug("Done.");
	return 0;
}

sub _verifyMessage ($c)
{
	# verify that the message hasn't been tampered with
	my $ltiauthen = WeBWorK::Authen::LTI1p3->new($c);
	$c->authen($ltiauthen);
	my $ret = $c->authen->verifyIdToken();
	if (!$ret) {
		return error("Error: LTI message integrity could not be verified. Check if the LTI launch URL has a trailing slash.","#e015");
	}
	return 0;
}

sub _verifyUser ($c)
{
	$c->param('isCalledByLti1p3Launch', 1);
	my $ret = $c->authen->verify();
	if (!$ret) {
		return error("Error: LTI user could not be verified: $ret", "#e015");
	}
	return 0;
}

1;
