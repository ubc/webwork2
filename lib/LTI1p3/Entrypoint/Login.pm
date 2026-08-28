package LTI1p3::Entrypoint::Login;
use Mojo::Base 'LTI1p3::Entrypoint', -strict, -signatures, -async_await;

##### Library Imports #####

use Data::Dumper;
use CGI;
use Bytes::Random::Secure::Tiny;
use URI;
use Date::Format;

use WeBWorK::CourseEnvironment;
use WeBWorK::DB;
use WeBWorK::Debug;

use LTI1p3::Importer::Error;

sub accept ($c) {
	if ($c->param("iss") && $c->param("login_hint") && $c->param("lti_message_hint") && $c->param("target_link_uri")) {
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

async sub run ($c) {
	# no course when starting lti, so create a empty course environment
	my $ce = $c->ce(WeBWorK::CourseEnvironment->new({
		webwork_dir => $ENV{WEBWORK_ROOT},
	}));
	my $db = $c->db(new WeBWorK::DB($ce));
	# in case we were sent a CORS request, add appropriate response headers
	$c->_addCorsHeaders($ce);
	# make sure browsers don't cache lti authentication requests
	$c->_addCacheControlHeaders($ce);

	# required
	my $platform_id      = $c->param("iss");
	my $login_hint       = $c->param("login_hint");
	my $lti_message_hint = $c->param("lti_message_hint");
	#my $target_link_uri = $c->param("target_link_uri");

	my $rng = Bytes::Random::Secure::Tiny->new;
	# We'll generate a 64 character cryptographically secure string and split
	# it in half, one half for state and one half for nonce. The entire 64
	# character string should be stored as a single entry in the nonce table.
	my $bag      = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_';
	my $nonceKey = $rng->string_from($bag, 64);
	my $state    = substr($nonceKey, 0, 32);
	my $nonce    = substr($nonceKey, 32);

	my $oidc_auth_url = "";
	foreach my $client_id (keys %{ $ce->{lti_advantage}{lti_clients} }) {
		if (defined($ce->{lti_advantage}{lti_clients}{$client_id}{platform_id})
			&& defined($ce->{lti_advantage}{lti_clients}{$client_id}{oidc_auth_url})
			&& $ce->{lti_advantage}{lti_clients}{$client_id}{platform_id} eq $platform_id)
		{
			$oidc_auth_url = $ce->{lti_advantage}{lti_clients}{$client_id}{oidc_auth_url};
			debug("oidc_auth_url is $oidc_auth_url for platform $platform_id with client_id $client_id.");
			last;
		}
	}

	if ($oidc_auth_url eq "") {
		debug("Could not find a oidc_auth_url for platform $platform_id.");
		return $c->reply->exception(
			$c->maketext(
				"Unfortunately, the LTI login failed. This might be a temporary condition. If it persists, please mail an error report with the time that the error occurred."
			)
		)->rendered(400);
	}

	# store the nonce
	my $exists = $db->existsLTINonce($platform_id, $nonceKey);

	if ($exists) {
		debug("Nonce already exists for $platform_id. Nonce: $nonce");
		return $c->reply->exception(
			$c->maketext(
				"Unfortunately, the LTI login failed. This might be a temporary condition. If it persists, please mail an error report with the time that the error occurred."
			)
		)->rendered(400);
	} else {
		my $expires_at = time2str("%Y-%m-%d %H:%M:%S", time + (15 * 60), "GMT");
		my $lti_nonce  = $db->newLTINonce(
			platform_id => $platform_id,
			nonce       => $nonceKey,
			expires_at  => $expires_at,
			was_used    => 0
		);
		$db->addLTINonce($lti_nonce);
	}

	my $full_url = URI->new($oidc_auth_url);
	$full_url->query_form({
		'scope'         => 'openid',                                               # OIDC Scope
		'response_type' => 'id_token',                                             # OIDC response is always an id token
		'response_mode' => 'form_post',                                            # OIDC response is always a form post
		'prompt'        => 'none',                                                 # Don't prompt user on redirect
		'client_id'     => $c->param("client_id"),                                 # Registered client id
		'redirect_uri'  => $ENV{WEBWORK_ROOT_URL} . $c->url_for('lti1p3redirect'), # next step url
		'state'         => $state,                                                 # State to identify browser session
		'nonce'         => $nonce,                                                 # Prevent replay attacks
		'login_hint'       => $login_hint,         # Login hint to identify platform session
		'lti_message_hint' => $lti_message_hint    # LTI message hint to identify LTI context within the platform
	});

	$c->redirect_to($full_url);
	return 0;
}

sub getAuthenModule {
	my $self = shift;
	return "";
}

1;
