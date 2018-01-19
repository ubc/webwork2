package WebworkBridge::Exporter::GradesExport;

##### Library Imports #####
use strict;
use warnings;

use Data::Dumper;

use WeBWorK::CourseEnvironment;
use WeBWorK::Debug;
use WeBWorK::DB;


# Constructor, only needs the the Apache request object
sub new
{
	my ($class, $r) = @_;
	my $self = {
		r => $r
	};
	bless $self, $class;
	return $self;
}

sub getGrades
{
	my $self = shift;
	my $ce = $self->{r}->ce;
	my $db = $self->{r}->db;

	debug(("-" x 80) . "\n");
	debug("Attempting to get grades.");

	# preload information needed later
	my @userIDs;
	my @usersList; # user objects
	my @permsList; # user's permissions in this course
	eval 
	{ 
		@userIDs = $db->listUsers(); 
		@usersList = $db->getUsers(@userIDs);
		@permsList = $db->getPermissionLevels(@userIDs);
	};
	if ($@)
	{
		die "Unable to list existing users for course: ".$ce->courseName."\n";
	}
	my %perms = map {($_->user_id => $_ )} @permsList;
	my %users = map {($_->user_id => $_ )} @usersList;

	my %scores = ();
	foreach my $userid (@userIDs)
	{ # go through each user in the course
		# skip users who are not students or who has no student numbers
		my $studentID = $users{$userid}->student_id;
		if ($perms{$userid}->permission() != $ce->{userRoles}{student} || $studentID eq "")
		{
			next;
		}

		# get the sets assigned to this user
		my @setids = $db->listUserSets($userid);
		my @sets = $db->getMergedSets( map {[$userid, $_]} @setids );

		my $courseTotalRight = 0;
		my $courseTotal = 0;

		foreach my $set ( @sets )
		{ # go through each assigned set
			my $record = $self->getGradeRecords($set, $db, $userid);
			if (defined($record)) {
				$courseTotalRight += $record->{totalRight};
				$courseTotal += $record->{total};

				if ($record->{lis_source_did}) {
					push(@{$scores{$userid}}, $record);
				}
			}
		}

		# pass back course grade if student's lis_source_did is set
		if ($users{$userid}->lis_source_did()) {
			my $courseRecord = {
				totalRight => $courseTotalRight,
				total => $courseTotal,
				score => $self->getScore($courseTotalRight, $courseTotal),
				lis_source_did => $users{$userid}->lis_source_did()
			};

			push(@{$scores{$userid}}, $courseRecord);
		}
	}

	debug("Grades found: ". Dumper(\%scores));

	return \%scores;
}


#### Private Helper Functions ####

# Get grade records for a user's problem set
# There are 2 types of assignments with different grade types,
# the gateway quizzes may have multiple scores for multiple tries,
# hence they're returned as an array of score records.
sub getGradeRecords
{
	my ($self, $set, $db, $userid) = @_;
	my $setName = $set->set_id();

	if (defined($set->assignment_type) &&
		$set->assignment_type =~ /gateway/)
	{ # this set allows multiple attempts and can record many scores
		# get all attempts
		my @vList = $db->listSetVersions($userid,$setName);
		my @setVersions = $db->getMergedSetVersions(
			map {[$userid, $setName, $_]} @vList );

		# calculate and store score for each attempt
		my @scores = map {$self->getGradeRecord($db,$_,$userid,1)} @setVersions;
		my $bestScore = $scores[0];
		foreach my $score (@scores) {
			if ($score->{score} > $bestScore->{score}) {
				$bestScore = $score;
			}
		}
		return $bestScore;
	}
	else
	{ # only one score will be recorded for this set
		return $self->getGradeRecord($db, $set, $userid, 0);
	}
}

# Return a hash of grade attributes for user's set. The hash
# is composed of 3 elements:
# status - whether the user has attempted this assignment yet
# totalRight - how many points the user got for answering correctly
# total - total number of points possible
sub getGradeRecord
{
	my ($self, $db, $set, $userid, $isVersioned) = @_;
	my ($status, $totalRight, $total) =
		$self->grade_set($db, $set, $userid, $isVersioned);
	my $score = {
		status => $status,
		totalRight => $totalRight,
		total => $total,
		score => $self->getScore($totalRight, $total),
		lis_source_did => $set->lis_source_did()
	};
	return $score;
}

sub getScore
{
	my ($self, $totalRight, $total) = @_;
	if ($total <= 0 || $totalRight < 0) {
		return 0;
	} elsif ($totalRight > $total) {
		return 1;
	}
	return sprintf("%.5f", $totalRight/$total);
}

# Get the grades for a set.
# Taken and modified from ContentGenerator/Grades.pm
# Since we only want the final grade, it's a lot simpler than
# the Grades.pm version.
sub grade_set
{
	my ($self, $db, $set, $studentName, $setIsVersioned) = @_;

	my $setID = $set->set_id();

	my $status = 0;
	my $totalRight = 0;
	my $total      = 0;

	# DBFIXME: to collect the problem records, we have to know 
	#    which merge routines to call.  Should this really be an 
	#    issue here?  That is, shouldn't the database deal with 
	#    it invisibly by detecting what the problem types are?  
	#    oh well.

	my @problemRecords;

	if ( $setIsVersioned ) 
	{
		# use versioned problems instead (assume that each version has 
		# the same number of problems.
		@problemRecords = $db->getAllMergedProblemVersions( $studentName, $setID, $set->version_id );
	}
	else 
	{ 
		@problemRecords = $db->getAllMergedUserProblems( $studentName, $setID );
	}

	foreach my $problemRecord (@problemRecords) {
		unless (defined($problemRecord) ){
			# warn "Can't find record for problem $prob in set $setName for $student";
			# FIXME check the legitimate reasons why a student record might not be defined
			next;
		}

		$status           = $problemRecord->status || 0;

		# sanity check that the status (score) is 
		# between 0 and 1
		my $valid_status = ($status>=0 && $status<=1)?1:0;

		my $probValue     = $problemRecord->value;
		$probValue        = 1 unless defined($probValue) and $probValue ne "";  # FIXME?? set defaults here?
		$total           += $probValue;
		$totalRight += $self->round_score($status*$probValue) if $valid_status;

	}  # end of problem record loop

	return($status, $totalRight, $total);
}

# Taken and modified from ContentGenerator/Grades.pm
# Modified to be a class method.
sub round_score
{
	my ($self, $ret) = @_;
	return $ret;
}

1;
