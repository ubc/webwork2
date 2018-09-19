package WebworkBridge::Bridges::LTILoginBridge;
use base qw(WebworkBridge::Bridge);

##### Library Imports #####
use strict;
use warnings;

use Data::Dumper;
use CGI;
use Data::UUID;
use URI;
use Date::Format;

use WeBWorK::CourseEnvironment;
use WeBWorK::DB;
use WeBWorK::Debug;

use WebworkBridge::Importer::Error;
use WeBWorK::Authen::LTIAdvantage::LTILaunchParser;

use WeBWorK::Authen::LTIAdvantage;
use WeBWorK::Authen::LTIAdvantage::NamesAndRoleService;
use WeBWorK::Authen::LTIAdvantage::AssignmentAndGradeService;

# Constructor
sub new
{
	my ($class, $r) = @_;
	my $self = $class->SUPER::new($r);
	my $ce = $r->ce;
	$self->{parser} = WeBWorK::Authen::LTIAdvantage::LTILaunchParser->new($ce, $r->param("id_token"));
	bless $self, $class;
	return $self;
}

sub accept
{
	my $self = shift;
	my $r = $self->{r};
	if ($r->param("iss") && $r->param("login_hint") && $r->param("lti_message_hint") && $r->param("target_link_uri")) {
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

	# required
	my $platform_id = $r->param("iss");
	my $login_hint = $r->param("login_hint");
	my $lti_message_hint = $r->param("lti_message_hint");
	#my $target_link_uri = $r->param("target_link_uri");

	my $ug = new Data::UUID;
	my $nonce = $ug->create_str;
	my $state = "state.$nonce";
	$state =~ s/\-/\./g; # replace - with . for valid cookies

	# valid until 15 minutes from now
	my $expires = time2str("%a, %d-%h-%Y %H:%M:%S %Z", time+(15*60), "GMT");
	my $cookie = WeBWorK::Cookie->new($r,
		-name    => $state,
 		-value   => $nonce,
		-path    => $ce->{webworkURLRoot},
		-expires => $expires,
		-secure  => 0,
		-domain  => $r->hostname
	);

	my $oidc_auth_url = "";
	foreach my $client_id (keys %{$ce->{bridge}{lti_clients}}) {
		if (defined($ce->{bridge}{lti_clients}{$client_id}{platform_id}) &&
		    defined($ce->{bridge}{lti_clients}{$client_id}{oidc_auth_url}) &&
			$ce->{bridge}{lti_clients}{$client_id}{platform_id} eq $platform_id)
		{
			$oidc_auth_url = $ce->{bridge}{lti_clients}{$client_id}{oidc_auth_url};
			debug("oidc_auth_url is $oidc_auth_url for platform $platform_id with client_id $client_id.");
			last;
		}
	}

	if ($oidc_auth_url eq "") {
		debug("Could not find a oidc_auth_url for platform $platform_id.");
		my $error_message = CGI::h2("LTI Login Failed");
		$error_message .= CGI::p("Unfortunately, the LTI login failed. This might be a temporary condition. If it persists, please mail an error report with the time that the error.");
		return $error_message;
	}

	# store the nonce
	my $lti_nonce;
	my $exists = $db->existsLTINonce($platform_id, $nonce);

	if($exists) {
		debug("Nonce already exists for $platform_id. Nonce: $nonce");
		my $error_message = CGI::h2("LTI Login Failed");
		$error_message .= CGI::p("Unfortunately, the LTI login failed. This might be a temporary condition. If it persists, please mail an error report with the time that the error.");
		return $error_message;
    } else {
		my $expires_at = time2str("%Y-%m-%d %H:%M:%S", time+(15*60), "GMT");
        $lti_nonce = $db->newLTINonce(
			platform_id => $platform_id,
			nonce => $nonce,
			expires_at => $expires_at,
			was_used => 0
		);
        $db->addLTINonce($lti_nonce);
	}

	my $full_url = URI->new($oidc_auth_url);
	$full_url->query_form({
		'scope' => 'openid',  # OIDC Scope
		'response_type' => 'id_token',  # OIDC response is always an id token
		'response_mode' => 'form_post',  # OIDC response is always a form post
		'prompt' => 'none',  # Don't prompt user on redirect
		'client_id' => $r->param("client_id"),  # Registered client id
		'redirect_uri' => $r->param("target_link_uri"),  # URL to return to after login
		'state' => $state,  # State to identify browser session
		'nonce' => $nonce,  # Prevent replay attacks
		'login_hint' => $login_hint,  # Login hint to identify platform session
		'lti_message_hint' => $lti_message_hint  # LTI message hint to identify LTI context within the platform
	});

	my $q = CGI->new();
	print $q->redirect( -uri => "$full_url", -cookie => $cookie->as_string );
	return 0;
}

sub getAuthenModule
{
	my $self = shift;
	return "";
}

1;
