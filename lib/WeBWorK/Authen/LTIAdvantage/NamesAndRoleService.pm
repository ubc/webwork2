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

package WeBWorK::Authen::LTIAdvantage::NamesAndRoleService;

=head1 NAME

WeBWorK::Authen::LTIAdvantage::NamesAndRoleService

=cut


use strict;
use warnings;
use WeBWorK::Debug;
use WeBWorK::CGI;
use WeBWorK::Utils qw(grade_set grade_gateway grade_all_sets wwRound);
use Net::OAuth;
use HTTP::Request;
use LWP::UserAgent;
use Digest::SHA qw(sha1_base64);
use JSON;

use WeBWorK::CourseEnvironment;
use WeBWorK::DB;
use WeBWorK::Debug;
use Data::Dumper;

use WeBWorK::Authen::LTIAdvantage::AccessTokenRequest;
use WebworkBridge::ExtraLog;
use WeBWorK::Authen::LTIAdvantage::LTINamesAndRoleServiceParser;

#$WeBWorK::Debug::Enabled = 1;

# This package is used retrieving content membership from the LMS
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

sub getAllNamesAndRole {
	my $self = shift;
	my $ce = $self->{ce};
	my $db = $self->{db};

	my $course_id = $ce->{courseName};
	my $extralog = WebworkBridge::ExtraLog->new($ce);
	my @lti_contexts = $db->getLTIContextsByCourseID($course_id);
	my @lti_resource_links = $db->getAllLTIResourceLinks();

	# Step 1: make a request for each context (use first resource link id)
	my @membership_requests = ();
	foreach my $lti_context (@lti_contexts) {
		my $client_id = $lti_context->client_id();
		my $context_id = $lti_context->context_id();
		my $context_memberships_url = $lti_context->context_memberships_url();
		next if !$context_memberships_url;

		my @lti_context_resource_links = grep {$_->context_id() eq $context_id} @lti_resource_links;
		next if scalar(@lti_context_resource_links) == 0;
		my $lti_resource_link = $lti_context_resource_links[0];

		# Canvas HACK: if context_id == resource_link_id then resource link will have membership for entire class
		# (use these first if available)
		my @canvas_hack_resource_links = grep {$_->resource_link_id() eq $context_id} @lti_context_resource_links;
		if (scalar(@canvas_hack_resource_links) > 0) {
			$lti_resource_link = $canvas_hack_resource_links[0];
		}

		my $request = {
			'client_id' => $client_id,
			'context_id' => $context_id,
			'resource_link_id' => $lti_resource_link->resource_link_id(),
			'context_memberships_url' => $context_memberships_url,
		};
		push(@membership_requests, $request);
	}

	if (scalar(@membership_requests) == 0) {
		$self->{error} = "No valid Names and Roles requests.";
		$extralog->logNRPSRequest($self->{error});
		return 0;
	}

	# Step 2: Fetch membership for each client for the context (merging results)

	# use a hash to prevent multiple instances of the same user
	my $users = {};
	foreach my $membership_request (@membership_requests) {
		my $members = $self->getNamesAndRole(
			$membership_request->{'client_id'},
			$membership_request->{'context_id'},
			$membership_request->{'resource_link_id'},
			$membership_request->{'context_memberships_url'},
		);

		# return error instead?
		next if (!$members || scalar(@{$members}) == 0);

		# merge memberships. If user exists in multiple places, use first result only
		foreach my $member (@{$members}) {
			unless(exists $users->{$member->{'loginid'}}) {
				$users->{$member->{'loginid'}} = $member;
			}
		}
	}
	my @return_value = values %{$users};

	return \@return_value;
}

sub getNamesAndRole {
	my ($self, $client_id, $context_id, $resource_link_id, $context_memberships_url) = @_;

	my $ce = $self->{ce};

	my $extralog = WebworkBridge::ExtraLog->new($ce);
	$extralog->logNRPSRequest("Beginning Names And Roles Service request for client: $client_id on context: $context_id with membership url: $context_memberships_url");

	if (!defined($ce->{bridge}{lti_clients}{$client_id}))
	{
		$self->{error} = "Unknown client_id '$client_id'";
		$extralog->logNRPSRequest($self->{error});
		return 0;
	}

	my $scopes = "https://purl.imsglobal.org/spec/lti-nrps/scope/contextmembership.readonly";
	my $lti_access_token_request = WeBWorK::Authen::LTIAdvantage::AccessTokenRequest->new($ce, $client_id, $scopes);
	my $access_token = $lti_access_token_request->getAccessToken();
	unless ($access_token) {
		$self->{error} = "Names And Roles Service request failed, unable to get an access token for scopes: $scopes";
		$extralog->logNRPSRequest($self->{error});
		return 0;
	}

	my @users = ();
	my $request_url = $context_memberships_url;
	if ($resource_link_id) {
		if ($request_url =~ /\?/) {
			$request_url = $request_url."&rlid=".$resource_link_id
		} else {
			$request_url = $request_url."?rlid=".$resource_link_id
		}
	}
	while (1) {
		$extralog->logNRPSRequest("Beginning Names And Roles Service request for url: $request_url");
		debug("Beginning Names And Roles Service request for url: $request_url");

		my $ua = LWP::UserAgent->new();
		$ua->default_header( 'Accept' => 'application/vnd.ims.lis.v2.membershipcontainer+json' );
		$ua->default_header( 'Authorization' => "Bearer $access_token");
		my $res = $ua->get($request_url);

		if ($res->is_success)
		{
			my $data = from_json($res->content);

			$extralog->logNRPSRequest("Names And Roles Service request successful: \n" . Dumper($data) . "\n");
			# debug("Names And Roles Service request successful! \n" . Dumper($data). "\n");

			my $parser = WeBWorK::Authen::LTIAdvantage::LTINamesAndRoleServiceParser->new($client_id, $ce, $data);
			my @membership = $parser->get_members();

			if (scalar(@membership) == 0) {
				$self->{error} = "Names And Roles Service did not return any users.";
				$extralog->logNRPSRequest($self->{error});
				return 0;
			}
			push(@users, @membership);

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
					$request_url = $next_request_url;
					next;
				}
			}
			last;
		} else {
			$self->{error} = "Names And Roles Service request failed. " . $res->status_line;
			$extralog->logNRPSRequest($self->{error});
			debug($self->{error});
			return 0;
		}
	}

	return \@users;
}

1;

