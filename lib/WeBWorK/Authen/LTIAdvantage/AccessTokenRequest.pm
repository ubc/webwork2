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

package WeBWorK::Authen::LTIAdvantage::AccessTokenRequest;

=head1 NAME

WeBWorK::Authen::LTIAdvantage::AccessToken::

=cut


use strict;
use warnings;
use WeBWorK::Debug;
use WeBWorK::CGI;
use WeBWorK::Utils qw(grade_set grade_gateway grade_all_sets wwRound);
use HTTP::Request;
use LWP::UserAgent;
use HTML::Entities;
use Data::UUID;
use JSON;
use Date::Format;
use Date::Parse;

use Digest::SHA qw(sha1_base64);
use Crypt::JWT qw(encode_jwt);

use WeBWorK::CourseEnvironment;
use WeBWorK::DB;
use WeBWorK::Debug;
use Data::Dumper;
use WebworkBridge::ExtraLog;

# This package contains utilities for retrieving content membership from the LMS
sub new {
	my ($invocant, $ce, $client_id, $scopes) = @_;
	my $class = ref($invocant) || $invocant;
	my $db = new WeBWorK::DB($ce->{dbLayout});
	my $self = {
		ce => $ce,
		db => $db,
		client_id => $client_id,
		scopes => $scopes,
		error => '',
	};
	bless $self, $class;
	return $self;
}

sub getCachedAccessToken {
	my ($self) = @_;

	my $db = $self->{db};
	my $client_id = $self->{client_id};
	my $scopes = $self->{scopes};

	if($db->existsLTIAccessToken($client_id, $scopes)) {
		my $lti_access_token = $db->getLTIAccessToken($client_id, $scopes);

		my $expires_time = str2time($lti_access_token->expires_at(), "GMT");
		# only return access token if there is enough time to perform longer tasks (assume 10 minutes)
		if ( ($expires_time - (60*10)) > time) {
			return $lti_access_token->access_token();
		}
	}
	return 0;
}

sub cacheAccessToken {
	my ($self, $access_token, $expires_in) = @_;

	my $db = $self->{db};
	my $client_id = $self->{client_id};
	my $scopes = $self->{scopes};
	my $expires_at = time2str("%Y-%m-%d %H:%M:%S", time + $expires_in, "GMT");

	my $lti_access_token;
	my $exists = $db->existsLTIAccessToken($client_id, $scopes);

	if($exists) {
        $lti_access_token = $db->getLTIAccessToken($client_id, $scopes);
    } else {
        $lti_access_token = $db->newLTIAccessToken(
			client_id => $client_id,
			scopes => $scopes
		);
	}

	$lti_access_token->access_token($access_token);
	$lti_access_token->expires_at($expires_at);

	if($exists) {
        $db->putLTIAccessToken($lti_access_token);
    } else {
        $db->addLTIAccessToken($lti_access_token);
	}
}

sub getAccessToken {
	my ($self) = @_;

	my $client_id = $self->{client_id};
	my $scopes = $self->{scopes};
	my $ce = $self->{ce};

	my $extralog = WebworkBridge::ExtraLog->new($ce);

	if (!defined($ce->{bridge}{lti_clients}{$client_id}))
	{
		$self->{error} = "Unknown client_id '$client_id'. ";
		$extralog->logAccessTokenRequest($self->{error});
		debug($self->{error});
		return 0;
	}

	# return access token if exists, hasn't expired, and there is headway to complete longer tasks
	my $cached_access_token = $self->getCachedAccessToken();
	if ($cached_access_token) {
		$extralog->logAccessTokenRequest("Using existing LTI Access Token for client: $client_id on scopes: $scopes");
		debug("Using existing LTI Access Token for client: $client_id on scopes: $scopes");
		return $cached_access_token;
	}

	my $access_token_url = $ce->{bridge}{lti_clients}{$client_id}{oauth2_access_token_url};
	my $tool_private_key = $ce->{bridge}{lti_clients}{$client_id}{tool_private_key};

	$extralog->logAccessTokenRequest("Requesting LTI Access Token for client: $client_id on scopes: $scopes");
	debug("Requesting LTI Access Token for client: $client_id on scopes: $scopes");

	my $request_result = undef;
	my $retry_count = 0;
	while (1) {
		my $ug = new Data::UUID;
		my $uuid = $ug->create_str;
		$uuid =~ s/\-//g;

		my $time = time;
		my $data = {
			iss => $ce->{server_root_url},
			sub => $client_id,
			aud => $access_token_url,
			iat => $time,
			exp => $time + 3600,
			jti => $uuid
		};

		my $jwt = encode_jwt(payload=>$data, alg=>'RS256', key=>\$tool_private_key, extra_headers=>{typ=>"JWT"});

		my $ua = LWP::UserAgent->new();
		my $response = $ua->post($access_token_url, {
			grant_type => encode_entities('client_credentials'),
			client_assertion_type => encode_entities('urn:ietf:params:oauth:client-assertion-type:jwt-bearer'),
			client_assertion => $jwt,
			scope => encode_entities($scopes)
		});

		if($response->is_success()) {
			$request_result = from_json($response->content);
			last;
		} elsif ($response->code eq 403 && $response->content =~ /Rate Limit Exceeded/) {
			my $sleep_seconds = $retry_count + 3;
			$extralog->logAccessTokenRequest("Rate limit Exceeded, sleep for $sleep_seconds seconds");
			debug("Rate limit Exceeded, sleep for $sleep_seconds seconds");
			sleep $sleep_seconds; # wait reties + 3 seconds to try again
		} else {
			$self->{error} = "LTI Access Token Request failed. " .
				"\nStatus: " . $response->status_line .
				"\nRequest URI: " . $response->request->uri .
				"\nRequest Content: " . $response->request->content .
				"\nResponse: " . $response->content;
			$extralog->logAccessTokenRequest($self->{error});
			debug($self->{error});
			return 0;
		}

		$retry_count += 1;
		if ($retry_count >= 10) {
			$self->{error} = "LTI Access Token Request failed. Retry limit exceeded.";
			$extralog->logAccessTokenRequest($self->{error});
			debug($self->{error});
			return 0;
		}
	}

	unless(defined($request_result->{access_token})) {
		$self->{error} = "LTI Access Token Request failed. No Access Token given.";
		$extralog->logAccessTokenRequest($self->{error});
		$extralog->logAccessTokenRequest(Dumper($request_result));
		debug($self->{error});
		debug(Dumper($request_result));
		return 0;
	}

	my $access_token = $request_result->{access_token};
	my $expires_in = $request_result->{expires_in};

	$extralog->logAccessTokenRequest("LTI Access Token request successful for client: $client_id with access token: $access_token");
	debug("LTI Access Token request successful for client: $client_id with access token: $access_token");

	$self->cacheAccessToken($access_token, $expires_in);

	return $access_token;
}

1;

