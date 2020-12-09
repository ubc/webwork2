package WebworkBridge::Importer::CourseCreator;

##### Library Imports #####
use strict;
use warnings;
#use lib "$ENV{WEBWORK_ROOT}/lib"; # uncomment for shell invocation

use WeBWorK::CourseEnvironment;
use WeBWorK::DB;
use WeBWorK::Debug;
use Data::Dumper;
use WeBWorK::Utils qw(cryptPassword);
use WeBWorK::Utils::CourseManagement qw(addCourse);

use WebworkBridge::Importer::Error;

use Text::CSV;

# Constructor
sub new
{
	my ($class, $ce, $db, $courseID, $courseTitle) = @_;
	my $self = {
		ce => $ce,
		db => $db,
		courseID => $courseID,
		courseTitle => $courseTitle
	};
	bless $self, $class;
	return $self;
}

sub createCourse
{
	my $self = shift;
	my $ce = $self->{ce};
	my $db = $self->{db};

	my $courseID = $self->{courseID};
	my $courseTitle = $self->{courseTitle};

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
	my @classlist = [ $AdminUser, $AdminPassword, $AdminPermissionLevel];

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
