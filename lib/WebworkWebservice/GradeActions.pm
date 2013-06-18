#!/usr/local/bin/perl -w 
use strict;
use warnings;

package WebworkWebservice::GradeActions;

use WebworkWebservice;
use base qw(WebworkWebservice); 

use WeBWorK::DB;
use WeBWorK::Debug;
use WeBWorK::CourseEnvironment;
use WeBWorK::Localize;
use WeBWorK::Utils::Grades qw/list_set_versions/;

use Data::Dumper;
use JSON;
use MIME::Base64 qw( encode_base64 decode_base64);

# really only 1 use case for now, given an assignment or gateway quiz, get 
# detailed grade information for all users for that assignment/quiz
# * for each question and for each user
# ** # of attempts
# ** got it right or not 
# Since there is an existing method of listing problem sets for a course, we
# can just reuse that and decrease the stuff we have to implement.
# Now, it's just get the grades for students given a set
# 3 limits:
# - want students only
# - want a certain set
# - want more detail than just total grade, so this is a more detailed breakdown
# for each student, determine if they have any attempts at this assignment, if
# so, get the grades, if not, skip
sub getDetailedSetGrades
{
	my ($self, $params) = @_;
	my $out = {};
	my $db = $self->{db};
	my $ce = $self->{ce};

	my $setid = $params->{'set_id'};

	debug(("-" x 80) . "\n");
	debug("Attempting to get grades for set: $setid.");

	debug("First, retrieve users assigned to this set.");
	my @userIDs = $db->listSetUsers($setid);

	my %scores = ();
	foreach my $userid (@userIDs)
	{ # grab the grades for each user
		my $studentRecord = $db->getUser($userid) 
			or die "record for user $userid not found";
		# skip if we're not supposed to include this user in states
		next unless $ce->status_abbrev_has_behavior($studentRecord->status, "include_in_stats");
		# get this user's version of the set
		my $set = $db->getMergedSet($userid, $setid);
		# retrieve grades using this user's set version
		my $setName = $set->set_id;
		$scores{$userid} = getGrades($self, $db, $set, $userid);
	}

	$out->{'grades'} = \%scores;
	debug("Grades done.");

	return $out;
}

#### Helper Functions ####

# Get grade records for a user's problem set
# There are 2 types of assignments with different grade types,
# the gateway quizzes may have multiple scores for multiple tries,
# hence they're returned as an array of score records.
# 
# Non-versioned sets returns a hash.
# Versioned sets will return an array of hashes.
# 
# Versioned sets comes from quizzes where multiple attempts are allowed
# 
# Both version will return the same hash structure:
# PG File Path ->
#	status - Has the user answered this question correctly? 
#	numIncorrect - Number of times the user answered incorrectly.
#	numCorrect - Number of times the user answered correctly.
#	attempted - 1 if the user has attempted this question 0 otherwise
# Total ->
#	version - this field exists if we're checking a versioned quiz where a user
#		can attempt a quiz multiple times.
#	numAttempts - Total number of attempts for every problem.
#	totalRight - Number of questions that the user has gotten completely right.
#	status - How many questions the user got right. Usually, each question
#		counts for 1 point. If a question has multiple parts, then each part
#		that the user got right would count as a fraction of the total 1 point.
#	score - Score out of 100 that the user got for this assignment
#	total - total number of points possible
# 
sub getGrades
{
	my ($self, $db, $set, $userid) = @_;

	my $isVersioned = 0;
	if (defined($set->assignment_type) && 
		$set->assignment_type =~ /gateway/) 
	{ # this set allows multiple attempts and can record many scores 
		$isVersioned = 1;
	}

	# Grab set version numbers
	my( $ra_allSetVersionNames, $notAssignedSet) = list_set_versions($db, $userid, $set->set_id, $isVersioned);
	my @allSetVersionNames = @{$ra_allSetVersionNames};

	my $ret;
	if ($isVersioned) {
		$ret = ();
	}
	else {
		$ret = {};
	}

	foreach my $setName ( @allSetVersionNames ) {

		my $status          = 0;
		my $longStatus      = '';
		my $string          = '';
		my $twoString       = '';
		my $totalRight      = 0;
		my $total           = 0;
		my $total_num_of_attempts_for_set = 0;
		my %h_problemData   = ();
		my $num_of_attempts;
		my $num_of_problems;

		my $set;
		my $userSet;
		my $version;
		if ( $isVersioned ) {
			my ($setN,$vNum) = ($setName =~ /(.+),v(\d+)$/);
			$version = $vNum;
			# we'll also need information from the set
			#    as we set up the display below, so get
			#    the merged userset as well
			$set = $db->getMergedSetVersion($userid, $setN, $vNum);
			$userSet = $set;
			$setName = $setN;
		} else {
			$set = $db->getMergedSet( $userid, $setName );

		}

		# Create an empty set if we didn't get one? Not sure why this is here.
		unless ( ref($set) ) {
			$set = new WeBWorK::DB::Record::UserSet;
			$set->set_id($setName);
		}

		my $grades = grade_set( $db, $set, $setName, $userid, $isVersioned);
		if ($isVersioned) {
			$grades->{'total'}{'version'} = $version;
			push(@{$ret}, $grades);
		}
		else {
			$ret = $grades;
		}
	}

	return $ret;
}

