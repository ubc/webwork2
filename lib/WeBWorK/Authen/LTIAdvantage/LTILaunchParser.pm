package WeBWorK::Authen::LTIAdvantage::LTILaunchParser;

use strict;
use warnings;

use XML::Simple;
use WeBWorK::Debug;
use Data::Dumper;
use Crypt::JWT qw(decode_jwt);

##### Exported Functions #####
sub new
{
	my ($class, $ce, $encoded_data) = @_;

	my $data = {};
	my $error = '';
	if (defined($encoded_data) && $encoded_data) {
		eval {
			$data = decode_jwt(token => $encoded_data, ignore_signature => 1);
		};
		if ($@) {
			$error = $@;
		}
	}

	my $self = {
		ce => $ce,
		data => $data,
		error => $error
	};
	bless $self, $class;
	return $self;
}

sub getCourseName
{
	my $self = shift;
	my $ce = $self->{ce};

	my $course_title;
	# Allow sites to customize the user
	if (defined($ce->{bridge}{custom_course_title_parser})) {
		$course_title = $ce->{bridge}{custom_course_title_parser}($self);
	} else {
		# default to context_id if custom_course_title_parser is not defined
		$course_title = $self->get_claim_param("context", "id");
	}

	$course_title = $self->sanitizeCourseName($course_title);
	debug("Course name is: $course_title");
	return $course_title;
}

sub sanitizeCourseName
{
	my $self = shift;
	my $course = shift;
	# replace spaces with underscores cause the addcourse script can't handle
	# spaces in course names and we want to keep the course name readable
	$course =~ s/ /_/g;
	$course =~ s/\./_/g;
	$course =~ s/[^a-zA-Z0-9_-]//g;
	$course = substr($course,0,40); # needs to fit mysql table name limits
	# max length of a mysql table name is 64 chars, however, webworks stick
	# additional characters after the course name, so, to be safe, we'll
	# have an error margin of 24 chars (currently the longest webwork table addition is 24 characters long).
	return $course;
}

sub sanitizeSetName
{
	my $self = shift;
	my $set_id = shift;
	# replace spaces with underscores cause the addcourse script can't handle
	# spaces in course names and we want to keep the course name readable
	$set_id =~ s/ /_/g;
	$set_id =~ s/\./_/g;
	$set_id =~ s/[^a-zA-Z0-9_-]//g;
	return $set_id;
}


sub get_param {
	my $self = shift;
	my $param_name = shift;

	return unless exists $self->{data};
	return unless exists $self->{data}{$param_name};
	return $self->{data}{$param_name};
}

sub get_claim {
	my $self = shift;
	my $claim_name = shift;

	return unless exists $self->{data};
	return unless exists $self->{data}{"https://purl.imsglobal.org/spec/lti/claim/".$claim_name};
	return $self->{data}{"https://purl.imsglobal.org/spec/lti/claim/".$claim_name};
}

sub get_claim_param {
	my $self = shift;
	my $claim_name = shift;
	my $param_name = shift;

	return unless exists $self->{data};
	return unless exists $self->{data}{"https://purl.imsglobal.org/spec/lti/claim/".$claim_name};
	return unless exists $self->{data}{"https://purl.imsglobal.org/spec/lti/claim/".$claim_name}{$param_name};
	return $self->{data}{"https://purl.imsglobal.org/spec/lti/claim/".$claim_name}{$param_name};
}

sub get_nrps_claim {
	my $self = shift;
	my $param_name = shift;

	return unless exists $self->{data};
	return unless exists $self->{data}{"https://purl.imsglobal.org/spec/lti-nrps/claim/namesroleservice"};
	return $self->{data}{"https://purl.imsglobal.org/spec/lti-nrps/claim/namesroleservice"};
}

sub get_nrps_claim_param {
	my $self = shift;
	my $param_name = shift;

	return unless exists $self->{data};
	return unless exists $self->{data}{"https://purl.imsglobal.org/spec/lti-nrps/claim/namesroleservice"};
	return unless exists $self->{data}{"https://purl.imsglobal.org/spec/lti-nrps/claim/namesroleservice"}{$param_name};
	return $self->{data}{"https://purl.imsglobal.org/spec/lti-nrps/claim/namesroleservice"}{$param_name};
}

sub get_ags_claim {
	my $self = shift;
	my $param_name = shift;

	return unless exists $self->{data};
	return unless exists $self->{data}{"https://purl.imsglobal.org/spec/lti-ags/claim/endpoint"};
	return $self->{data}{"https://purl.imsglobal.org/spec/lti-ags/claim/endpoint"};
}

sub get_ags_claim_param {
	my $self = shift;
	my $param_name = shift;

	return unless exists $self->{data};
	return unless exists $self->{data}{"https://purl.imsglobal.org/spec/lti-ags/claim/endpoint"};
	return unless exists $self->{data}{"https://purl.imsglobal.org/spec/lti-ags/claim/endpoint"}{$param_name};
	return $self->{data}{"https://purl.imsglobal.org/spec/lti-ags/claim/endpoint"}{$param_name};
}

sub has_ags_claim_scope {
	my $self = shift;
	my $scope_name = shift;

	return 0 unless exists $self->{data};
	return 0 unless exists $self->{data}{"https://purl.imsglobal.org/spec/lti-ags/claim/endpoint"};
	return 0 unless exists $self->{data}{"https://purl.imsglobal.org/spec/lti-ags/claim/endpoint"}{"scope"};
	for my $scope (@{$self->{data}{"https://purl.imsglobal.org/spec/lti-ags/claim/endpoint"}{"scope"}}) {
		if ($scope eq "https://purl.imsglobal.org/spec/lti-ags/scope/".$scope_name) {
			return 1;
		}
	}
	return 0;
}

