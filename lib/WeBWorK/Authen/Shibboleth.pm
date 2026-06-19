package WeBWorK::Authen::Shibboleth;
use Mojo::Base 'WeBWorK::Authen', -signatures;

=head1 NAME

WeBWorK::Authen::Shibboleth - Authentication plug in for Shibboleth.

to use: include in localOverrides.conf or course.conf
  $authen{user_module} = "WeBWorK::Authen::Shibboleth";
and add /webwork2/courseName as a Shibboleth Protected
Location or enable lazy session.

if $c->ce->{shiboff} is set for a course, authentication reverts
to standard WeBWorK authentication.

add the following to localOverrides.conf to setup the Shibboleth

$shibboleth{login_script} = "/Shibboleth.sso/Login"; # login handler
$shibboleth{logout_script} = "/Shibboleth.sso/Logout?return=".$server_root_url.$webwork_url; # return URL after logout
$shibboleth{session_header} = "Shib-Session-ID"; # the header to identify if there is an existing shibboleth session
$shibboleth{manage_session_timeout} = 1; # allow shib to manage session time instead of webwork
$shibboleth{hash_user_id_method} = "MD5"; # possible values none, MD5. Use it when you want to hide real user_ids from showing in url.
$shibboleth{hash_user_id_salt} = ""; # salt for hash function
#define the attributes that we should look for user_id from
$shibboleth{attributes} = [
	'username',
	'studentNumber',
	'loginName',
];

=cut

use Digest;

use WeBWorK::Debug qw(debug);

sub request_has_data_for_this_verification_module ($self) {
	my $c = $self->{c};

	# Skip if shiboff is set in the course environment or the bypassShib param is set.
	if ($c->ce->{shiboff} || ($c->ce->{shibboleth}{bypass_query} && $c->param($c->ce->{shibboleth}{bypass_query}))) {
		debug('Shibboleth authen module bypass detected. Going to next authentication module.');
		return 0;
	}

	return 1;
}

sub get_credentials ($self) {
	my $c  = $self->{c};
	my $ce = $c->ce;
	my $db = $c->db;

	$c->stash(disable_cookies => 1);
	$self->{external_auth} = 1;

	debug('Checking for shibboleth authentication headers.');

	my $user_id;
	$user_id = $c->req->headers->header($ce->{shibboleth}{mapping}{user_id}) if $ce->{shibboleth}{mapping}{user_id};

	if (defined $user_id && $user_id ne '') {
		debug("Got shibboleth header ($ce->{shibboleth}{mapping}{user_id}) and user_id ($user_id)");

	if ( defined ($ENV{$ce->{shibboleth}{session_header}})) {
		debug('Got shib header and looking for user_id');
		# loop through all attributes to find the one mapped to user_id
		foreach (@{$ce->{shibboleth}{attributes}}) {
			my $key = $_;
			if (defined( $ENV{$key} ) ) {
				my $user_id;
				# if we need hash the user_id
				if ( defined ($ce->{shibboleth}{hash_user_id_method}) &&
						$ce->{shibboleth}{hash_user_id_method} ne "none" &&
						$ce->{shibboleth}{hash_user_id_method} ne "" ) {
					use Digest;
					my $digest  = Digest->new($ce->{shibboleth}{hash_user_id_method});
					$digest->add($ENV{$key} . ( defined $ce->{shibboleth}{hash_user_id_salt} ? $ce->{shibboleth}{hash_user_id_salt} : ""));
					$user_id = $digest->hexdigest;
				} else {
					$user_id = $ENV{$key};
				}

				# got one match, login user
				if ($db->getUser($user_id)) {
					debug("Got user_id $user_id from shib attribute $key");
					$self->{'user_id'} = $user_id;
					$self->{c}->param("user", $user_id);
					$self->{session_key} = undef;

					# reuse db session_key if still valid (prevent new tab issue)
					my $Key = $db->getKey($user_id);
					if (defined($Key)) {
						if (time <= $Key->timestamp()+$ce->{sessionKeyTimeout}) {
							$self->{session_key} = $Key->key;
						}
					}
					$self->{login_type} = "normal";
					$self->{credential_source} = "params";
					$self->{password} = 1;
					return 1;
				}
			}
		}

		# no match, login failed
		if (!defined($self->{'user_id'})) {
			$self->{log_error} = "Access Denied.";
			$self->{error} = "Access Denied.";
			return 0;
		}
	}

	debug('Unable to obtain user id from Shibboleth header.');
	$self->{redirect} = $ce->{shibboleth}{login_script} . '?target=' . $c->url_for->to_abs;
	$c->redirect_to($self->{redirect});
	return 0;
}

sub checkPassword {
	my ($self, @args) = @_;

	if ($self->{c}->ce->{shiboff} || $self->{c}->param('bypassShib')) {
		return $self->SUPER::checkPassword( @args );
	} else {
		# this is easy; if we're here at all, we've authenticated
		# through shib
		return 1;
	}
}

sub logout_user ($self) {
	$self->{redirect} = $self->{c}->ce->{shibboleth}{logout_script};
	return;
}

sub check_session ($self, $userID, $possibleKey, $updateTimestamp) {
	my $ce = $self->{c}->ce;
	my $db = $self->{c}->db;

	my $Key = $db->getKey($userID);
	return 0 unless defined $Key;

	# This is filled in just in case it is needed somewhere, but is not used in the Shibboleth authentication process.
	$self->{session_key} = $Key->{key};

	my $currentTime = time;
	my $timestampValid =
		$ce->{shibboleth}{manage_session_timeout} ? 1 : time <= $Key->timestamp + $ce->{sessionTimeout};

	if ($timestampValid && $updateTimestamp) {
		$Key->timestamp($currentTime);
		$self->{c}->stash->{'webwork2.database_session'} = { $Key->toHash };
		$self->{c}->stash->{'webwork2.database_session'}{session}{flash} =
			delete $self->{c}->stash->{'webwork2.database_session'}{session}{new_flash}
			if $self->{c}->stash->{'webwork2.database_session'}{session}{new_flash};
	}

	return (1, 1, $timestampValid);
}

1;
