package WebworkBridge::Importer::CourseUpdater;

##### Library Imports #####
use strict;
use warnings;

use Time::HiRes qw/gettimeofday/;
use Date::Format;
use App::Genpass;
use Data::Dumper;

use WeBWorK::CourseEnvironment;
use WeBWorK::DB;
use WeBWorK::Debug;
use WeBWorK::Utils qw(runtime_use readFile cryptPassword);
use WeBWorK::DB::Utils qw(initializeUserProblem);

# Constructor
sub new
{
	my ($class, $ce, $db, $users) = @_;
	my $self = {
		ce => $ce,
		db => $db,
		users => $users
	};
	bless $self, $class;
	return $self;
}

# it should be safe to require that we have the correctly init course
# environment with the necessary course context
sub updateCourse
{
	my $self = shift;
	my $ce = $self->{ce};
	my $db = $self->{db};

	my $course_id = $ce->{courseName}; # the course we're updating

	debug(("-" x 80) . "\n");
	debug("Starting User Update");

	# Perform Setup
	my @users = @{$self->{users}}; # deref pointer

	# Get already existing users in the database
	my @userIDs;
	my @usersList;
	my @permsList;
	eval
	{
		@userIDs = $db->listUsers();
		@usersList = $db->getUsers(@userIDs);
		@permsList = $db->getPermissionLevels(@userIDs);
	};
	if ($@)
	{
		return "Unable to list existing users for course: $course_id\n"
	}
	my %perms = map {($_->user_id => $_ )} @permsList;
	my %userList = map {($_->user_id => $_ )} @usersList;

	# we received _ people from LTI, there was _ people in the course before update
	# Summary log entry
	my $numCurAct = 0;
	my $numCurDrop = 0;
	while (my ($key, $person) = each(%userList)) {
		if ($person->status() ne "D") {
			$numCurAct++;
		} else {
			$numCurDrop++;
		}
	}

	my $numLTI = @users;
	my $sum = " -- Course $course_id currently has $numCurAct people active, " .
		"$numCurDrop people dropped, we received $numLTI people from LTI.";
	$self->addlog($sum);

	# Update has 4 components
	#	1. Check existing users to see if we have anyone who dropped the course
	#		but decided to re-register or if their info needs updating.
	#	2. Add newly enrolled users
	#	3. Mark dropped user as "dropped"

	# Update components 1,2: Check existing users
	debug("Checking for new users...\n");
	foreach (@users)
	{
		my $id = $_->{'loginid'};
		if (exists($userList{$id})) {
			# Update component 1: Update existing users
			$self->updateUser($userList{$id}, $_, $perms{$id});
			delete($userList{$id}); # this user is now safe from being dropped
		} else {
			# Update component 2: newly enrolled user, have to add
			my $ret = $self->addUser($_);
			$self->addlog("User $id joined $course_id");
			if ($ret)
			{
				return $ret;
			}
		}
	}

	debug("Checking for dropped users...\n");
	# Update component 3: Mark dropped users as dropped
	while (my ($key, $val) = each(%userList))
	{ # any users left in %userList has been dropped
		my $person = $val;
		# only users with status C or P should be tracked by enrolment sync
		if (($person->status() eq "C" || $person->status() eq "P") &&
			$key ne "admin")
		{
			$person->status("D");
			$db->putUser($person);
			if ($perms{$key}->permission() == $ce->{userRoles}{student}) {
				$self->addlog("Student $key dropped $course_id");
			} else {
				$self->addlog("Teaching staff $key dropped $course_id");
			}
			#$db->deleteUser($key); # uncomment to actually delete user
		}
	}

	debug("User Update Finished!\n");
	debug(("-" x 80) . "\n");
	return 0;
}

