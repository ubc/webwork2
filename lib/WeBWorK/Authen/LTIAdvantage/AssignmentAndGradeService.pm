###############################################################################
# WeBWorK Online Homework Delivery System
# Copyright &copy; 2000-2016 The WeBWorK Project, http://openwebwork.sf.net/
#
# This program is free software; you can redistribute it and/or modify it under
# the terms of either: (a) the GNU General Public License as published by the
# Free Software Foundation; either version 2, or (at your option) any later
# version, or (b) the "Artistic License" which comes with this package.
#
# This program is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
# FOR A PARTICULAR PURPOSE.  See either the GNU General Public License or the
# Artistic License for more details.
################################################################################

package WeBWorK::Authen::LTIAdvantage::AssignmentAndGradeService;

=head1 NAME

WeBWorK::Authen::LTIAdvantage::AssignmentAndGradeService

=cut

use strict;
use warnings;
use WeBWorK::Debug;
use WeBWorK::CGI;
use Net::OAuth;
use HTTP::Request;
use LWP::UserAgent;
use Digest::SHA qw(sha1_base64);
use Data::Dumper;
use WeBWorK::Utils qw(before after between formatDateTime);
use JSON;

use HTTP::Request::Common;
use HTTP::Async;

use WeBWorK::Authen::LTIAdvantage::AccessTokenRequest;
use WebworkBridge::ExtraLog;

#$WeBWorK::Debug::Enabled = 1;

# This package is used for managing and sending grades back to the LMS
sub new {
	my ($invocant, $ce, $db) = @_;
	my $class = ref($invocant) || $invocant;
	my $self = {
		ce => $ce,
		db => $db,
		error => '',
	};
	bless $self, $class;
	return $self;
}

sub pushAllAssignmentGrades {
	my $self = shift;
	my $ce = $self->{ce};
	my $db = $self->{db};

	my @lti_resource_links = $db->getAllLTIResourceLinks();
	# ensure there are lti links to update
	return if scalar(@lti_resource_links) == 0;

	my @lti_users = $db->getAllLTIUsers();

	my @user_ids = $db->listUsers();
	my @users_list = $db->getUsers(@user_ids);
	my @perms_list = $db->getPermissionLevels(@user_ids);

	my %users = map {($_->user_id => $_ )} @users_list;
	my %perms = map {($_->user_id => $_ )} @perms_list;

	# Step 1: Calulate grades for all students who need thier grade calculated

	# {user_id => {set_id => grade_record}}
	my $user_grades = {};
	foreach my $user (@users_list) {
		my $user_id = $user->user_id();

		# skip if user no longer in course
		next if !exists $perms{$user_id};

		# skip if user not student
		next if $perms{$user_id}->permission() != $ce->{userRoles}{student};

		my @current_lti_users = grep { $_->user_id() eq $user_id } @lti_users;

		# skip if not linked to a lti user account
		next if scalar(@current_lti_users) == 0;

		my $grades = {};

		# get grades
		my @set_ids = $db->listUserSets($user_id);
		my @sets = $db->getMergedSets( map {[$user_id, $_]} @set_ids );

		my $course_total_right = 0;
		my $course_total = 0;

		foreach my $set ( @sets ) {
			# go through each assigned set
			my $grade_record = $self->_getGradeRecords($set, $user_id);
			if (defined($grade_record)) {
				$course_total_right += $grade_record->{total_right};
				$course_total += $grade_record->{total};
				$grades->{$grade_record->{set_id}} = $grade_record;
			}
		}

		# pass back course grade
		my $course_grade_record = $self->_getCourseGradeRecord($user_id, $course_total, $course_total_right);
		$grades->{'/--course_overall--/'} = $course_grade_record;
		$user_grades->{$user_id} = $grades;
	}

	# Step 2: Get a list of grades to update for each resourse link (that allow grade updates)
	my $lti_assignment_and_grade_requests = $self->_generate_requests(
		\@lti_resource_links, \@lti_users, $user_grades);

	# ensure there are lti rrequests to update
	return if scalar(@{$lti_assignment_and_grade_requests}) == 0;

	$self->_performAssignmentAndGradeRequests($lti_assignment_and_grade_requests);
}

