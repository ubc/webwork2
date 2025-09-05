package LTI1p3::Entrypoint;

use Mojo::Base 'WeBWorK::Controller', -strict, -signatures, -async_await;

##### Library Imports #####
use WeBWorK::CourseEnvironment;
use WeBWorK::DB;
use WeBWorK::Debug;

use LTI1p3::Importer::Error;
use LTI1p3::Importer::CourseCreator;
use LTI1p3::Importer::CourseUpdater;

sub getSetId
{
	my $self = shift;
	return $self->{setId};
}

sub createCourse ($c, $courseID, $courseTitle)
{
	my $ce = $c->ce;
	my $db = $c->db;

	my $creator = LTI1p3::Importer::CourseCreator->new($ce, $db, $courseID, $courseTitle);
	my $ret = $creator->createCourse();
	if ($ret)
	{
		return error("Failed to create course: $ret", "#e004");
	}

	return 0;
}

sub updateCourse
{
	my ($self, $ce, $db, $users) = @_;

	my $creator = LTI1p3::Importer::CourseUpdater->new($ce, $db, $users);
	my $ret = $creator->updateCourse();
	if ($ret)
	{
		return error("Failed to update course: $ret", "#e004");
	}

	return 0;
}

sub _addCorsHeaders ($c, $ce) {
	my $originHeader = $c->req->headers->header('Origin');
	my $allowHeader = $c->req->headers->header('Access-Control-Allow-Headers');
	my $sendHeader = 0;
	# don't send header if we don't have an origin header or if the origin
	# isn't listed as allowed
	if ($originHeader) {
		foreach my $allowOrigin (@{$ce->{lti_advantage}{allow_origins}}) {
			debug("Origin: $originHeader Allow: $allowOrigin");
			if ($originHeader eq $allowOrigin) {
				$sendHeader = 1;
				last;
			}
		}
	}

	if ($sendHeader) {
		$c->res->headers->access_control_allow_origin($originHeader);
		$c->res->headers->header('Access-Control-Allow-Methods' =>
								 'OPTIONS, GET, POST');
		$c->res->headers->header('Access-Control-Allow-Credentials' => 'true');
		$c->res->headers->header('Vary' => 'Cookie, Origin');
		if ($allowHeader) {
			$c->res->headers->header('Access-Control-Allow-Headers' => $allowHeader);
		}
	}
}

async sub options ($c)
{
	my $ce = $c->ce(WeBWorK::CourseEnvironment->new({
		webwork_dir => $ENV{WEBWORK_ROOT},
	}));

	$c->_addCorsHeaders($ce);

	$c->rendered(204);
}

1;
