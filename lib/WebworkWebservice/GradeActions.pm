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
		# get this user's version of the set
		my $set = $db->getMergedSet($userid, $setid);
		# retrieve grades using this user's set version
		my $setName = $set->set_id;
		$scores{$userid} = getGradeRecords($self, $set, $db, $userid);
	}

	$out->{'grades'} = \%scores;
	debug("Grades done: ". Dumper($out));

	return $out;
}

#### Helper Functions ####

# Get grade records for a user's problem set
# There are 2 types of assignments with different grade types,
# the gateway quizzes may have multiple scores for multiple tries,
# hence they're returned as an array of score records.
sub getGradeRecords
{
	my ($self, $set, $db, $userid) = @_;
	my $setName = $set->set_id;

	if (defined($set->assignment_type) && 
		$set->assignment_type =~ /gateway/) 
	{ # this set allows multiple attempts and can record many scores 
		# get all attempts
		my @vList = $db->listSetVersions($userid,$setName);
		my @setVersions = $db->getMergedSetVersions( 
			map {[$userid, $setName, $_]} @vList );

		# calculate and store score for each attempt
		my @scores =
			map {getGradeRecord($self, $db, $set, $userid, 1)} @setVersions;
		return \@scores;
	}
	else 
	{ # only one score will be recorded for this set
		return getGradeRecord($self, $db, $set, $userid, 0);
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
	return grade_set($self, $db, $set, $userid, $isVersioned);
}

sub grade_set {
	my ($self, $db, $set, $studentName, $setIsVersioned) = @_;

	my $setID = $set->set_id;

	my $status = 0;
	my $longStatus = '';
	my $string     = '';
	my $twoString  = '';
	my $totalRight = 0;
	my $total      = 0;
	my $num_of_attempts = 0;

	debug("Begin collecting problems for set $setID");
	# DBFIXME: to collect the problem records, we have to know 
	#    which merge routines to call.  Should this really be an 
	#    issue here?  That is, shouldn't the database deal with 
	#    it invisibly by detecting what the problem types are?  
	#    oh well.

	my @problemRecords = $db->getAllMergedUserProblems( $studentName, $setID );
	my $num_of_problems  = @problemRecords || 0;
	my $max_problems     = defined($num_of_problems) ? $num_of_problems : 0; 

	if ( $setIsVersioned ) {
		@problemRecords = $db->getAllMergedProblemVersions( $studentName, $setID, $set->version_id );
	}   # use versioned problems instead (assume that each version has the same number of problems.

	debug("End collecting problems for set $setID");

	####################
	# Resort records
	#####################
	@problemRecords = sort {$a->problem_id <=> $b->problem_id }  @problemRecords;

	# for gateway/quiz assignments we have to be careful about 
	#    the order in which the problems are displayed, because
	#    they may be in a random order
	if ( $set->problem_randorder ) {
		my @newOrder = ();
		my @probOrder = (0..$#problemRecords);
		# we reorder using a pgrand based on the set psvn
		my $pgrand = PGrandom->new();
		$pgrand->srand( $set->psvn );
		while ( @probOrder ) { 
			my $i = int($pgrand->rand(scalar(@probOrder)));
			push( @newOrder, $probOrder[$i] );
			splice(@probOrder, $i, 1);
		}
		# now $newOrder[i] = pNum-1, where pNum is the problem
		#    number to display in the ith position on the test
		#    for sorting, invert this mapping:
		my %pSort = map {($newOrder[$_]+1)=>$_} (0..$#newOrder);

		@problemRecords = sort {$pSort{$a->problem_id} <=> $pSort{$b->problem_id}} @problemRecords;
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
		my  $attempted    = $problemRecord->attempted;
		my $num_correct   = $problemRecord->num_correct || 0;
		my $num_incorrect = $problemRecord->num_incorrect   || 0;
		$num_of_attempts  += $num_correct + $num_incorrect;

		$ret->{$pgfile}{'status'} = $status;
		$ret->{$pgfile}{'attempted'} = $attempted;
		$ret->{$pgfile}{'numCorrect'} = $num_correct;
		$ret->{$pgfile}{'numIncorrect'} = $num_incorrect;

#######################################################
		# This is a fail safe mechanism that makes sure that
		# the problem is marked as attempted if the status has
		# been set or if the problem has been attempted
		# DBFIXME this should happen in the database layer, not here!
		if (!$attempted && ($status || $num_correct || $num_incorrect )) {
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
			$longStatus     = '.';
		} elsif   ($valid_status) {
			$longStatus     = int(100*$status+.5);
			$longStatus='C' if ($longStatus==100);
		} else	{
			$longStatus 	= 'X';
		}

		$string          .= threeSpaceFill($longStatus);
		$twoString       .= threeSpaceFill($num_incorrect);
		my $probValue     = $problemRecord->value;
		$probValue        = 1 unless defined($probValue) and $probValue ne "";  # FIXME?? set defaults here?
		$total           += $probValue;
		$totalRight      += round_score($status*$probValue) if $valid_status;


	}  # end of problem record loop


	$ret->{'total'} = {
		status => $status,
		totalRight => $totalRight,
		total => $total,
		numAttempts => $num_of_attempts
	};

	return $ret;
}


# Utility functions from ContentGenerator/Grades.pm
sub threeSpaceFill {
	my $num = shift @_ || 0;

	if (length($num)<=1) {return "$num".'&nbsp;&nbsp;';}
	elsif (length($num)==2) {return "$num".'&nbsp;';}
	else {return "## ";}
}

sub round_score {
	return shift;
}

1;