sub pushUserGradesOnSubmit {
	my $self = shift;
	my $user_id = shift;
	my $set_id = shift;
	my $ce = $self->{ce};
	my $db = $self->{db};

	my @lti_resource_links = $db->getAllLTIResourceLinks();
	@lti_resource_links = grep { $_->set_id() eq '' || $_->set_id() eq $set_id } @lti_resource_links;
	# ensure there are lti resource links to update
	return if scalar(@lti_resource_links) == 0;

	my $permission = $db->getPermissionLevel($user_id);

	# ensure user is a student
	return if !defined($permission) || $permission->permission() != $ce->{userRoles}{student};

	my @lti_users = $db->getLTIUserByUserID($user_id);

	# ensure there are lti links to update
	return if scalar(@lti_users) == 0;

	# Step 1: Calulate grades for student
	my $user_grades = {
		$user_id => {}
	};

	# get grades
	my @set_ids = $db->listUserSets($user_id);
	my @sets = $db->getMergedSets( map {[$user_id, $_]} @set_ids );

	my $course_total_right = 0;
	my $course_total = 0;

	foreach my $set ( @sets ) {
		# go through each assigned set
		my $grade_record = $self->_getGradeRecords($set, $user_id);
		if (defined($grade_record)) {
			$course_total_right += $grade_record->{total_right};
			$course_total += $grade_record->{total};
			if ($set->set_id() eq $set_id) {
				$user_grades->{$user_id}->{$set_id} = $grade_record;
			}
		}
	}

	# pass back course grade
	my $course_grade_record = $self->_getCourseGradeRecord($user_id, $course_total, $course_total_right);
	$user_grades->{$user_id}->{'/--course_overall--/'} = $course_grade_record;


	# Step 2: Get a list of grades to update for each resourse link (that allow grade updates)

	my $lti_assignment_and_grade_requests = $self->_generate_requests(
		\@lti_resource_links, \@lti_users, $user_grades);

	# ensure there are lti rrequests to update
	return if scalar(@{$lti_assignment_and_grade_requests}) == 0;

	$self->_performAssignmentAndGradeRequests($lti_assignment_and_grade_requests);
}
sub _generate_requests {
	my $self = shift;
	my $lti_resource_links = shift;
	my $lti_users = shift;
	my $user_grades = shift;

	my $ce = $self->{ce};
	my $db = $self->{db};

	my @lti_assignment_and_grade_requests = ();
	foreach my $lti_resource_link (@{$lti_resource_links}) {

		my $client_id = $lti_resource_link->client_id();
		my $context_id = $lti_resource_link->context_id();
		my $resource_link_id = $lti_resource_link->resource_link_id();
		my $set_id = $lti_resource_link->set_id();
		$set_id = '/--course_overall--/' if !defined($set_id) || $set_id eq '';

		# Canvas HACK: if context_id == resource_link_id then grades cannot be sent back
		# (canvas marks the links as having permission to update but errors if you try)
		next if $resource_link_id eq $context_id;

		# skip if cannot update grades
		next if !$lti_resource_link->scope_result_score();

		my @client_lti_users = grep { $_->client_id() eq $client_id } @{$lti_users};

		my @grades_to_update = ();
		foreach my $lti_user (@client_lti_users) {
			my $lti_user_id = $lti_user->lti_user_id();
			my $user_id = $lti_user->user_id();

			if (defined($user_grades->{$user_id}) && defined($user_grades->{$user_id}->{$set_id})) {
				my $grade_record = $user_grades->{$user_id}->{$set_id};

				my $lti_grade_record = {
					set_id => $set_id,
					lti_user_id => $lti_user_id,
					user_id => $user_id,
					grade => $grade_record->{grade},
					activity_progress => $grade_record->{activity_progress},
					grading_progress => $grade_record->{grading_progress},
					timestamp => $grade_record->{timestamp}
				};
				push(@grades_to_update, $lti_grade_record);
			}
		}

		my $lti_assignment_and_grade_request = {
			lti_resource_link => $lti_resource_link,
			grades_to_update => \@grades_to_update
		};
		push(@lti_assignment_and_grade_requests, $lti_assignment_and_grade_request);
	}

	return \@lti_assignment_and_grade_requests;
}

