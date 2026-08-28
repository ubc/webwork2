package LTI1p3::Entrypoint::Jwks;

use Mojo::Base 'WeBWorK::Controller', -strict, -signatures, -async_await;
use Crypt::PK::RSA;

use WeBWorK::CourseEnvironment;
use WeBWorK::Debug;

async sub get ($c) {
	debug('Rendering JWKS');
	my $ce = $c->ce(WeBWorK::CourseEnvironment->new({
		webwork_dir => $ENV{WEBWORK_ROOT},
	}));
	# retrieve keys in PEM format, key ID is the LTI platform's ID
	my %pems = ();
	foreach my $clientId (keys %{ $ce->{lti_advantage}{lti_clients} }) {
		my $ltiClient  = $ce->{lti_advantage}{lti_clients}{$clientId};
		my $platformId = '';
		my $publicPem  = '';
		if ($ltiClient->{platform_id}) {
			$platformId = $ltiClient->{platform_id};
		}
		if ($ltiClient->{tool_public_key}) {
			$publicPem = $ltiClient->{tool_public_key};
		}
		if ($platformId eq '' || $publicPem eq '') { next; }
		$pems{$platformId} = $publicPem;
	}
	# convert PEM keys into JWK format
	my @keys = ();
	foreach my $platformId (keys %pems) {
		my $rsa = Crypt::PK::RSA->new;
		$rsa->import_key(\$pems{$platformId});
		my $jwk = $rsa->export_key_jwk('public', 1);
		# add additional required params
		$jwk->{use} = 'sig';
		$jwk->{alg} = 'RS256';
		$jwk->{kid} = $platformId;
		push(@keys, $jwk);
	}

	return $c->render(json => { keys => \@keys });
}

1;
