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
	my ($class, $r, $course_ref, $students_ref) = @_;
	my $self = $class->SUPER::new($r, $course_ref, $students_ref);
	bless $self, $class;
	return $self;
}

sub parse
{
	my ($self, $param) = @_;
	my $ce = $self->{r}->ce;
	my $course = $self->{course};
	# named students, but is actually the list of all users in the course
	my $students = $self->{students}; 
	%{$course} = ();
	@{$students} = ();

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

	$course->{'profid'} = ""; # Initialize profid to empty string

	# we want to make sure that the student we received are actually
	# in the course that we sent the request for, we can do this
	# by checking their lis_result_sourcedid if they have LTI grade sync
	# enabled. The raw string looks like :_101_1::webworkdev:0004
	# we only want the _101_1 part.
	my $ltiIdRegex = qr/:(.+?):.+/;
	my $expectedLTIId = $self->{r}->param('ext_ims_lis_memberships_id');
	($expectedLTIId) = $expectedLTIId =~ $ltiIdRegex;

	foreach(@members)
	{ # process members
		my %tmp = $self->parseUser($_);
		# assign appropriate permissions based on roles
		my $roles = $_->{'roles'};
		if (exists $_->{'lis_result_sourcedid'} && $expectedLTIId ne "")
		{
			my $sourcedid = $_->{'lis_result_sourcedid'};
			$sourcedid =~ $ltiIdRegex;
			if ($1 ne $expectedLTIId)
			{ # student does not match course
				$extralog->logXML("Update aborted, got student in wrong course: $1");
				return error("Student does not match course.");
			}
		}
		if ($roles =~ /instructor/i ||
			$roles =~ /contentdeveloper/i)
		{ # make note of the instructor for later
			$course->{'profid'} = $tmp{'loginid'} . ',' . $course->{'profid'};
			$tmp{'permission'} = $ce->{userRoles}{professor};
		}
		elsif ($roles =~ /teachingassistant/i)
		{
			$tmp{'permission'} = $ce->{userRoles}{ta};
		}
		else
		{
			$tmp{'permission'} = $ce->{userRoles}{student};
		}
		# store user info
		push(@{$students}, \%tmp);
	}
	$course->{'profid'} = substr($course->{'profid'}, 0, -1); # rm extra comma 

	return 0;
}

##### Helper Functions #####

sub parseUser
{
	my ($self, $tmp) = @_;
	my $ce = $self->{r}->ce;
	my %param = %{$tmp};
	my %user;
	$user{'firstname'} = $param{'person_name_given'};
	$user{'lastname'} = $param{'person_name_family'};
	# convert from internal perl UTF8 to binary UTF8, note that this means
	# I'm expecting these to go straight into the database, not be used in
	# any more perl ops
	utf8::encode($user{'firstname'});
	utf8::encode($user{'lastname'});
	$user{'studentid'} = $param{'user_id'};
	$user{'loginid'} = $param{$ce->{bridge}{user_identifier_field}};
	$user{'lis_source_did'} = $param{'lis_result_sourcedid'};
	$user{'email'} = $param{'person_contact_email_primary'};
	$user{'password'} = "";
	return %user;
}

sub parseLaunchUser
{
	my $self = shift;
	my $r = $self->{r};
	my $ce = $r->ce;

	my %user;
	$user{'firstname'} = $r->param('lis_person_name_given');
	$user{'lastname'} = $r->param('lis_person_name_family');
	# convert from internal perl UTF8 to binary UTF8, note that this means
	# I'm expecting these to go straight into the database, not be used in
	# any more perl ops
	utf8::encode($user{'firstname'});
	utf8::encode($user{'lastname'});
	$user{'studentid'} = $r->param('user_id');
	$user{'loginid'} = $r->param($ce->{bridge}{user_identifier_field});
	$user{'email'} = $r->param('lis_person_contact_email_primary');
	$user{'password'} = "";

	# set lis_source_did if not a quiz or homework set launch request
	if (!$r->param("custom_homework_set") && !$r->param("custom_quiz_set"))
	{
		$user{'lis_source_did'} = $r->param('lis_result_sourcedid');
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

# test code
#open FILE, "test.xml" or die "Cannot open XML file. $!";
#
#my $input = join("",<FILE>);
#
#my %course = ();
#my @students = ();
#
#parse($input, \%course, \@students);
#
#$Data::Dumper::Indent = 3;
#print "Course Info: \n";
#print Dumper(\%course);
#
#print "\n\nStudents List: \n";
#print Dumper(\@students);

1;