sub _performAssignmentAndGradeRequests {
	my $self = shift;
	my $lti_assignment_and_grade_requests = shift;
	my $ce = $self->{ce};
	my $db = $self->{db};

	my $extralog = WebworkBridge::ExtraLog->new($ce);
	$extralog->logAGSRequest("Beginning LTI Assignment and Grade Service requests for Course: ".$ce->{courseName});
	debug("Beginning LTI Assignment and Grade Service requests for Course: ".$ce->{courseName});

	foreach my $lti_assignment_and_grade_request (@{$lti_assignment_and_grade_requests}) {
		my $lti_resource_link = $lti_assignment_and_grade_request->{lti_resource_link};
		my @grades_to_update = @{$lti_assignment_and_grade_request->{grades_to_update}};
		my @grades_to_skip = ();

		my $client_id = $lti_resource_link->client_id();
		my $context_id = $lti_resource_link->context_id();
		my $resource_link_id = $lti_resource_link->resource_link_id();

		$extralog->logAGSRequest("Beginning LTI Assignment and Grade Service request for Client: $client_id, Context: $context_id, Resource Link: $resource_link_id");
		debug("Beginning LTI Assignment and Grade Service request for Client: $client_id, Context: $context_id, Resource Link: $resource_link_id");

		# skip if cannot update grades
		next if !$lti_resource_link->scope_result_score();

		my $scopes = "https://purl.imsglobal.org/spec/lti-ags/scope/score";
		if ($lti_resource_link->scope_lineitem()) {
			$scopes .= " https://purl.imsglobal.org/spec/lti-ags/scope/lineitem";
		}
		if ($lti_resource_link->scope_result_readonly()) {
			$scopes .= " https://purl.imsglobal.org/spec/lti-ags/scope/result.readonly";
		}

		my $lti_access_token_request = WeBWorK::Authen::LTIAdvantage::AccessTokenRequest->new($ce, $client_id, $scopes);
		my $access_token = $lti_access_token_request->getAccessToken();
		unless ($access_token) {
			$self->{error} = "Assignment and Grades Service request failed, unable to get an access token for scopes: $scopes";
			$extralog->logAGSRequest($self->{error});
			return 0;
		}

		my $set_id = $lti_resource_link->set_id();
		$set_id = '/--course_overall--/' if !defined($set_id) || $set_id eq '';
		my $label = $set_id eq '/--course_overall--/' ? "WeBWorK Course Grade" : "WeBWorK ".$set_id." Grade";

		debug("Resource link set id: $set_id with label: $label");

		my $lineitem_url = $lti_resource_link->lineitem_url();
		my $lineitems_url = $lti_resource_link->lineitems_url();
		# if there isn't a line item url already, create one
		if (!defined($lineitem_url) || $lineitem_url eq '') {
			# skip if cannot modify line items
			next if !$lti_resource_link->scope_lineitem();

			# skip if no line item url
			next if !defined($lineitems_url) || $lineitems_url eq '';

			my $ua = LWP::UserAgent->new();
			$ua->default_header( 'Accept' => 'application/vnd.ims.lis.v2.lineitem+json' );
			$ua->default_header( 'Authorization' => "Bearer $access_token");
			my $params = {
				scoreMaximum => 1.0,
				label => $label,
				resourceLinkId => $resource_link_id,
				tag => 'WebWork'
			};

			$extralog->logAGSRequest("Assignment and Grades Service (LineItems POST) request url: $lineitems_url, params: ".Dumper($params));
			debug("Assignment and Grades Service (LineItems POST) request url: $lineitems_url, params: ".Dumper($params));
			my $res = $ua->post($lineitems_url, $params);

			if ($res->is_success) {
				my $data = from_json($res->content);

				$extralog->logAGSRequest("Assignment and Grades Service (LineItems POST): Added new Line Item: \n" . Dumper($data) . "\n");
				debug("Assignment and Grades Service (LineItems): Added new Line Item: \n" . Dumper($data) . "\n");

				$lti_resource_link->lineitem_url($data->{'id'});
				$db->putLTIResourceLink($lti_resource_link);
				$lineitem_url = $lti_resource_link->lineitem_url();
			} elsif ($res->code eq 404 && $res->content =~ /resource does not exist/) {
				$extralog->logAGSRequest("Assignment and Grades Service (LineItems POST) request failed, unable to create new line item for resource link id: $resource_link_id");
				next;
			} else {
				$self->{error} = "Assignment and Grades Service (LineItems POST) request failed. " . $res->status_line;
				$extralog->logAGSRequest($self->{error});
				debug($self->{error});
				next;
			}
		} elsif ($lti_resource_link->scope_lineitem()) {
			my $ua = LWP::UserAgent->new();
			$ua->default_header( 'Accept' => 'application/vnd.ims.lis.v2.lineitem+json' );
			$ua->default_header( 'Authorization' => "Bearer $access_token");

			$extralog->logAGSRequest("Assignment and Grades Service (LineItem GET) request url: $lineitem_url");
			debug("Assignment and Grades Service (LineItem GET) request url: $lineitem_url");
			my $res = $ua->get($lineitem_url);

			if ($res->is_success) {
				my $data = from_json($res->content);

				$extralog->logAGSRequest("Assignment and Grades Service (LineItem GET): Get Line Item: \n" . Dumper($data) . "\n");
				debug("Assignment and Grades Service (LineItem GET): Get Line Item: \n" . Dumper($data) . "\n");
			} else {
				$self->{error} = "Assignment and Grades Service (LineItem GET) request failed. " . $res->status_line;
				$extralog->logAGSRequest($self->{error});
				debug($self->{error});
				next;
			}

		}

		# time to filter out unnecissary grade updates if scope_result_readonly is set
		if ($lti_resource_link->scope_result_readonly()) {

			my $lti_results = {};
			my $lineitem_results_url = "$lineitem_url/results";
			my $request_error = 0;
			while (1) {
				my $ua = LWP::UserAgent->new();
				$ua->default_header( 'Accept' => 'application/vnd.ims.lis.v2.resultcontainer+json' );
				$ua->default_header( 'Authorization' => "Bearer $access_token");

				$extralog->logAGSRequest("Assignment and Grades Service (LineItem Result GET) request url: $lineitem_results_url");
				debug("Assignment and Grades Service (LineItem Result GET) request url: $lineitem_results_url");
				my $res = $ua->get($lineitem_results_url);

				if ($res->is_success) {
					my $data = from_json($res->content);

					$extralog->logAGSRequest("Assignment and Grades Service (LineItem Result GET): Found these results: \n" . Dumper($data) . "\n");
					debug("Assignment and Grades Service (LineItem Result GET): Found these results: \n" . Dumper($data) . "\n");

					foreach my $lti_result (@{$data}) {
						if (defined($lti_result->{'resultScore'}) && defined($lti_result->{'userId'})) {
							$lti_results->{$lti_result->{'userId'}} = sprintf("%.4f", $lti_result->{'resultScore'});
						}
					}

					if (defined($res->header("Link"))) {
						my @links = split(',', $res->header("Link"));

						my $next_request_url = undef;
						foreach my $link (@links) {
							debug("link: $link");
							if ($link =~ /;.*rel.*next.*/) {
								$next_request_url = $link;
								# get just the url between the < >
								$next_request_url =~ s/^.*\<(http.*)>\s*;.*$/$1/g;
							}
						}
						if (defined($next_request_url)) {
							$lineitem_results_url = $next_request_url;
							next;
						}
					}
					last;
				} else {
					$self->{error} = "Assignment and Grades Service (LineItem Result GET) request failed." . $res->status_line;
					$extralog->logAGSRequest($self->{error});
					debug($self->{error});
					$request_error = 1;
					last;
				}
			}
			if ($request_error) {
				next;
			}

			# Skip updating if
			# 1) the grade is the same in webwork and consumer
			# 2) the grade is uninitialized in consumer and zero in webwork (aka no work as been done)
			@grades_to_skip = grep {
				(defined($lti_results->{$_->{lti_user_id}}) && $lti_results->{$_->{lti_user_id}} eq $_->{grade}) ||
				(!defined($lti_results->{$_->{lti_user_id}}) && $_->{grade} eq sprintf("%.4f", 0))
			} @grades_to_update;

			@grades_to_update = grep {
				!(
					(defined($lti_results->{$_->{lti_user_id}}) && $lti_results->{$_->{lti_user_id}} eq $_->{grade}) ||
					(!defined($lti_results->{$_->{lti_user_id}}) && $_->{grade} eq sprintf("%.4f", 0))
				)
			} @grades_to_update;
		}

		foreach my $grade_to_skip (@grades_to_skip) {
			my $lti_user_id = $grade_to_skip->{lti_user_id};
			my $user_id = $grade_to_skip->{user_id};
			my $set_id = $grade_to_skip->{set_id};
			my $grade = $grade_to_skip->{grade};

			$extralog->logAGSRequest("Skipping Grade update for User: $user_id, LTI User: $lti_user_id, Set: $set_id, Grade: $grade, Client: $client_id, Context: $context_id, Resource Link: $resource_link_id");
			debug("Skipping Grade update for User: $user_id, LTI User: $lti_user_id, Set: $set_id, Grade: $grade, Client: $client_id, Context: $context_id, Resource Link: $resource_link_id");
		}

		my $async = HTTP::Async->new;
		$async->slots( 10 );

		foreach my $grade_to_update (@grades_to_update) {
			my $lti_user_id = $grade_to_update->{lti_user_id};
			my $user_id = $grade_to_update->{user_id};
			my $set_id = $grade_to_update->{set_id};
			my $grade = $grade_to_update->{grade};

			$extralog->logAGSRequest("Updating Grade for User: $user_id, LTI User: $lti_user_id, Set: $set_id, Grade: $grade, Client: $client_id, Context: $context_id, Resource Link: $resource_link_id");
			debug("Updating Grade for User: $user_id, LTI User: $lti_user_id, Set: $set_id, Grade: $grade, Client: $client_id, Context: $context_id, Resource Link: $resource_link_id");

			my $params = {
				userId => $lti_user_id,
				scoreGiven => $grade,
				scoreMaximum => 1.0,
				timestamp =>  $grade_to_update->{timestamp},
				activityProgress => $grade_to_update->{activity_progress},
				gradingProgress => $grade_to_update->{grading_progress}
			};
			my $json_payload = JSON->new->canonical->encode($params);

			$extralog->logAGSRequest("Assignment and Grades Service (LineItem Score POST) request url: $lineitem_url/scores, params: ".Dumper($params));
			debug("Assignment and Grades Service (LineItem Score POST) request url: $lineitem_url/scores, params: ".Dumper($params));

			my $HTTPRequest = HTTP::Request->new('POST', "$lineitem_url/scores", [
				'Accept' => 'application/vnd.ims.lis.v1.score+json',
				'Content-Type' => 'application/json',
				'Authorization' => "Bearer $access_token"
			], $json_payload);
			$async->add($HTTPRequest);
		}

		while ( my $res = $async->wait_for_next_response ) {
			if (!$res->is_success) {
				# expected errors
				# Canvas Student View User (Test Student)
				if ($res->status_line eq '422 Unprocessable Entity' && $res->content eq '{"errors":{"type":"unprocessable_entity","message":"User not found in course or is not a student"}}') {
					$extralog->logAGSRequest(
						"Could not update grade for probable Canvas Student View user. " .
						"\nRequest URI: " . $res->request->uri .
						"\nRequest Content: " . $res->request->content
					);
					debug(
						"Could not update grade for probable Canvas Student View user. " .
						"\nRequest URI: " . $res->request->uri .
						"\nRequest Content: " . $res->request->content
					);
					next;
				}
				# Canvas Unpublished Assignment
				if ($res->status_line eq '422 Unprocessable Entity' && $res->content eq '{"errors":[{"field":"grade","message":"cannot be changed at this time: This assignment is still unpublished","error_code":null}]}') {
					$extralog->logAGSRequest(
						"Could not update grade for unpublished Canvas assignment. " .
						"\nRequest URI: " . $res->request->uri .
						"\nRequest Content: " . $res->request->content
					);
					debug(
						"Could not update grade for unpublished Canvas assignment. " .
						"\nRequest URI: " . $res->request->uri .
						"\nRequest Content: " . $res->request->content
					);
					next;
				}
				$self->{error} = "Assignment and Grades Service (LineItem Score POST) request failed. " .
					"\nStatus: " . $res->status_line .
					"\nRequest URI: " . $res->request->uri .
					"\nRequest Content: " . $res->request->content .
					"\nResponse: " . $res->content;
				debug($self->{error});
				$extralog->logAGSRequest($self->{error});
			}
		}
	}
}