# grab grades for a single set
sub grade_set {

	my ($db, $set, $setName, $studentName, $setIsVersioned) = @_;

	my $setID = $set->set_id();  #FIXME   setName and setID should be the same

	my $status = 0;
	my $longStatus = '';
	my $string     = '';
	my $totalRight = 0;
	my $total      = 0;
	my $num_of_attempts = 0;

	debug("Collecting problems for user $studentName and set $setName");
	# DBFIXME: to collect the problem records, we have to know 
	#    which merge routines to call.  Should this really be an 
	#    issue here?  That is, shouldn't the database deal with 
	#    it invisibly by detecting what the problem types are?  
	#    oh well.

	my @problemRecords = $db->getAllMergedUserProblems( $studentName, $setID );
	my $num_of_problems  = @problemRecords || 0;
	if ( $setIsVersioned ) {
		@problemRecords =  $db->getAllMergedProblemVersions( $studentName, $setID, $set->version_id );
	}

	#######################################################
	# construct header

	my $ret = {};

	foreach my $problemRecord (@problemRecords) {
		my $prob = $problemRecord->problem_id;

		unless (defined($problemRecord) ){
			# warn "Can't find record for problem $prob in set $setName for $student";
			# FIXME check the legitimate reasons why a student record might not be defined
			next;
		}

		my $pgfile = $problemRecord->source_file;
		debug("Processing problem: $prob | $pgfile");

		$status           = $problemRecord->status || 0;
		my $attempted     = $problemRecord->attempted;
		my $num_correct   = $problemRecord->num_correct || 0;
		my $num_incorrect = $problemRecord->num_incorrect   || 0;
		$num_of_attempts  = $num_correct + $num_incorrect;

		$ret->{$pgfile}{'status'} = $status;
		$ret->{$pgfile}{'attempted'} = $attempted;
		$ret->{$pgfile}{'numCorrect'} = $num_correct;
		$ret->{$pgfile}{'numIncorrect'} = $num_incorrect;

#######################################################
		# This is a fail safe mechanism that makes sure that
		# the problem is marked as attempted if the status has
		# been set or if the problem has been attempted
		# DBFIXME this should happen in the database layer, not here!
		if (!$attempted && ($status || $num_of_attempts)) {
			$attempted = 1;
			$problemRecord->attempted('1');
			# DBFIXME: this is another case where it 
			#    seems we shouldn't have to check for 
			#    which routine to use here...
			if ( $setIsVersioned ) {
				$db->putProblemVersion($problemRecord);
			} else {
				$db->putUserProblem($problemRecord );
			}
		}
######################################################			

		# sanity check that the status (score) is 
		# between 0 and 1
		my $valid_status = ($status>=0 && $status<=1)?1:0;

		###########################################
		# Determine the string $longStatus which 
		# will display the student's current score
		###########################################

		if (!$attempted){
			$longStatus     = 0;
		} elsif   ($valid_status) {
			$longStatus     =  int(100*$status+.5) ;
		} else	{
			$longStatus 	= '-';
		}

		my $probValue   =  $problemRecord->value;
		$probValue      =  1 unless defined($probValue) and $probValue ne "";  # FIXME?? set defaults here?
		$total          += $probValue;
		$totalRight     += round_score($status*$probValue) if $valid_status;
	}

	$ret->{'total'} = {
		status => $status,
		totalRight => $totalRight,
		total => $total,
		numAttempts => $num_of_attempts,
		score => $longStatus
	};

	return $ret;
}

# Utility functions from ContentGenerator/Grades.pm
sub round_score {
	return shift;
}

1;