sub get_user_info {
	my $self = shift;
	my $ce = $self->{ce};

	my %user;

	$user{'loginid'} = $self->get_user_identifier();
	$user{'client_id'} = $self->get_param("aud");
	$user{'lti_user_id'} = $self->get_param("sub");
	$user{'firstname'} = $self->get_param("given_name");
	$user{'lastname'} = $self->get_param("family_name");
	$user{'email'} = $self->get_param("email");

	# convert from internal perl UTF8 to binary UTF8, note that this means
	# I'm expecting these to go straight into the database, not be used in
	# any more perl ops
	utf8::encode($user{'firstname'});
	utf8::encode($user{'lastname'});

	# set user permissions
	$user{'studentid'} = '';

	$user{'permission'} = $self->get_permissions();

	if ($user{'permission'} == $ce->{userRoles}{student}) {
		$user{'studentid'} = $self->get_student_number();
	}

	return %user;
}

sub get_user_identifier {
	my $self = shift;
	my $ce = $self->{ce};

	my $client_id = $self->get_param("aud");
	my $data_ref = $self->{data};

	if (exists($ce->{bridge}{lti_clients}{$client_id}{user_identifier_field})) {
		my $user_identifier_field = $ce->{bridge}{lti_clients}{$client_id}{user_identifier_field};
		my @user_identifier_parts = split(/\|/, $user_identifier_field);

		foreach my $user_identifier_part (@user_identifier_parts) {
			if (!defined($data_ref->{$user_identifier_part})) {
				return $self->get_param("sub");
			}
			$data_ref = $data_ref->{$user_identifier_part};
		}

		if (!defined($data_ref) || ref($data_ref) eq 'HASH' || ref($data_ref) eq 'ARRAY' || $data_ref eq '') {
			# fallback is to use lti_user_id (useful for LMS preview users)
			return $self->get_param("sub");
		}

		return $data_ref;
	}

	# use sub by default
	return $self->get_param("sub");
}

sub get_student_number {
	my $self = shift;
	my $ce = $self->{ce};

	my $client_id = $self->get_param("aud");
	my $data_ref = $self->{data};

	if (exists($ce->{bridge}{lti_clients}{$client_id}{user_student_number_field})) {
		my $student_number_field = $ce->{bridge}{lti_clients}{$client_id}{user_student_number_field};
		my @student_number_parts = split(/\|/, $student_number_field);

		foreach my $student_number_part (@student_number_parts) {
			if (!defined($data_ref->{$student_number_part})) {
				return '';
			}
			$data_ref = $data_ref->{$student_number_part};
		}

		if (!defined($data_ref) || ref($data_ref) eq 'HASH' || ref($data_ref) eq 'ARRAY' || $data_ref eq '') {
			return '';
		}

		return $data_ref;
	}

	# use '' by default
	return '';
}

# Core context roles
# http://purl.imsglobal.org/vocab/lis/v2/membership#Administrator
# http://purl.imsglobal.org/vocab/lis/v2/membership#ContentDeveloper
# http://purl.imsglobal.org/vocab/lis/v2/membership#Instructor
# http://purl.imsglobal.org/vocab/lis/v2/membership#Learner
# http://purl.imsglobal.org/vocab/lis/v2/membership#Mentor

# Instructor 	Sub-role
# Grader, GuestInstructor, Instructor, Lecturer, PrimaryInstructor
# SecondaryInstructor, TeachingAssistant, TeachingAssistantGroup
# TeachingAssistantOffering, TeachingAssistantSection, TeachingAssistantTemplate

sub get_permissions {
	my $self = shift;
	my $ce = $self->{ce};

	my @roles = @{$self->get_claim("roles")};

	my $is_admin = 0;
	my $is_instructor = 0;
	my $is_content_developer = 0;
	my $is_ta = 0;
	my $is_student = 0;

	foreach my $role (@roles) {
		# supports long and short formats. ex:
		# http://purl.imsglobal.org/vocab/lis/v2/membership#Instructor
		# Instructor
		# http://purl.imsglobal.org/vocab/lis/v2/membership/Instructor#TeachingAssistant
		# Instructor#TeachingAssistant
		$role =~ s/http\:\/\/purl\.imsglobal\.org\/vocab\/lis\/v2\/membership(\#|\/)//g;
		if ($role eq 'Administrator') {
			$is_admin = 1;
		} elsif ($role eq 'Instructor') {
			$is_instructor = 1;
		} elsif ($role eq 'ContentDeveloper') {
			$is_content_developer = 1;
		} elsif ($role eq 'Instructor#TeachingAssistant') {
			$is_ta = 1;
		} elsif ($role eq 'Learner') {
			$is_student = 1;
		}
	}

	if ($is_admin) {
		return $ce->{userRoles}{admin};
	} elsif ($is_instructor && !$is_ta) {
		return $ce->{userRoles}{professor};
	} elsif ($is_content_developer) {
		return $ce->{userRoles}{professor};
	} elsif ($is_ta) {
		return $ce->{userRoles}{ta};
	} elsif ($is_student) {
		return $ce->{userRoles}{student};
	} else {
		# default return guest or error??
		return $ce->{userRoles}{guest};
	}
}

1;