#### Private Helper Functions ####

# Get grade records for a user's problem set
# There are 2 types of assignments with different grade types,
# the gateway quizzes may have multiple grades for multiple tries
sub _getGradeRecords
{
	my ($self, $set, $user_id) = @_;
	my $ce = $self->{ce};
	my $db = $self->{db};

	my $set_name = $set->set_id();

	if (defined($set->assignment_type) && $set->assignment_type =~ /gateway/) {
		# this set allows multiple attempts and can record many grades get all attempts
		my @vList = $db->listSetVersions($user_id, $set_name);
		my @setVersions = $db->getMergedSetVersions(map {[$user_id, $set_name, $_]} @vList);

		# calculate and store grade for each attempt
		my @grades = map {$self->_getGradeRecord($_, $user_id, 1)} @setVersions;
		# set default to the unversioned set. Should be a grade of zero
		# helpful if the user has not created a version yet
		my $bestGrade = $self->_getGradeRecord($set, $user_id, 0);
		foreach my $grade (@grades) {
			if ($grade->{raw_grade} > $bestGrade->{raw_grade}) {
				$bestGrade = $grade;
			}
		}
		return $bestGrade;
	} else {
		# only one grade will be recorded for this set
		return $self->_getGradeRecord($set, $user_id, 0);
	}
}

