package WebworkBridge::Importer::CourseCreator;

##### Library Imports #####
use strict;
use warnings;
#use lib "$ENV{WEBWORK_ROOT}/lib"; # uncomment for shell invocation

use WeBWorK::CourseEnvironment;
use WeBWorK::DB;
use WeBWorK::Debug;
use WeBWorK::Utils qw(cryptPassword);
use WeBWorK::Utils::CourseManagement qw(addCourse);

use WebworkBridge::Importer::Error;

use App::Genpass;
use Text::CSV;

# Constructor
sub new
{
	my ($class, $r, $course_ref, $users_ref) = @_;
	my $self = {
		r => $r,
		course => $course_ref,
		users => $users_ref
	};
	bless $self, $class;
	return $self;
}

sub createCourse
{
	my $self = shift;

	my $error = $self->runAddCourse();
	if ($error) { return $error; }

	return 0;
}

sub runAddCourse
{
	my $self = shift;
	my $ce = $self->{r}->ce;
	my $db = $self->{r}->db;

	my $courseID = $self->{course}->{name};
	my $courseTitle = $self->{course}->{title};

	my $ce2 = new WeBWorK::CourseEnvironment({
		%WeBWorK::SeedCE,
		courseName => $courseID,
	});

	my %courseOptions = ( dbLayoutName => $ce2->{dbLayoutName} );
	my %dbOptions;
	my %optional_arguments;
	if ($ce->{bridge}{course_template})
	{
		$optional_arguments{templatesFrom} = $ce->{bridge}{course_template};
	}
	if ($courseTitle ne "") {
		$optional_arguments{courseTitle} = $courseTitle;
	}

	my $genpass = App::Genpass->new(length=>16);
	my @classlist;
	my @users = @{$self->{users}};
	foreach my $user (@users)
	{
		my $User = $db->newUser(
			user_id       => $user->{'loginid'},
			first_name    => $user->{'firstname'},
			last_name     => $user->{'lastname'},
			student_id    => $user->{'studentid'},
			email_address => $user->{email} ? $user->{email} : "",
			status        => ($user->{'permission'} > $ce->{userRoles}{student}) ? "P" : "C",
		);
		my $Password = $db->newPassword(
			user_id  => $user->{'loginid'},
			password => cryptPassword($genpass->generate),
		);
		my $PermissionLevel = $db->newPermissionLevel(
			user_id    => $user->{'loginid'},
			permission => $user->{'permission'},
		);
		push @classlist, [ $User, $Password, $PermissionLevel];
	}
	# add admin
	my $AdminUser = $db->newUser(
		user_id       => "admin",
		first_name    => "admin",
		last_name     => "admin",
		student_id    => "admin",
		email_address => "",
		status        => "P",
	);
	my $AdminPassword = $db->newPassword(
		user_id  => "admin",
		password => cryptPassword($ce->{bridge}{adminuserpw}),
	);
	my $AdminPermissionLevel = $db->newPermissionLevel(
		user_id    => "admin",
		permission => $ce->{userRoles}{professor},
	);
	push @classlist, [ $AdminUser, $AdminPassword, $AdminPermissionLevel];

	eval {
		addCourse(
			courseID      => $courseID,
			ce            => $ce2,
			courseOptions => \%courseOptions,
			dbOptions     => \%dbOptions,
			users         => \@classlist,
			%optional_arguments,
		);
	};
	if ($@) {
		my $error = $@;
		# get rid of any partially built courses
		unless ($error =~ /course exists/) {
			eval {
				deleteCourse(
					courseID   => $courseID,
					ce         => $ce2,
					dbOptions  => \%dbOptions,
				);
			}
		}
		return error("Add course failed, failure: $error","#e018");
	}

	if ($ce->{bridge}{hide_new_courses}) {
		my $message = 'Place a file named "hide_directory" in a course or other directory '.
			'and it will not show up in the courses list on the WeBWorK home page. '.
			'It will still appear in the Course Administration listing.';
		my $coursesDir = $ce->{webworkDirs}->{courses};
		local *HIDEFILE;
		if (open (HIDEFILE, ">","$coursesDir/$courseID/hide_directory")) {
			print HIDEFILE "$message";
			close HIDEFILE;
		} else {
			return error("Add course failed, hide directory failure", "#e022");
		}
	}

	return 0;
}

# Perl 5.8.8 doesn't let you override `` for testing. This sub gets
# around that since we can still override subs.
sub customExec
{
	my $cmd = shift;
	my $msg = shift;

	$$msg = `$cmd 2>&1`;
	if ($?)
	{
		return 1;
	}
	return 0;
}

1;
