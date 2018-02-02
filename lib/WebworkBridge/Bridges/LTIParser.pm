package WebworkBridge::Bridges::LTIParser;
use base qw(WebworkBridge::Parser);

use strict;
use warnings;

use XML::Simple;
use WebworkBridge::Importer::Error;
use WeBWorK::Debug;
use Data::Dumper;

##### Exported Functions #####
sub new
{
	my ($class, $r, $course_ref, $users_ref) = @_;
	my $self = $class->SUPER::new($r, $course_ref, $users_ref);
	bless $self, $class;
	return $self;
}

sub parse
{
	my ($self, $param) = @_;
	my $ce = $self->{r}->ce;
	my $course = $self->{course};
	my $users = $self->{users};
	%{$course} = ();
	@{$users} = ();

	my $xml = new XML::Simple;

	my $extralog = WebworkBridge::ExtraLog->new($self->{r});

	my $data;
	eval
	{
		$data = $xml->XMLin($param, SuppressEmpty=>'');
	};
	if ($@)
	{
		$extralog->logXML("XML parsing failed.");
		return error("XML parsing failed\n");
	}

	if ($data->{'statusinfo'}{'codemajor'} ne 'Success')
	{ # check status code
		$extralog->logXML("Retrived roster has failure status code.");
		return error("Failed to retrieve roster.", "#e001");
	}

	my @members = $data->{'memberships'}{'member'};

	# xml parser creates different data structs if more than 1 member
	if (ref($data->{'memberships'}{'member'}) eq 'ARRAY')
	{
		# Note that the explicit cast is necessary, otherwise it throws
		# a bad index error in the foreach loop. The explicit cast is not
		# necessary if we only have a single member in the course, hence
		# we only cast if there are more than one members in the course.
		@members = @{$data->{'memberships'}{'member'}};
	}

	foreach(@members)
	{ # process members
		my %user = $self->parseUser($_);
		# assign appropriate permissions based on roles
		my $roles = $_->{'roles'};
		if ($roles =~ /instructor/i || $roles =~ /contentdeveloper/i)
		{
			$user{'permission'} = $ce->{userRoles}{professor};
		}
		elsif ($roles =~ /teachingassistant/i)
		{
			$user{'permission'} = $ce->{userRoles}{ta};
		}
		else
		{
			$user{'permission'} = $ce->{userRoles}{student};
		}
		# store user info
		push(@{$users}, \%user);
	}

	return 0;
}

##### Helper Functions #####

sub parseUser
{
	my ($self, $tmp) = @_;
	my $ce = $self->{r}->ce;
	my %param = %{$tmp};
	my %user;
	# fetch user_id
	foreach my $field (@{$ce->{bridge}{user_identifier_fields}})
	{
		# create copy of user_identifier_field element
		my $field_name = $field;
		# fix user_identifier_fields for membership extension
		if ($field_name eq 'lis_person_sourcedid') {
			$field_name = 'person_sourcedid';
		} elsif ($field_name eq 'lis_person_contact_email_primary') {
			$field_name = 'person_contact_email_primary';
		}

		if (defined($param{$field_name}) && $param{$field_name} ne '') {
			$user{'loginid'} = $param{$field_name};
			last;
		}
	}
	$user{'firstname'} = $param{'person_name_given'};
	$user{'lastname'} = $param{'person_name_family'};
	# convert from internal perl UTF8 to binary UTF8, note that this means
	# I'm expecting these to go straight into the database, not be used in
	# any more perl ops
	utf8::encode($user{'firstname'});
	utf8::encode($user{'lastname'});
	# fetch student number
	$user{'studentid'} = '';
	foreach my $field (@{$ce->{bridge}{user_student_number_fields}})
	{
		# create copy of user_identifier_field element
		my $field_name = $field;
		# fix user_identifier_fields for membership extension
		if ($field_name eq 'lis_person_sourcedid') {
			$field_name = 'person_sourcedid';
		}

		if (defined($param{$field_name}) && $param{$field_name} ne '') {
			$user{'studentid'} = $param{$field_name};
			last;
		}
	}
	$user{'lis_source_did'} = $param{'lis_result_sourcedid'};
	$user{'email'} = $param{'person_contact_email_primary'};
	return %user;
}

sub parseLaunchUser
{
	my $self = shift;
	my $r = $self->{r};
	my $ce = $r->ce;

	my %user;
	# fetch user_id
	foreach my $field_name (@{$ce->{bridge}{user_identifier_fields}})
	{
		if (defined($r->param($field_name)) && $r->param($field_name) ne '') {
			$user{'loginid'} = $r->param($field_name);
			last;
		}
	}
	$user{'firstname'} = $r->param('lis_person_name_given');
	$user{'lastname'} = $r->param('lis_person_name_family');
	# convert from internal perl UTF8 to binary UTF8, note that this means
	# I'm expecting these to go straight into the database, not be used in
	# any more perl ops
	utf8::encode($user{'firstname'});
	utf8::encode($user{'lastname'});
	# fetch student number
	$user{'studentid'} = '';
	foreach my $field_name (@{$ce->{bridge}{user_student_number_fields}})
	{
		if (defined($r->param($field_name)) && $r->param($field_name) ne '') {
			$user{'studentid'} = $r->param($field_name);
			last;
		}
	}
	$user{'email'} = $r->param('lis_person_contact_email_primary');

	# set lis_source_did if not a quiz or homework set launch request
	if (!$r->param("custom_homework_set") && !$r->param("custom_quiz_set"))
	{
		$user{'lis_source_did'} = $r->param('lis_result_sourcedid');
	}
	else {
		# used to overwrite existing lis_source_did attached to user if needed
		$user{'homework_set_lis_source_did'} = $r->param('lis_result_sourcedid');
	}

	# set user permissions
	if ($r->param('roles') =~ /instructor/i || $r->param('roles') =~ /contentdeveloper/i) {
		$user{'permission'} = $ce->{userRoles}{professor};
	}
	elsif ($r->param('roles') =~ /teachingassistant/i) {
		$user{'permission'} = $ce->{userRoles}{ta};
	}
	else {
		$user{'permission'} = $ce->{userRoles}{student};
	}

	return %user;
}

1;