sub _getGradeRecord
{
	my ($self, $set, $user_id, $isVersioned) = @_;
	my $ce = $self->{ce};
	my $db = $self->{db};

	my $timestamp = formatDateTime(time(), $ce->{siteDefaults}{timezone}, "%Y-%m-%dT%H:%M:%S%z");
	my $activity_progress = 'Initialized';
	# Note: Canvas won't display grades unless `FullyGraded` is sent
	my $grading_progress = 'NotReady';

	my ($status, $total_right, $total) = $self->grade_set($db, $set, $user_id, $isVersioned);
	if (between($set->open_date, $set->due_date)) {
		$grading_progress = 'FullyGraded';
		if ($status == 1) {
			$activity_progress = 'Submitted';
		} else {
			$activity_progress = 'InProgress';
		}
	} elsif (after($set->due_date)) {
		$activity_progress = 'Completed';
		$grading_progress = 'FullyGraded';
	}

	my $grade = {
		set_id => $set->set_id(),
		user_id => $user_id,
		activity_progress => $activity_progress,
		grading_progress => $grading_progress,
		timestamp => $timestamp,
		total_right => $total_right,
		total => $total,
		grade => $self->getGrade($total_right, $total),
		raw_grade => $self->getRawGrade($total_right, $total)
	};
	return $grade;
}

