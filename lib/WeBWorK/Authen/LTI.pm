################################################################################
# WeBWorK Online Homework Delivery System
# Copyright © 2000-2007 The WeBWorK Project, http://openwebwork.sf.net/
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

package WeBWorK::Authen::LTI;
use base qw/WeBWorK::Authen/;

use strict;
use warnings;
use WeBWorK::Debug;
use Net::OAuth;
use Encode qw(decode);

sub get_credentials {
	my $self = shift;
	my $r = $self->{r};
	my $ce = $r->ce;

	# don't allow guest login using LTI
	if ($r->param("login_practice_user")) {
		$self->{log_error} = "no guest logins are available";
		$self->{error} = "No guest logins are available. Please try again in a few minutes.";
		return 0;
	}

	debug(("-" x 80) . "\n");
	debug("Start LTI Single Sign On Authentication\n");
	debug("Checking for required LTI parameters\n");

	my $msgheader = "Missing or incorrect LTI field:";
	if ($r->param("lti_message_type") ne 'basic-lti-launch-request')
	{ # required, has to be 'basic-lti-launch-request'
		$self->{log_error} = "$msgheader Unknown lti_message_type";
		$self->{error} = "$msgheader Unknown lti_message_type";
		return 0;
	}
	if (!defined $r->param("lti_version")  || 
		$r->param("lti_version")ne 'LTI-1p0')
	{ # required, has to be 'LTI-1p0'
		$self->{log_error} = "$msgheader Unknown lti_version";
		$self->{error} = "$msgheader Unknown lti_version";
		return 0;
	}
	if (!defined $r->param("resource_link_id")) 
	{ # required
		$self->{log_error} = "$msgheader Undefined resource_link_id";
		$self->{error} = "$msgheader Undefined resource_link_id";
		return 0;
	}

	# verify user_id
	my $user_id;
	foreach my $field_name (@{$ce->{bridge}{user_identifier_fields}})
	{
		if (defined($r->param($field_name)) && $r->param($field_name) ne '') {
			$user_id = $r->param($field_name);
			last;
		}
	}
	if (!defined($user_id))
	{
		$self->{log_error} = "$msgheader Undefined user identifiers ".$r->ce->{bridge}{user_identifier_fields};
		$self->{error} = "$msgheader Undefined user identifiers ".$r->ce->{bridge}{user_identifier_fields};
		return 0;
	}
	# set user id for the Authen module (inherited methods in particular)
	if ($r->param("ubc_auto_update"))
	{ # Keep auto-update from logging real users out
		$self->{user_id} = "admin";
	}
	else
	{
		$self->{user_id} = $user_id;
	}

	debug("Checking for required OAuth parameters\n");

	$msgheader = "Missing or incorrect OAuth field:";
	if (!defined $r->param("oauth_consumer_key")) 
	{ # required
		$self->{log_error} = "$msgheader Undefined oauth_consumer_key";
		$self->{error} = "$msgheader Undefined oauth_consumer_key";
		return 0;
	}
	if (!defined $r->param("oauth_signature_method")) 
	{ # required
		$self->{log_error} = "$msgheader Undefined oauth_signature_method";
		$self->{error} = "$msgheader Undefined oauth_signature_method";
		return 0;
	}
	if (!defined $r->param("oauth_timestamp")) 
	{ # required
		$self->{log_error} = "$msgheader Undefined oauth_timestamp";
		$self->{error} = "$msgheader Undefined oauth_timestamp";
		return 0;
	}
	if (!defined $r->param("oauth_nonce")) 
	{ # required
		$self->{log_error} = "$msgheader Undefined oauth_nonce";
		$self->{error} = "$msgheader Undefined oauth_nonce";
		return 0;
	}
	if (!defined $r->param("oauth_version")) 
	{ # required
		$self->{log_error} = "$msgheader Undefined oauth_version";
		$self->{error} = "$msgheader Undefined oauth_version";
		return 0;
	}
	if (!defined $r->param("oauth_signature")) 
	{ # required
		$self->{log_error} = "$msgheader Undefined oauth_signature";
		$self->{error} = "$msgheader Undefined oauth_signature";
		return 0;
	}
	if (!defined $r->param("oauth_callback")) 
	{ # required
		$self->{log_error} = "$msgheader Undefined oauth_callback";
		$self->{error} = "$msgheader Undefined oauth_callback";
		return 0;
	}

	debug("All required parameters found!\n");
    $self->{login_type} = "normal";
    $self -> {credential_source} = "LTI";
	
	return 1;
}

sub authenticate {
	my $self = shift;
	my $r = $self->{r};
	my $ce = $r->ce;

	debug("Starting OAuth verification\n");
	# OAuth verification
	# convert the param object into a hash for passing into OAuth object
	my %hash_params = ();
	foreach my $key ($r->param) 
	{
		my $vals = $r->param($key);
		# let's hope incoming text is UTF-8 or signature calculation will fail
		$key = decode('UTF-8', $key); 
		$vals = decode('UTF-8', $vals); 
		$hash_params{$key} = $vals;
	}
	my $key = $r->param('oauth_consumer_key');
	if (!defined($r->ce->{bridge}{lti_secrets}{$key}))
	{
		$self->{log_error} = "Unable to find a secret key that matches '$key'.";
		$self->{error} = "Unable to find a secret key that matches '$key'.";
		return 0;
	}
	# need to make sure request_urls are terminated with /
	my $request_url = $ce->{server_root_url} . $ce->{webwork_url};
	if (substr($request_url, -1, 1) ne "/")
	{
		$request_url .= "/";
	}
	debug("Assuming the launch URL is ". $request_url);
	my $request = Net::OAuth->request("request token")->from_hash(
		\%hash_params,
		request_url => $request_url,
		request_method => 'POST',
		consumer_secret => $ce->{bridge}{lti_secrets}{$key},
		protocol_version => Net::OAuth::PROTOCOL_VERSION_1_0A,
	);
	if (!$request->verify())
	{ 
		$self->{log_error} = "Failed OAuth verification";
		$self->{error} = "Failed OAuth verification";
		return 0;
	}
	debug("LTI OAuth Verification Successful");
	debug(("-" x 80) . "\n");
	return 1;
}

1;
