################################################################################
# WeBWorK Online Homework Delivery System
# Copyright &copy; 2000-2007 The WeBWorK Project, http://openwebwork.sf.net/
# $CVSHeader: webwork2/lib/WeBWorK/Authen/Moodle.pm,v 1.14 2007/02/14 19:08:46 gage Exp $
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

package WeBWorK::Authen::LTIAdvantage;
use base qw/WeBWorK::Authen/;

use strict;
use warnings;
use WeBWorK::Debug;
use Net::OAuth;
use JSON::Validator qw(validate_json);
use Crypt::JWT qw(decode_jwt);
use LWP::UserAgent;
use WeBWorK::Authen::LTIAdvantage::LTILaunchParser;
use File::Basename;
use Data::Dumper;
use WeBWorK::Cookie;
use mod_perl;
use JSON;
use Date::Format;
use Date::Parse;

use constant MP2 => ( exists $ENV{MOD_PERL_API_VERSION} and $ENV{MOD_PERL_API_VERSION} >= 2 );

sub verify_normal_user {
	my $self = shift;
	my $ret = $self->SUPER::verify_normal_user(@_);

	if ($ret and $self->{initial_login}) {
		$self->prevent_replay();
	}

	return $ret;
}

sub get_credentials {
	my $self = shift;
	my $r = $self->{r};
	my $ce = $r->ce;

	# don't allow guest login using LTI
	if ($r->param("login_practice_user")) {
		$self->{log_error} = "no guest logins are available";
		$self->{error} = "No guest logins are available.";
		debug($self->{log_error});
		return 0;
	}

	debug(("-" x 80) . "\n");
	debug("Start LTI Single Sign On Authentication\n");
	debug("Checking for required LTI parameters\n");

	if (!defined($r->param("id_token"))) {
		$self->{log_error} = "Unable to find id_token param.";
		$self->{error} = "Unable to find id_token param.";
		debug($self->{log_error});
		return 0;
	}

	#disable password login
	$self->{external_auth} = 1;

	my $parser = WeBWorK::Authen::LTIAdvantage::LTILaunchParser->new($ce, $r->param("id_token"));
	if ($parser->{error}) {
		$self->{log_error} = "Could not parse LTI launch. Error: \n".$parser->{error};
		$self->{error} = "Could not parse LTI launch. Error: \n".$parser->{error};
		debug($self->{log_error});
		return 0;
	}

	my $platform_id = $parser->get_param("iss");
	if (!defined($platform_id)) {
		$self->{log_error} = "Unable to find platform id (iss).";
		$self->{error} = "Unable to find platform id (iss).";
		debug($self->{log_error});
		return 0;
	}

	my $client_id = $parser->get_param("aud");
	if (!defined($client_id)) {
		$self->{log_error} = "Unable to find client id (aud).";
		$self->{error} = "Unable to find client id (aud).";
		debug($self->{log_error});
		return 0;
	}

	my $deployment_id = $parser->get_claim("deployment_id");
	if (!defined($deployment_id)) {
		$self->{log_error} = "Unable to find deployment id.";
		$self->{error} = "Unable to find deployment id.";
		debug($self->{log_error});
		return 0;
	}

	my $message_type = $parser->get_claim("message_type");
	if (!defined($message_type) || $message_type ne 'LtiResourceLinkRequest') {
		$self->{log_error} = "Invalid or missing LTI message type.";
		$self->{error} = "Invalid or missing LTI message type.";
		debug($self->{log_error});
		return 0;
	}

	my $version = $parser->get_claim("version");

	my $dirname = dirname(__FILE__);
	my $schema = $dirname."/LTIAdvantage/schema/1.3.0/LtiResourceLinkRequest.json";
	if ($version ne "1.3.0") {
		# for future, load different schemas as needed
		# $schema = $dirname."/LTIAdvantage/schema/1.3.0/LtiResourceLinkRequest.json";

		# error out
		$self->{log_error} = "Invalid LTI Version. Supported Version are: 1.3.0";
		$self->{error} = "Invalid LTI Version. Supported Version are: 1.3.0";
		debug($self->{log_error});
		return 0;
	}

	my @errors = validate_json($parser->{data}, $schema);
	# debug(Dumper(@errors));
	# debug(Dumper($parser->{data}));
	if (@errors) {
		$self->{log_error} = "JSON Validation Errors:\n" . join("\n", map { "* [" . $_->{'path'} . "] " . $_->{'message'} } @errors);
		$self->{error} = "JSON Validation Errors:<br>" . join("<br>", map { "* [" . $_->{'path'} . "] " . $_->{'message'} } @errors);
		debug($self->{log_error});
		return 0;
	}

	# check if valid client
	if (!defined($ce->{bridge}{lti_clients}{$client_id}) ||
		!defined($ce->{bridge}{lti_clients}{$client_id}))
	{
		$self->{log_error} = "Unable to find a client id that matches '$client_id'.";
		$self->{error} = "Unable to find a client id that matches '$client_id'.";
		debug($self->{log_error});
		return 0;
	}

	# check if valid platform
	if (!defined($ce->{bridge}{lti_clients}{$client_id}{platform_id}) ||
		$ce->{bridge}{lti_clients}{$client_id}{platform_id} ne $platform_id)
	{
		$self->{log_error} = "Unable to find a platform id that matches '$platform_id'.";
		$self->{error} = "Unable to find a platform id that matches '$platform_id'.";
		debug($self->{log_error});
		return 0;
	}

	# check if public key
	if (!defined($ce->{bridge}{lti_clients}{$client_id}) ||
		!defined($ce->{bridge}{lti_clients}{$client_id}{platform_security_jwks_url}))
	{
		$self->{log_error} = "Unable to find a security jwks url for client '$client_id'.";
		$self->{error} = "Unable to find a security jwks url for client '$client_id'.";
		debug($self->{log_error});
		return 0;
	}

	# verify user_id
	my $user_id = $parser->get_user_identifier();
	if (!$user_id) {
		$self->{log_error} = "Missing or incorrect JWT Token field: Undefined user identifier for ".$client_id;
		$self->{error} = "Missing or incorrect JWT Token field: Undefined user identifier for ".$client_id;
		debug($self->{log_error});
		return 0;
	}

	$self->{user_id} = $user_id;
    $self->{login_type} = "normal";
    $self->{credential_source} = "LTIAdvantage";
	$self->{session_key} = undef;

	# resuse session_key if possible
	my ($cookieUser, $cookieKey, $cookieTimeStamp) = $self->fetchCookie;
	if (defined($cookieUser) && defined($cookieKey)) {
		if ($cookieUser eq $user_id) {
			$self->{session_key} = $cookieKey;
		}
	}

	return 1;
}