sub _getCourseGradeRecord
{
	my ($self, $user_id, $course_total, $course_total_right) = @_;
	my $ce = $self->{ce};
	my $db = $self->{db};

	my $timestamp = formatDateTime(time(), $ce->{siteDefaults}{timezone}, "%Y-%m-%dT%H:%M:%S%z");
	# no way to know when the course is completed in Webwork by itself
	my $activity_progress = 'InProgress';
	# Note: Canvas won't display grades unless `FullyGraded` is sent
	my $grading_progress = 'FullyGraded';

	my $course_grade = {
		set_id => '/--course_overall--/',
		user_id => $user_id,
		activity_progress => $activity_progress,
		grading_progress => $grading_progress,
		timestamp => $timestamp,
		total_right => $course_total_right,
		total => $course_total,
		grade => $self->getGrade($course_total_right, $course_total),
		raw_grade => $self->getRawGrade($course_total_right, $course_total)
	};
	return $course_grade;
}

sub getGrade
{
	my ($self, $total_right, $total) = @_;
	if ($total <= 0 || $total_right < 0) {
		return sprintf("%.4f", 0);
	} elsif ($total_right > $total) {
		return sprintf("%.4f", 1);
	}
	return sprintf("%.4f", $total_right/$total);
}

sub getRawGrade
{
	my ($self, $total_right, $total) = @_;
	if ($total <= 0 || $total_right < 0) {
		return 0;
	} elsif ($total_right > $total) {
		return 1;
	}
	return $total_right/$total;
}

# Return a hash of grade attributes for user's set. The hash
# is composed of 3 elements:
# status - whether the user has attempted this assignment yet
# total_right - how many points the user got for answering correctly
# total - total number of points possible
sub grade_set
{
	my ($self, $db, $set, $studentName, $setIsVersioned) = @_;

	my $setID = $set->set_id();
	my $total_right = 0;
	my $total = 0;
	my $status = 0;

	my @problemRecords;
	if ( $setIsVersioned ) {
		# use versioned problems instead (assume that each version has the same number of problems.
		@problemRecords = $db->getAllMergedProblemVersions( $studentName, $setID, $set->version_id );
	} else {
		@problemRecords = $db->getAllMergedUserProblems( $studentName, $setID );
	}

	foreach my $problemRecord (@problemRecords) {
		next unless (defined($problemRecord) );

		$status 		  = $problemRecord->status || 0;
		# sanity check that the status (grade) is between 0 and 1
		my $valid_status  = ($status>=0 && $status<=1)? 1 : 0;
		my $probValue     = $problemRecord->value;
		$probValue        = 1 unless defined($probValue) and $probValue ne "";  # FIXME?? set defaults here?
		$total           += $probValue;
		$total_right 	 += $status * $probValue if $valid_status;
	}

	return ($status, $total_right, $total);
}

1;