##### Helper Functions #####
sub updateUser
{
	# permission is the current permission object, which can be updated
	# if $newInfo contains new permission
	my ($self, $oldInfo, $newInfo, $permission) = @_;
	my $ce = $self->{ce};
	my $db = $self->{db};

	my $course_id = $ce->{courseName}; # the course we're updating
	my $id = $oldInfo->user_id();

	# Do the simple updates first since they can be batched
	my $update = 0;
	# Update student id
	# don't update if it is undefined or blank (lti membership might not be able to populate field)
	if (defined($newInfo->{'studentid'}) && $newInfo->{'studentid'} ne '' && $newInfo->{'studentid'} ne $oldInfo->student_id()) {
		$oldInfo->student_id($newInfo->{'studentid'});
		$update = 1;
	}
	# Update email, only students get updated, and the new email address
	# has to be non-empty
	if (defined($newInfo->{'email'}) &&
		$newInfo->{'permission'} == $ce->{userRoles}{student} &&
		$newInfo->{'email'} ne "" &&
		$newInfo->{'email'} ne $oldInfo->email_address())
	{
		$oldInfo->email_address($newInfo->{'email'});
		$update = 1;
	}
	# Update first name
	if ($newInfo->{'firstname'} ne $oldInfo->first_name()) {
		$oldInfo->first_name($newInfo->{'firstname'});
		$update = 1;
	}
	# Update last name
	if ($newInfo->{'lastname'} ne $oldInfo->last_name()) {
		$oldInfo->last_name($newInfo->{'lastname'});
		$update = 1;
	}
	# Batch update info
	if ($update) {
		$db->putUser($oldInfo);
	}
	# Update permissions
	if ($newInfo->{'permission'} != $permission->permission()) {
		$permission->permission($newInfo->{'permission'});
		$db->putPermissionLevel($permission);
	}

	# Update status
	if ($oldInfo->status() eq "D") {
		# this person dropped the course but re-registered
		if ($permission->permission() <= $ce->{userRoles}{student}) {
			$oldInfo->status("C");
			$db->putUser($oldInfo);
			$self->addlog("Student $id rejoined $course_id");
		} else {
			$oldInfo->status("P");
			$db->putUser($oldInfo);
			$self->addlog("Teaching staff $id rejoined $course_id");
		}
	}

	# assign all visible homeworks to user
	$self->assignAllVisibleSetsToUser($id, $db);

	if (defined($newInfo->{'client_id'}) && defined($newInfo->{'lti_user_id'}) ) {
		$self->addOrUpdateLTIUser($newInfo);
	}

	return 0;
}

sub addUser
{
	my ($self, $new_user_info) = @_;
	my $ce = $self->{ce};
	my $db = $self->{db};
	my $id = $new_user_info->{'loginid'};
	my $status = "C"; # defaults to enroled
	my $role = $ce->{userRoles}{student}; # defaults to student

	# modify status and role if user is a teaching staff
	if ($new_user_info->{'permission'})
	{ # override default permission if necessary
		$role = $new_user_info->{'permission'};
	}

	if ($role == $ce->{userRoles}{professor} ||
		$role == $ce->{userRoles}{ta} ||
		$role == $ce->{userRoles}{admin})
	{
		$status = "P"; # teaching staff status, doesn't get homework or graded
	}

	# student record
	my $new_user = $db->newUser();
	$new_user->user_id($id);
	$new_user->first_name($new_user_info->{'firstname'});
	$new_user->last_name($new_user_info->{'lastname'});
	$new_user->email_address($new_user_info->{'email'});
	$new_user->status($status);
	$new_user->student_id($new_user_info->{'studentid'});

	# password record
	my $genpass = App::Genpass->new(length=>16);
	my $password = $db->newPassword(user_id => $id);
	$password->password(cryptPassword($genpass->generate));

	# permission record
	my $permission = $db->newPermissionLevel(user_id => $id, permission => $role);

	# commit changes to db
	eval{ $db->addUser($new_user); };
	if ($@)
	{
		return "Add user for $id failed!\n";
	}
	eval { $db->addPassword($password); };
	if ($@)
	{
		return "Add password for $id failed!\n";
	}
	eval { $db->addPermissionLevel($permission); };
	if ($@)
	{
		return "Add permission for $id failed!\n";
	}

	# assign all visible homeworks to user
	$self->assignAllVisibleSetsToUser($id, $db);

	if (defined($new_user_info->{'client_id'}) && defined($new_user_info->{'lti_user_id'}) ) {
		$self->addOrUpdateLTIUser($new_user_info);
	}

	return 0;
}