sub prevent_replay {
	my $self = shift;
	my $r = $self->{r};
	my $ce = $r->ce;
	my $db = $r->db;

	my $parser = WeBWorK::Authen::LTIAdvantage::LTILaunchParser->new($ce, $r->param("id_token"));
	my $platform_id = $parser->get_param("iss");
	my $nonce = $parser->get_param("nonce");

	my $exists = $db->existsLTINonce($platform_id, $nonce);
	if ($exists) {
		my $lti_nonce = $db->getLTINonce($platform_id, $nonce);
		$lti_nonce->was_used(1);
		$db->putLTINonce($lti_nonce);
	}
}

sub authenticate {
	my $self = shift;
	my $r = $self->{r};
	my $ce = $r->ce;
	my $db = $r->db;

	debug("Starting OAuth verification\n");

	if (!defined($r->param("id_token"))) {
		$self->{log_error} = "Unable to find id_token param.";
		$self->{error} = "Unable to find id_token param.";
		debug($self->{log_error});
		return 0;
	}

	if (!defined($r->param("state"))) {
		$self->{log_error} = "Unable to find state param.";
		$self->{error} = "Unable to find state param.";
		debug($self->{log_error});
		return 0;
	}

	my $parser = WeBWorK::Authen::LTIAdvantage::LTILaunchParser->new($ce, $r->param("id_token"));
	if ($parser->{error}) {
		$self->{log_error} = "Could not parse LTI launch. Error: \n".$parser->{error};
		$self->{error} = "Could not parse LTI launch. Error: \n".$parser->{error};
		debug($self->{log_error});
		return 0;
	}

	my $client_id = $parser->get_param("aud");
	if (!defined($ce->{bridge}{lti_clients}{$client_id}) || !defined($ce->{bridge}{lti_clients}{$client_id}{platform_security_jwks_url})) {
		$self->{log_error} = "Unable to find a security jwks url for client '$client_id'.";
		$self->{error} = "Unable to find a security jwks url for client '$client_id'.";
		debug($self->{log_error});
		return 0;
	}


	my $ua = LWP::UserAgent->new();
	$ua->default_header( 'Accept' => 'application/json' );

	my $jwt_keys_url = $ce->{bridge}{lti_clients}{$client_id}{platform_security_jwks_url};
	my $jwt_keys = undef;
	my $retry_count = 0;
	while (1) {
		my $response = $ua->get($jwt_keys_url);
		debug('$response: '.Dumper($response));

		if($response->is_success()) {
			$jwt_keys = from_json($response->content);
			last;
		} elsif ($response->code eq 403 && $response->content =~ /Rate Limit Exceeded/) {
			my $sleep_seconds = $retry_count + 3;
			debug("Rate limit Exceeded, sleep for $sleep_seconds seconds");
			sleep $sleep_seconds; # wait reties + 3 seconds to try again
		} else {
			debug($response->status_line);
			$self->{log_error} = "Failed to fetch JWT keys from $jwt_keys_url.";
			$self->{error} = "Failed to fetch JWT keys from $jwt_keys_url.";
			return 0;
		}

		$retry_count += 1;
		if ($retry_count >= 10) {
			$self->{log_error} = "Failed to fetch JWT keys from $jwt_keys_url. Retry count exceeded.";
			$self->{error} = "Failed to fetch JWT keys from $jwt_keys_url. Retry count exceeded.";
			debug($self->{error});
			return 0;
		}
	}

	if (!decode_jwt(token => $r->param("id_token"), kid_keys => $jwt_keys )) {
		$self->{log_error} = "Failed JWT verification";
		$self->{error} = "Failed JWT verification";
		debug($self->{log_error});
		return 0;
	}

	# validate nonce
	my %cookies = WeBWorK::Cookie->fetch( MP2 ? $r : () );
	my $cookie = $cookies{$r->param("state")};
	if (!$cookie) {
		$self->{log_error} = "Could not find LTI launch cookie: ".$r->param("state");
		$self->{error} = "Could not find LTI launch cookie: ".$r->param("state");
		debug($self->{log_error});
		return 0;
	}

	my $platform_id = $parser->get_param("iss");
	my $nonce = $parser->get_param("nonce");
	my $expected_nonce = $cookie->value;
	if (!defined($expected_nonce) || $expected_nonce ne $nonce) {
		$self->{log_error} = "Invalid nonce provided. Expected: $expected_nonce Got: $nonce";
		$self->{error} = "Invalid nonce provided. Expected: $expected_nonce Got: $nonce";
		debug($self->{log_error});
		return 0;
	}

	my $exists = $db->existsLTINonce($platform_id, $nonce);
	if (!$exists) {
		$self->{log_error} = "Invalid nonce provided. Doesn't exist in lti_nonces table";
		$self->{error} = "Invalid nonce provided. Doesn't exist in lti_nonces table";
		debug($self->{log_error});
		return 0;
	}
	my $lti_nonce = $db->getLTINonce($platform_id, $nonce);
	if ($lti_nonce->was_used()) {
		$self->{log_error} = "Invalid nonce provided. Was already used.";
		$self->{error} = "Invalid nonce provided. Was already used.";
		debug($self->{log_error});
		return 0;
	}
	my $lti_nonce_expires_time = str2time($lti_nonce->expires_at(), "GMT");
	if ( $lti_nonce_expires_time < time) {
		my $expires_at = time2str("%Y-%m-%d %H:%M:%S %Z", $lti_nonce_expires_time, "GMT");
		my $currently = time2str("%Y-%m-%d %H:%M:%S %Z", time, "GMT");
		$self->{log_error} = "Invalid nonce provided. Expired at: $expires_at Currently: $currently";
		$self->{error} = "Invalid nonce provided. Expired at: $expires_at Currently: $currently";
		debug($self->{log_error});
		return 0;
	}

	debug("LTI OAuth Verification Successful");
	debug(("-" x 80) . "\n");
	return 1;
}

1;