sub addOrUpdateLTIUser
{
	my ($self, $user) = @_;
	my $ce = $self->{ce};
	my $db = $self->{db};
	my $client_id = $user->{'client_id'};
	my $user_id = $user->{'loginid'};
	my $lti_user_id = $user->{'lti_user_id'};

	my $exists = $db->existsLTIUser($user_id, $client_id);
	if($exists) {
        my $lti_user = $db->getLTIUser($user_id, $client_id);
		if (defined($lti_user_id) && $lti_user_id ne $lti_user->lti_user_id()) {
			$lti_user->lti_user_id($lti_user_id);
			$db->putLTIUser($lti_user);
		}
    } else {
        my $lti_user = $db->newLTIUser(
			user_id => $user_id,
			client_id => $client_id,
			lti_user_id => $lti_user_id
		);
        $db->addLTIUser($lti_user);
	}

	return 0;
}

sub addlog
{
	my ($self, $msg) = @_;

	my ($sec, $msec) = gettimeofday;
	my $date = time2str("%a %b %d %H:%M:%S.$msec %Y", $sec);

	$msg = "[$date] $msg\n";

	my $logfile = $self->{ce}->{bridge}{studentlog};
	if ($logfile ne "") {
		if (open my $f, ">>", $logfile) {
			print $f $msg;
			close $f;
		} else {
			debug("Error, unable to open student updates log file '$logfile' in append mode: $!");
		}
	} else {
		debug("Warning, student updates log file not configured.");
		print STDERR $msg;
	}
}

# Taken from assignAllSetsToUser() in WeBWorK::ContentGenerator::Instructor
sub assignAllVisibleSetsToUser {
	my ($self, $userID, $db) = @_;

	# skip automatically assigning homeworksets if disabled for course
	my $ltiAutoAssignHomeworksets = $db->getSettingValue('skipLTIAutomaticAssignHomeworksets');
	if (defined($ltiAutoAssignHomeworksets) && $ltiAutoAssignHomeworksets eq "1") {
		return;
	}

	my @globalSetIDs = $db->listGlobalSets;
	my @GlobalSets = $db->getGlobalSets(@globalSetIDs);

	my @results;

	my $i = 0;
	foreach my $GlobalSet (@GlobalSets) {
		if (not defined $GlobalSet) {
			warn "record not found for global set $globalSetIDs[$i]";
		}
		elsif ($GlobalSet->visible) {
			my @result = $self->assignSetToUser($userID, $GlobalSet, $db);
			push @results, @result if @result;
		}
		$i++;
	}

	return @results;
}

# Taken and modified from WeBWorK::ContentGenerator::Instructor
sub assignSetToUser {
	my ($self, $userID, $GlobalSet, $db) = @_;
	my $setID = $GlobalSet->set_id;

	my $UserSet = $db->newUserSet;
	$UserSet->user_id($userID);
	$UserSet->set_id($setID);

	my @results;
	my $set_assigned = 0;

	eval { $db->addUserSet($UserSet) };
	if ($@) {
		if ($@ =~ m/user set exists/) {
			push @results, "set $setID is already assigned to user $userID.";
			$set_assigned = 1;
		} else {
			die $@;
		}
	}

	my @GlobalProblems = grep { defined $_ } $db->getAllGlobalProblems($setID);
	foreach my $GlobalProblem (@GlobalProblems) {
		my @result = $self->assignProblemToUser($userID, $GlobalProblem, $db);
		push @results, @result if @result and not $set_assigned;
	}

	return @results;
}

# Taken and modified from WeBWorK::ContentGenerator::Instructor
sub assignProblemToUser {
	my ($self, $userID, $GlobalProblem, $db) = @_;

	my $UserProblem = $db->newUserProblem;
	$UserProblem->user_id($userID);
	$UserProblem->set_id($GlobalProblem->set_id);
	$UserProblem->problem_id($GlobalProblem->problem_id);
	my $seed; # yes, I know it's empty, just needed a null value for this
	initializeUserProblem($UserProblem, $seed);

	eval { $db->addUserProblem($UserProblem) };
	if ($@) {
		if ($@ =~ m/user problem exists/) {
			return "problem " . $GlobalProblem->problem_id
				. " in set " . $GlobalProblem->set_id
				. " is already assigned to user $userID.";
		} else {
			die $@;
		}
	}

	return ();
}

1;
