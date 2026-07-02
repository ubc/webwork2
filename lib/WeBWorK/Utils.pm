package WeBWorK::Utils;
use Mojo::Base 'Exporter', -signatures;

use Email::Sender::Transport::SMTP;
use Mojo::JSON qw(from_json to_json);
use Mojo::Util qw(b64_encode b64_decode encode decode);
use Storable   qw(nfreeze thaw);

# UBC custom: WeBWorK::Utils keeps the UBC 5-return grade_set variant (adds
# num_of_attempts); the upstream 4-return variants live in WeBWorK::Utils::Sets.
# These imports are needed by the UBC grade_set/grade_gateway/grade_all_sets below.
use WeBWorK::Utils::DateTime qw(after);
use WeBWorK::Utils::JITAR    qw(jitar_id_to_seq jitar_problem_adjusted_status);

our @EXPORT_OK = qw(
	runtime_use
	trim_spaces
	fix_newlines
	encodeAnswers
	decodeAnswers
	encode_utf8_base64
	decode_utf8_base64
	nfreeze_base64
	thaw_base64
	min
	max
	wwRound
	cryptPassword
	utf8Crypt
	undefstr
	sortByName
	sortAchievements
	grade_set
	grade_gateway
	grade_all_sets
	not_blank
	role_and_above
	fetchEmailRecipients
	processEmailMessage
	createEmailSenderTransportSMTP
	generateURLs
	getAssetURL
	x
);

sub runtime_use ($module, @import_list) {
	my $package = (caller)[0];    # import into caller's namespace

	my $import_string;
	if (@import_list == 1 && ref($import_list[0]) eq 'ARRAY' && @{ $import_list[0] } == 0) {
		$import_string = '';
	} else {
		# \Q = quote metachars \E = end quoting
		$import_string = "import $module " . join(',', map {qq|"\Q$_\E"|} @import_list);
	}
	eval "package $package; require $module; $import_string";
	die $@ if $@;
	return;
}

sub trim_spaces ($string) {
	return '' unless $string;
	return $string =~ s/^\s*|\s*$//gr;
}

sub fix_newlines ($in) {
	return $in =~ s/\r\n?/\n/gr;
}

sub encodeAnswers ($hash, $order) {
	my @ordered_hash;
	for my $key (@$order) {
		push @ordered_hash, $key, $hash->{$key};
	}
	return to_json(\@ordered_hash);
}

sub decodeAnswers ($serialized) {
	return unless $serialized;
	if ($serialized =~ /^\[/ && $serialized =~ /\]$/) {
		# Assuming this is JSON encoded
		my @array_data = @{ from_json($serialized) };
		return @array_data;
	} else {
		# Fall back to old Storable::thaw based code
		my $array_ref = eval { thaw($serialized) };
		if ($@ || !defined $array_ref) {
			return;
		} else {
			return @{$array_ref};
		}
	}
}

sub encode_utf8_base64 ($in) {
	return b64_encode(encode('UTF-8', $in));
}

sub decode_utf8_base64 ($in) {
	return decode('UTF-8', b64_decode($in));
}

sub nfreeze_base64 ($in) {
	return b64_encode(nfreeze($in));
}

sub thaw_base64 ($string) {
	my $result;

	eval { $result = thaw(b64_decode($string)); };

	if ($@) {
		warn('Deleting corrupted achievement data.');
		return {};
	} else {
		return $result;
	}

}

sub min (@items) {
	my $min = (shift @items) // 0;
	for my $item (@items) {
		$min = $item if ($item < $min);
	}
	return $min;
}

sub max (@items) {
	my $max = (shift @items) // 0;
	for my $item (@items) {
		$max = $item if ($item > $max);
	}
	return $max;
}

sub wwRound ($places, $float) {
	my $factor = 10**$places;
	return int($float * $factor + 0.5) / $factor;
}

sub cryptPassword ($clearPassword) {
	# Use an SHA512 salt with 16 digits
	my $salt = '$6$';
	for (my $i = 0; $i < 16; $i++) {
		$salt .= ('.', '/', '0' .. '9', 'A' .. 'Z', 'a' .. 'z')[ rand 64 ];
	}

	return utf8Crypt(trim_spaces($clearPassword), $salt);
}

sub utf8Crypt ($clearPassword, $hash) {
	# Wrap crypt in an eval to catch any "Wide character in crypt" errors.
	# If crypt fails due to a wide character, encode to UTF-8 before calling crypt.
	my $cryptedPassword = '';
	eval { $cryptedPassword = crypt($clearPassword, $hash); };
	$cryptedPassword = crypt(encode('UTF-8', $clearPassword), $hash) if $@ && $@ =~ /Wide char/;
	return $cryptedPassword;
}

sub undefstr ($default, @values) {
	return map { defined $_ ? $_ : $default } @values[ 0 .. $#values ];
}

################################################################################
# Sorting
################################################################################

sub sortByName ($field, @items) {
	my %itemsByIndex;
	if (ref($field) eq 'ARRAY') {
		for my $item (@items) {
			my $key = '';
			for (@$field) {
				$key .= $item->$_;    # in this case we assume
			}    #    all entries in @$field
			$itemsByIndex{$key} = $item;    #  are defined.
		}
	} else {
		%itemsByIndex = map { defined $field ? $_->$field : $_ => $_ } @items;
	}

	my @sKeys = sort {
		return $a cmp $b if (uc($a) eq uc($b));

		my @aParts = split m/(?<=\D)(?=\d)|(?<=\d)(?=\D)/, $a;
		my @bParts = split m/(?<=\D)(?=\d)|(?<=\d)(?=\D)/, $b;

		while (@aParts && @bParts) {
			my $aPart    = shift @aParts;
			my $bPart    = shift @bParts;
			my $aNumeric = $aPart =~ m/^\d*$/;
			my $bNumeric = $bPart =~ m/^\d*$/;

			# numbers should come before words
			return -1 if $aNumeric  && !$bNumeric;
			return +1 if !$aNumeric && $bNumeric;

			# both have the same type
			if ($aNumeric && $bNumeric) {
				next if $aPart == $bPart;    # check next pair
				return $aPart <=> $bPart;    # compare numerically
			} else {
				next if uc($aPart) eq uc($bPart);    # check next pair
				return uc($aPart) cmp uc($bPart);    # compare alphabetically
			}
		}
		return +1 if @aParts;    # a has more sections, should go second
		return -1 if @bParts;    # a had fewer sections, should go first
	} (keys %itemsByIndex);

	return map { $itemsByIndex{$_} } @sKeys;
}

sub sortAchievements (@achievements) {
	# First sort by achievement id.
	@achievements = sort { uc($a->{achievement_id}) cmp uc($b->{achievement_id}) } @achievements;

	# Next sort by number.
	@achievements = sort { ($a->number || 0) <=> ($b->number || 0) } @achievements;

	# Finally sort by category. Always place level achievements last.
	@achievements = sort {
		if ($a->{category} eq 'level' && $b->{category} eq 'level') {
			return 0;
		} elsif ($a->{category} eq 'level') {
			return 1;
		} elsif ($b->{category} eq 'level') {
			return -1;
		} elsif ($a->number && $b->number) {
			return $a->number <=> $b->number;
		} elsif ($a->{category} eq $b->{category}) {
			return 0;
		} elsif ($a->{category} eq 'secret') {
			return -1;
		} elsif ($b->{category} eq 'secret') {
			return 1;
		} else {
			return $a->{category} cmp $b->{category};
		}
	} @achievements;

	return @achievements;

}

################################################################################
# Validate strings and labels
################################################################################

sub not_blank ($str = undef) {
	return defined $str && $str =~ /\S/;
}

# Given $problem which should be a problem version, getTestProblemPosition returns the 0 based problem number for the
# problem on the test, and the 1 based page number for the page on the test that the problem is on.
sub getTestProblemPosition {
	my ($db, $problem) = @_;

	my $set            = $db->getMergedSetVersion($problem->user_id, $problem->set_id, $problem->version_id);
	my @problemNumbers = $db->listProblemVersions($set->user_id, $set->set_id, $set->version_id);

	my $problemNumber = 0;

	if ($set->problem_randorder) {
		# Find the test problem order using the set psvn for the seed in the same way that the GatewayQuiz module does.
		my @problemOrder = (0 .. $#problemNumbers);
		my $pgrand       = PGrandom->new;
		$pgrand->srand($set->psvn);
		my $count = 0;
		while (@problemOrder) {
			my $index = splice(@problemOrder, int($pgrand->rand(scalar(@problemOrder))), 1);
			if ($problemNumbers[$index] == $problem->problem_id) {
				$problemNumber = $count;
				last;
			}
			++$count;
		}
	} else {
		($problemNumber) = grep { $problemNumbers[$_] == $problem->problem_id } 0 .. $#problemNumbers;
	}

	my $pageNumber;

	# Update startProb and endProb for multipage tests
	if ($set->problems_per_page) {
		$pageNumber = ($problemNumber + 1) / $set->problems_per_page;
		$pageNumber = int($pageNumber) + 1 if int($pageNumber) != $pageNumber;
	} else {
		$pageNumber = 1;
	}

	return ($problemNumber, $pageNumber);
}

sub is_restricted {
	my ($db, $set, $studentName) = @_;

	# all sets open after the due date
	return () if after($set->due_date());

	my $setID = $set->set_id();
	my @needed;

	if ($set->restricted_release) {
		my @proposed_sets  = split(/\s*,\s*/, $set->restricted_release);
		my $required_score = sprintf("%.2f", $set->restricted_status || 0);

		my @good_sets;
		foreach (@proposed_sets) {
			push @good_sets, $_ if $db->existsGlobalSet($_);
		}

		foreach my $restrictor (@good_sets) {
			my $r_score        = 0;
			my $restrictor_set = $db->getGlobalSet($restrictor);

			if ($restrictor_set->assignment_type =~ /gateway/) {
				my @versions =
					$db->getSetVersionsWhere({ user_id => $studentName, set_id => { like => $restrictor . ',v%' } });
				foreach (@versions) {
					my $v_score = grade_set($db, $_, $studentName, 1);

					$r_score = $v_score if ($v_score > $r_score);
				}
			} else {
				$r_score = grade_set($db, $restrictor_set, $studentName, 0);
			}

			# round to evade machine rounding error
			$r_score = sprintf("%.2f", $r_score);
			if ($r_score < $required_score) {
				push @needed, $restrictor;
			}
		}
	}
	return unless @needed;
	return @needed;
}

# Takes in $db, $set, $studentName, $setIsVersioned and returns ($totalCorrect, $total) or the percentage correct.
sub grade_set {
	my ($db, $set, $studentName, $setIsVersioned, $wantProblemDetails) = @_;

	my $totalRight = 0;
	my $total      = 0;

	# This information is also accumulated if $wantProblemDetails is true.
	my $problem_scores             = [];
	my $problem_incorrect_attempts = [];
	# ubc custom - return total number of attempts
	my $num_of_attempts            = 0;

	# DBFIXME: To collect the problem records, we have to know which merge routines to call.  Should this really be an
	# issue here?  That is, shouldn't the database deal with it invisibly by detecting what the problem types are?
	my @problemRecords =
		$setIsVersioned
		? $db->getAllMergedProblemVersions($studentName, $set->set_id, $set->version_id)
		: $db->getAllMergedUserProblems($studentName, $set->set_id);

	# For jitar sets we only use the top level problems.
	if ($set->assignment_type && $set->assignment_type eq 'jitar') {
		my @topLevelProblems;
		for my $problem (@problemRecords) {
			my @seq = jitar_id_to_seq($problem->problem_id);
			push @topLevelProblems, $problem if $#seq == 0;
		}

		@problemRecords = @topLevelProblems;
	}

	if ($wantProblemDetails) {
		# Sort records.  For gateway/quiz assignments we have to be careful about the order in which the problems are
		# displayed, because they may be in a random order.
		if ($set->problem_randorder) {
			my @newOrder;
			my @probOrder = (0 .. $#problemRecords);
			# Reorder using the set psvn for the seed in the same way that the GatewayQuiz module does.
			my $pgrand = PGrandom->new();
			$pgrand->srand($set->psvn);
			while (@probOrder) {
				my $i = int($pgrand->rand(scalar(@probOrder)));
				push(@newOrder, splice(@probOrder, $i, 1));
			}
		  # Now $newOrder[i] = pNum - 1, where pNum is the problem number to display in the ith position on the test for
		  # sorting. Invert this mapping.
			my %pSort = map { $problemRecords[ $newOrder[$_] ]->problem_id => $_ } (0 .. $#newOrder);

			@problemRecords = sort { $pSort{ $a->problem_id } <=> $pSort{ $b->problem_id } } @problemRecords;
		} else {
			# Sort records
			@problemRecords = sort { $a->problem_id <=> $b->problem_id } @problemRecords;
		}
	}

	for my $problemRecord (@problemRecords) {
		my $status = $problemRecord->status || 0;

		# Get the adjusted jitar grade for top level problems if this is a jitar set.
		$status = jitar_problem_adjusted_status($problemRecord, $db) if $set->assignment_type eq 'jitar';

		# Clamp the status value between 0 and 1.
		$status = 0 if $status < 0;
		$status = 1 if $status > 1;

		if ($wantProblemDetails) {
			push(@$problem_scores,             $problemRecord->attempted ? 100 * wwRound(2, $status) : '&nbsp;.&nbsp;');
			push(@$problem_incorrect_attempts, $problemRecord->num_incorrect || 0);
			# ubc custom - record total number of attempts
			my $num_correct   = $problemRecord->num_correct || 0;
			my $num_incorrect = $problemRecord->num_incorrect   || 0;
			$num_of_attempts  = $num_correct + $num_incorrect;
		}

		my $probValue = $problemRecord->value;
		$probValue = 1 unless defined $probValue && $probValue ne '';    # FIXME: Set defaults here?
		$total      += $probValue;
		$totalRight += $status * $probValue;
	}

	if (wantarray) {
		# ubc custom - return total number of attempts, note that we've tacked
		# it on at the end of the returned array. Calls that doesn't know this
		# exist should just ignore it (hopefully), but if the number of elements
		# change upstream, it'll break.
		return ($totalRight, $total, $problem_scores, $problem_incorrect_attempts,
				$num_of_attempts);
	} else {
		return $total ? $totalRight / $total : 0;
	}
}

# Takes in $db, $set, $setName, $studentName,
# and returns ($totalCorrect,$total) or the percentage correct
# for the highest scoring gateway

sub grade_gateway {
	my ($db, $set, $setName, $studentName) = @_;

	my @versionNums = $db->listSetVersions($studentName, $setName);

	my $bestTotalRight = 0;
	my $bestTotal      = 0;

	if (@versionNums) {
		for my $i (@versionNums) {
			my $versionedSet = $db->getSetVersion($studentName, $setName, $i);

			my ($totalRight, $total) = grade_set($db, $versionedSet, $studentName, 1);
			if ($totalRight > $bestTotalRight) {
				$bestTotalRight = $totalRight;
				$bestTotal      = $total;
			}
		}
	}

	if (wantarray) {
		return ($bestTotalRight, $bestTotal);
	} else {
		return 0 unless $bestTotal;
		return $bestTotalRight / $bestTotal;
	}
}

# Takes in $db, $studentName,
# and returns ($totalCorrect,$total) or the percentage correct
# for all sets in the course

sub grade_all_sets {
	my ($db, $studentName) = @_;

	my @setIDs     = $db->listUserSets($studentName);
	my @userSetIDs = map { [ $studentName, $_ ] } @setIDs;
	my @userSets   = $db->getMergedSets(@userSetIDs);

	my $courseTotal      = 0;
	my $courseTotalRight = 0;

	foreach my $userSet (@userSets) {
		next unless (after($userSet->open_date()));
		if ($userSet->assignment_type() =~ /gateway/) {

			my ($totalRight, $total) = grade_gateway($db, $userSet, $userSet->set_id, $studentName);
			$courseTotalRight += $totalRight;
			$courseTotal      += $total;
		} else {
			my ($totalRight, $total) = grade_set($db, $userSet, $studentName, 0);

			$courseTotalRight += $totalRight;
			$courseTotal      += $total;
		}
	}

	if (wantarray) {
		return ($courseTotalRight, $courseTotal);
	} else {
		return 0 unless $courseTotal;
		return $courseTotalRight / $courseTotal;
	}

}

#takes a tree sequence and returns the jitar id
#  This id is specially crafted signed 32 bit integer of the form, in binary
#  SAAAAAAABBBBBBCCCCCCDDDDEEEEFFFF
#  Here A is the level 1 index, B is the level 2 index, and
#  C, D, E and F are the indexes for levels 3 through 6.
#
#  Note:  Level 1 can contain indexes up to 125.  Levels 2 and 3 can contain
#         indxes up to 63.  For levels 4 through
#         six you are limited to 15.

sub seq_to_jitar_id {
	my @seq = @_;

	die("Jitar index 1 must be between 1 and 125")
		unless (defined($seq[0]) && $seq[0] < 126);

	my $id = $seq[0];
	my $ind;

	my @JITAR_SHIFT = @{ JITAR_SHIFT() };

	#shift first index to first two bytes
	$id = $id << $JITAR_SHIFT[0];

	#look for second and third index
	for (my $i = 1; $i < 3; $i++) {
		if (defined($seq[$i])) {
			$ind = $seq[$i];
			die("Jitar index " . ($i + 1) . " must be less than 63")
				unless $ind < 63;

			#shift index and or it with id to put it in right place
			$ind = $ind << $JITAR_SHIFT[$i];
			$id  = $id | $ind;
		}
	}

	#look for remaining 3 index's
	for (my $i = 3; $i < 6; $i++) {
		if (defined($seq[$i])) {
			$ind = $seq[$i];
			die("Jitar index " . ($i + 1) . " must be less than 16")
				unless $ind < 16;

			#shift index and or it with id to put it in right place
			$ind = $ind << $JITAR_SHIFT[$i];
			$id  = $id | $ind;
		}
	}

	return $id;
}

# Takes a jitar_id and returns the tree sequence
#  Jitar id's have the format described above.
sub jitar_id_to_seq {
	my $id = shift;
	my $ind;
	my @seq;

	my @JITAR_SHIFT = @{ JITAR_SHIFT() };
	my @JITAR_MASK  = @{ JITAR_MASK() };

	for (my $i = 0; $i < 6; $i++) {
		$ind = $id;
		#use a mask to isolate only the bits we want for this index
		# and shift them to get the index
		$ind = $ind & $JITAR_MASK[$i];
		$ind = $ind >> $JITAR_SHIFT[$i];

		#quit if we dont have a nonzero index
		last unless $ind;

		$seq[$i] = $ind;
	}

	return @seq;
}

# Takes in ($db, $userID, $setID, $problemID) and returns 1 if the
# problem is hidden.  The problem is hidden if the number of attempts
# on the parent problem is greater than att_to_open_children, or if the user
# has run out of attempts.  Everything is opened up after the due date

sub is_jitar_problem_hidden {
	my ($db, $userID, $setID, $problemID) = @_;

	die "Not enough arguments.  Use is_jitar_problem_hidden(db,userID,setID,problemID)"
		unless ($db && $userID && $setID && $problemID);

	my $mergedSet = $db->getMergedSet($userID, $setID);

	unless ($mergedSet) {
		warn "Couldn't get set $setID for user $userID from the database";
		return 0;
	}

	# only makes sense for jitar sets
	return 0 unless ($mergedSet->assignment_type eq 'jitar');

	# the set opens everything up after the due date.
	return 0 if (after($mergedSet->due_date));

	my @idSeq       = jitar_id_to_seq($problemID);
	my @parentIDSeq = @idSeq;

	unless ($#parentIDSeq != 0) {
		#this means we are at a top level problem and this check doesnt make sense
		return 0;
	}

	pop @parentIDSeq;
	while (@parentIDSeq) {

		my $parentProbID = seq_to_jitar_id(@parentIDSeq);

		my $userParentProb = $db->getMergedProblem($userID, $setID, $parentProbID);

		unless ($userParentProb) {
			warn "Couldn't get problem $parentProbID for user $userID and set $setID from the database";
			return 0;
		}

		# the child problems are closed unless the number of incorrect attempts is above the
		# attempts to open children, or if they have exausted their max_attempts
		# if att_to_open_children is -1 we just use max attempts
		# if max_attempts is -1 then they are always less than max attempts
		if (
			(
				$userParentProb->att_to_open_children == -1
				|| $userParentProb->num_incorrect() < $userParentProb->att_to_open_children()
			)
			&& ($userParentProb->max_attempts == -1
				|| $userParentProb->num_incorrect() < $userParentProb->max_attempts())
			)
		{
			return 1;
		}
		pop @parentIDSeq;
	}

	# if we get here then all of the parents are open so the problem is open.
	return 0;
}

# takes in ($db, $ce, $userID, $setID, $problemID) and returns 1 if the jitar problem is closed
# jitar problems are closed if the restrict_prob_progression variable is set on the set
# and if the previous problem is closed, or hasn't been finished yet.
# The first problem in a level is always open.

sub is_jitar_problem_closed {
	my ($db, $ce, $userID, $setID, $problemID) = @_;

	die "Not enough arguments.  Use is_jitar_problem_closed(db,userID,setID,problemID)"
		unless ($db && $ce && $userID && $setID && $problemID);

	my $mergedSet = $db->getMergedSet($userID, $setID);

	unless ($mergedSet) {
		warn "Couldn't get set $setID for user $userID from the database";
		return 0;
	}

	# return 0 unless we are a restricted jitar set
	return 0 unless ($mergedSet->assignment_type eq 'jitar' && $mergedSet->restrict_prob_progression());

	# the set opens everything up after the due date.
	return 0 if (after($mergedSet->due_date));

	my $prob;
	my $id;
	my @idSeq     = jitar_id_to_seq($problemID);
	my @parentSeq = @idSeq;

	# problems are automatically closed if their parents are closed
	#this means we cant find a previous problem to test against so we are open as long as the parent is open
	pop(@parentSeq);

	#if we can't get a parent problem then this is a top level problem and we
	# we just check the previous.
	if (@parentSeq) {
		$id = seq_to_jitar_id(@parentSeq);
		if (is_jitar_problem_closed($db, $ce, $userID, $setID, $id)) {
			return 1;
		}
	}

	# if the parent is open then we are open if the previous
	# problem has been "completed" or, if we are the first problem in this level

	do {
		$idSeq[$#idSeq]--;

		# in this case we are the first problem in the level
		if ($idSeq[$#idSeq] == 0) {
			return 0;
		}

		$id = seq_to_jitar_id(@idSeq);
	} until ($db->existsUserProblem($userID, $setID, $id));

	$prob = $db->getMergedProblem($userID, $setID, $id);

	# we have to test against the target status in case the student
	# is working in the reduced scoring period
	my $targetStatus = 1;
	if ($ce->{pg}{ansEvalDefaults}{enableReducedScoring}
		&& $mergedSet->enable_reduced_scoring
		&& after($mergedSet->reduced_scoring_date))
	{
		$targetStatus = $ce->{pg}{ansEvalDefaults}{reducedScoringValue};
	}

	if (abs(jitar_problem_adjusted_status($prob, $db) - $targetStatus) < .001
		|| jitar_problem_finished($prob, $db))
	{

		# either the previous problem is 100% or is finished
		return 0;
	} else {

		#in this case the previous problem is hidden
		return 1;
	}

}

# returns the adjusted status for a jitar problem.
# this is either the problems status or it is the greater of the
# status and the score generated by taking the weighted average of all
# child problems that have the "counts_parent_grade" flag set

sub jitar_problem_adjusted_status {
	my ($userProblem, $db) = @_;

	#this is goign to happen often enough that the check saves time
	return 1 if $userProblem->status == 1;

	my @problemSeq = jitar_id_to_seq($userProblem->problem_id);

	my @problemIDs = $db->listUserProblems($userProblem->user_id, $userProblem->set_id);

	my @weights;
	my @scores;

ID: foreach my $id (@problemIDs) {
		my @seq = jitar_id_to_seq($id);

		#check and see if this is a child
		# it has to be one level deper
		next unless $#seq == $#problemSeq + 1;

		# and it has to equal @seq up to the penultimate index
		for (my $i = 0; $i <= $#problemSeq; $i++) {
			next ID unless $seq[$i] == $problemSeq[$i];
		}

		#check to see if this counts towards the parent grade
		my $problem = $db->getMergedProblem($userProblem->user_id, $userProblem->set_id, $id);

		die "Couldn't get problem $id for user "
			. $userProblem->user_id
			. " and set "
			. $userProblem->set_id
			. " from the database"
			unless $problem;

		# skip if it doesnt
		next unless $problem->counts_parent_grade();

		# if it does count then add its adjusted status to the grading array
		push @weights, $problem->value;
		push @scores,  jitar_problem_adjusted_status($problem, $db);
	}

	# if no children count towards the problem grade return status
	return $userProblem->status unless (@weights && @scores);

	# if children do count then return the larger of the two (?)
	my $childScore  = 0;
	my $totalWeight = 0;
	for (my $i = 0; $i <= $#scores; $i++) {
		$childScore  += $scores[$i] * $weights[$i];
		$totalWeight += $weights[$i];
	}

	$childScore = $childScore / $totalWeight;

	if ($childScore > $userProblem->status) {
		return $childScore;
	} else {
		return $userProblem->status;
	}
}

# returns 1 if the given problem is "finished"  This happens when the problem attempts have
# been maxed out, and the attempts of any children with the "counts_to_parent_grade" also
# have their attemtps maxed out.  (In other words if the grade can't be raised any more)

sub jitar_problem_finished {
	my ($userProblem, $db) = @_;

	# the problem is open if you can still make attempts and you dont have a 100%
	return 0
		if (
			$userProblem->status < 1
			&& ($userProblem->max_attempts == -1
				|| $userProblem->max_attempts > ($userProblem->num_correct + $userProblem->num_incorrect))
		);

	# find children
	my @problemSeq = jitar_id_to_seq($userProblem->problem_id);

	my @problemIDs = $db->listUserProblems($userProblem->user_id, $userProblem->set_id);

ID: foreach my $id (@problemIDs) {
		my @seq = jitar_id_to_seq($id);

		#check and see if this is a child
		next unless $#seq == $#problemSeq + 1;
		for (my $i = 0; $i <= $#problemSeq; $i++) {
			next ID unless $seq[$i] == $problemSeq[$i];
		}

		#check to see if this counts towards the parent grade
		my $problem = $db->getMergedProblem($userProblem->user_id, $userProblem->set_id, $id);

		die "Couldn't get problem $id for user "
			. $userProblem->user_id
			. " and set "
			. $userProblem->set_id
			. " from the database"
			unless $problem;

		# if this doesn't count then we dont need to worry about it
		next unless $problem->counts_parent_grade();

		#if it does then see if the problem is finished
		# if it isn't then the parent isnt finished either.
		return 0 unless jitar_problem_finished($problem, $db);

	}

	# if we got here then the problem is finished
	return 1;
}

# Get the array of all permission levels at or above a given level
sub role_and_above {
	my ($userRoles, $role) = @_;
	my $role_array = [$role];
	for my $userRole (keys %$userRoles) {
		push @$role_array, $userRole if ($userRoles->{$userRole} > $userRoles->{$role});
	}
	return $role_array;
}

sub fetchEmailRecipients ($c, $permissionType, $sender = undef) {
	my $db    = $c->db;
	my $ce    = $c->ce;
	my $authz = $c->authz;

	my @recipients;
	push(@recipients, @{ $ce->{mail}{feedbackRecipients} }) if ref($ce->{mail}{feedbackRecipients}) eq 'ARRAY';

	return @recipients unless $permissionType && defined $ce->{permissionLevels}{$permissionType};

	my $roles =
		ref $ce->{permissionLevels}{$permissionType} eq 'ARRAY'
		? $ce->{permissionLevels}{$permissionType}
		: role_and_above($ce->{userRoles}, $ce->{permissionLevels}{$permissionType});
	my @rolePermissionLevels = map { $ce->{userRoles}{$_} } grep { defined $ce->{userRoles}{$_} } @$roles;
	return @recipients unless @rolePermissionLevels;

	my $user_ids = [ map { $_->user_id } $db->getPermissionLevelsWhere({ permission => \@rolePermissionLevels }) ];

	push(
		@recipients,
		map { $_->rfc822_mailbox } $db->getUsersWhere({
			user_id       => $user_ids,
			email_address => { '!=', undef },
			$ce->{feedback_by_section}
				&& defined $sender ? (section => ($sender->section eq '' ? undef : $sender->section)) : ()
		})
	);

	return @recipients;
}

sub processEmailMessage ($text, $user_record, $STATUS, $merge_data, $for_preview = 0) {
	# User macros that can be used in the email message
	my $SID        = $user_record->student_id;
	my $FN         = $user_record->first_name;
	my $LN         = $user_record->last_name;
	my $SECTION    = $user_record->section;
	my $RECITATION = $user_record->recitation;
	my $EMAIL      = $user_record->email_address;
	my $LOGIN      = $user_record->user_id;

	# Get record from merge data.
	my @COL = defined($merge_data->{$SID}) ? @{ $merge_data->{$SID} } : ();
	unshift(@COL, '');    # This makes COL[1] the first column.

	# For safety, only evaluate special variables.
	my $msg = $text;
	$msg =~ s/\$SID/$SID/g;
	$msg =~ s/\$LN/$LN/g;
	$msg =~ s/\$FN/$FN/g;
	$msg =~ s/\$STATUS/$STATUS/g;
	$msg =~ s/\$SECTION/$SECTION/g;
	$msg =~ s/\$RECITATION/$RECITATION/g;
	$msg =~ s/\$EMAIL/$EMAIL/g;
	$msg =~ s/\$LOGIN/$LOGIN/g;

	if (defined $COL[1]) {
		$msg =~ s/\$COL\[(\-?\d+)\]/$COL[$1]/g;
	} else {
		$msg =~ s/\$COL\[(\-?\d+)\]//g;
	}

	$msg =~ s/\r//g;

	if ($for_preview) {
		my @preview_COL = @COL;
		shift @preview_COL;    # Shift of the added empty string for preview.
		return $msg,
			join(' ',
				'', (map { "COL[$_]" . '&nbsp;' x (3 - length $_) } 1 .. $#COL),
				'<br>', (map { $_ =~ s/\s/&nbsp;/gr } map { sprintf('%-8.8s', $_); } @preview_COL));
	} else {
		return $msg;
	}
}

sub createEmailSenderTransportSMTP ($ce) {
	return Email::Sender::Transport::SMTP->new({
		host => $ce->{mail}{smtpServer},
		ssl  => $ce->{mail}{tls_allowed} // 0,
		defined $ce->{mail}->{smtpPort}       ? (port          => $ce->{mail}{smtpPort})       : (),
		defined $ce->{mail}->{smtpUsername}   ? (sasl_username => $ce->{mail}{smtpUsername})   : (),
		defined $ce->{mail}->{smtpPassword}   ? (sasl_password => $ce->{mail}{smtpPassword})   : (),
		defined $ce->{mail}->{smtpSSLOptions} ? (ssl_options   => $ce->{mail}{smtpSSLOptions}) : (),
		timeout => $ce->{mail}{smtpTimeout},
	});
}

sub generateURLs ($c, %params) {
	my $db       = $c->db;
	my $userName = $c->param('user');

	# generate context URLs
	my ($emailableURL, $returnURL);

	if ($userName) {
		my $routePath;
		my %args;
		if (defined $params{set_id} && $params{set_id} ne '') {
			if ($params{problem_id}) {
				$routePath = $c->url_for('problem_detail', setID => $params{set_id}, problemID => $params{problem_id});
				for my $name ('displayMode', 'showCorrectAnswers', 'showHints', 'showOldAnswers', 'showSolutions') {
					$args{$name} = [ $c->param($name) ] if defined $c->param($name) && $c->param($name) ne '';
				}
				$args{showProblemGrader} = 1;
			} else {
				$routePath = $c->url_for('problem_list', setID => $params{set_id});
			}
		} else {
			$routePath = $c->url_for('set_list');
		}
		$args{effectiveUser} = [ $c->param('effectiveUser') ] if defined $c->param('effectiveUser');
		$emailableURL        = $routePath->to_abs->query(map { $_ => $args{$_} } sort keys %args);
		$returnURL           = $c->systemLink($routePath);
	} else {
		$emailableURL = '(not available)';
		$returnURL    = '';
	}

	if ($params{url_type}) {
		if ($params{url_type} eq 'relative') {
			return $returnURL;
		} else {
			return $emailableURL;    # could include other types of URL here...
		}
	} else {
		return ($emailableURL, $returnURL);
	}
}

my $staticWWAssets;
my $staticPGAssets;
my $thirdPartyWWDependencies;
my $thirdPartyPGDependencies;

sub readJSON ($fileName) {
	return unless -r $fileName;

	open(my $fh, '<:encoding(UTF-8)', $fileName) or die "FATAL: Unable to open '$fileName'!";
	local $/;
	my $data = <$fh>;
	close $fh;

	return from_json($data);
}

sub getThirdPartyAssetURL ($file, $dependencies, $baseURL, $useCDN = 0) {
	for (keys %$dependencies) {
		if ($file =~ /^node_modules\/$_\/(.*)$/) {
			if ($useCDN) {
				return
					"https://cdn.jsdelivr.net/npm/$_\@"
					. substr($dependencies->{$_}, 1) . '/'
					. ($1 =~ s/(?:\.min)?\.(js|css)$/.min.$1/gr);
			} else {
				return "$baseURL/$file?version=$dependencies->{$_}";
			}
		}
	}
	return;
}

# Get the URL for static assets.
sub getAssetURL ($ce, $file, $isThemeFile = 0) {
	# Load the static files list generated by `npm ci` the first time this method is called.
	unless ($staticWWAssets) {
		my $staticAssetsList = "$ce->{webworkDirs}{htdocs}/static-assets.json";
		$staticWWAssets = readJSON($staticAssetsList);
		unless ($staticWWAssets) {
			warn "ERROR: '$staticAssetsList' not found or not readable!\n"
				. "You may need to run 'npm ci' from '$ce->{webworkDirs}{htdocs}'.";
			$staticWWAssets = {};
		}
	}

	unless ($staticPGAssets) {
		my $staticAssetsList = "$ce->{pg_dir}/htdocs/static-assets.json";
		$staticPGAssets = readJSON($staticAssetsList);
		unless ($staticPGAssets) {
			warn "ERROR: '$staticAssetsList' not found or not readable!\n"
				. "You may need to run 'npm ci' from '$ce->{pg_dir}/htdocs'.";
			$staticPGAssets = {};
		}
	}

	# Load the package.json files the first time this method is called.
	unless ($thirdPartyWWDependencies) {
		my $packageJSON = "$ce->{webworkDirs}{htdocs}/package.json";
		my $data        = readJSON($packageJSON);
		warn "ERROR: '$packageJSON' not found or not readable!\n" unless $data && defined $data->{dependencies};
		$thirdPartyWWDependencies = $data->{dependencies} // {};
	}

	unless ($thirdPartyPGDependencies) {
		my $packageJSON = "$ce->{pg_dir}/htdocs/package.json";
		my $data        = readJSON($packageJSON);
		warn "ERROR: '$packageJSON' not found or not readable!\n" unless $data && defined $data->{dependencies};
		$thirdPartyPGDependencies = $data->{dependencies} // {};
	}

	# Check to see if this is a third party asset file in node_modules (either in webwork2/htdocs or pg/htdocs).
	# If so, then either serve it from a CDN if requested, or serve it directly with the library version
	# appended as a URL parameter.
	if ($file =~ /^node_modules/) {
		my $wwFile = getThirdPartyAssetURL(
			$file, $thirdPartyWWDependencies,
			$ce->{webworkURLs}{htdocs},
			$ce->{options}{thirdPartyAssetsUseCDN}
		);
		return $wwFile if $wwFile;

		my $pgFile =
			getThirdPartyAssetURL($file, $thirdPartyPGDependencies, $ce->{pg_htdocs_url},
				$ce->{options}{thirdPartyAssetsUseCDN});
		return $pgFile if $pgFile;
	}

	# If a right-to-left language is enabled (Hebrew or Arabic) and this is a css file that is not a third party asset,
	# then determine the rtl variant file name.  This will be looked for first in the asset lists.
	my $rtlfile =
		($ce->{language} =~ /^(he|ar)/ && $file !~ /node_modules/ && $file =~ /\.css$/)
		? $file =~ s/\.css$/.rtl.css/r
		: undef;

	if ($isThemeFile) {
		# If the theme directory is the default location, then the file is in the static assets list.
		# Otherwise just use the given file name.
		if ($ce->{webworkDirs}{themes} =~ /^$ce->{webworkDirs}{htdocs}\/themes$/) {
			$rtlfile = "themes/$ce->{defaultTheme}/$rtlfile" if defined $rtlfile;
			$file    = "themes/$ce->{defaultTheme}/$file";
		} else {
			return "$ce->{webworkURLs}{themes}/$ce->{defaultTheme}/$file";
		}
	}

	# First check to see if this is a file in the webwork htdocs location with a rtl variant.
	return "$ce->{webworkURLs}{htdocs}/$staticWWAssets->{$rtlfile}"
		if defined $rtlfile && defined $staticWWAssets->{$rtlfile};

	# Next check to see if this is a file in the webwork htdocs location.
	return "$ce->{webworkURLs}{htdocs}/$staticWWAssets->{$file}" if defined $staticWWAssets->{$file};

	# Now check to see if this is a file in the pg htdocs location with a rtl variant.
	return "$ce->{pg_htdocs_url}/$staticPGAssets->{$rtlfile}"
		if defined $rtlfile && defined $staticPGAssets->{$rtlfile};

	# Next check to see if this is a file in the pg htdocs location.
	return "$ce->{pg_htdocs_url}/$staticPGAssets->{$file}" if defined $staticPGAssets->{$file};

	# If the file was not found in the lists, then assume it is in the webwork htdocs location, and use the given file
	# name.  If it is actually in the pg htdocs location, then the Mojolicious rewrite will send it there.
	return "$ce->{webworkURLs}{htdocs}/$file";
}

sub x (@args) { return @args }

1;

=head1 NAME

WeBWorK::Utils - General utility methods.

=head2 runtime_use

Usage: C<runtime_use($module, @import_list)>

This is like use, except it happens at runtime. The module name must be quoted,
and a comma after it if an import list is specified. Also, to specify an empty
import list (as opposed to no import list) use an empty array reference instead
of an empty array.

The following demonstrates equivalent usage of C<runtime_use> to that of C<use>.

    use Xyzzy;               =>    runtime_use 'Xyzzy';
    use Foo qw(pine elm);    =>    runtime_use 'Foo', qw(pine elm);
    use Foo::Bar ();         =>    runtime_use 'Foo::Bar', [];

=head2 trim_spaces

Usage: C<trim_spaces($string)>

Returns a string with whitespace trimmed from the start and end of C<$string>.

=head2 fix_newlines

Usage: C<fix_newlines($string)>

Converts carriage returns followed by new lines into just a new line. In other
words, converts non-unix like new lines into unix new lines.

=head2 encodeAnswers

Usage: C<encodeAnswers($hash, $order)>

Give a reference to a hash whose keys are answer names and values are student
answers in C<$hash>, and a reference to an array of answer names in the order
the answers appear in the problem in C<$order>, this returns a JSON encoded
array of answer name/student answer pairs where the pairs appear in the array in
the order provided by C<$order>.

=head2 decodeAnswers

Usage: C<decodeAnswers($serialized)>

Returns an array of answers decoded from the given C<$serialized> string.

This method attempts to detect if C<$serialized> is a JSON encoded array, or is
a L<Storable::nfreeze> encoded hash (the old method), and decodes using the
appropriate method.

=head2 encode_utf8_base64

Usage: C<encode_utf8_base64($in)>

UTF-8 encodes, and then base 64 endcodes the input and returns the result.

=head2 decode_utf8_base64

Usage: C<decode_utf8_base64($in)>

Base 64 decodes, and then UTF-8 decodes the input and returns the result.

=head2 nfreeze_base64

Usage: C<nfreeze_base64($in)>

This C<Storable::nfreeze> encodes and then base 64 encodes C<$in> and returns
the result.

=head2 thaw_base64

Usage: C<thaw_base64($in)>

This base 64 decodes and then C<Storable::thaw> decodes C<$in> and returns
result.

=head2 min

Usage: C<min(@items)>

Return the minimum element in C<@items>.

=head2 max

Usage: C<max(@items)>

Return the maximum element in C<@items>.

=head2 wwRound

Usage: C<wwRound($places, $float)>

Returns C<$float> rounded to C<$places> decimal places.

=head2 cryptPassword

Usage: C<cryptPassword($clearPassword)>

Returns the crypted form of C<$clearPassword> using a random 16 character
salt.

=head2 utf8Crypt

Usage: C<utf8Crypt($clearPassword, $hash)>

Attempts to call C<crypt> on C<$clearPassword>. If that fails, then C<crypt> is
called on the UTF-8 encoded version of C<$clearPassword>.

Note that C<$hash> can be a salt or a password hash generated by a previous call
of this method with a salt..

=head2 undefstr

Usage: C<undefstr($default, @values)>

Returns a copy of C<@values> whose undefined entries are replaced with
C<$default>.

=head2 sortByName

Usage: C<sortByName($field, @items)>

If C<$field> is a string naming a single field, then this returns the elements
in C<@items> sorted by that field.

If C<$field> is a reference to an array of strings each naming a field, then
this returns the entries of C<@items> sorted first by the first name field,
then by second, etc.

A natural sort algorithm is used for sorting, i.e., numeric parts are sorted
numerically, and alphabetic parts sorted lexicographically.

=head2 sortAchievements

Usage: C<sortAchievements(@achievements)>

Returns C<@achievements> sorted first by achievement id, then by number or
category (if the achievement does not have a number).

=head2 not_blank

Usage: C<not_blank($str)>

Returns true if C<$str> is defined and does not consist entirely of white space.

=head2 role_and_above

Usage: C<role_and_above($userRoles, $role)>

Given a reference to a hash C<$userRoles> whose keys are roles and values are
permission levels, returns a reference to an array of roles that are at or above
that of the permission level of the role specified in C<$role>.

=head2 fetchEmailRecipients

Usage: C<fetchEmailRecipients($c, $permissionType, $sender)>

Given a C<WeBWorK::ContentGenerator> object C<$c> and permission type
C<$permissionType>, this returns a list of feedback email recipients for the
course. If C<$sender> is provided, then this list is filtered by the section of
that sender.

=head2 processEmailMessage

Usage: C<processEmailMessage($text, $user_record, $STATUS, $merge_data, $for_preview)>

Process the email message in C<$text> and replace macros with values from the
C<$user_record>, the C<$STATUS>, and C<$merge_data>. If C<$for_prevew> is true
then the result is formatted to be display in HTML.

The replaceable macros and what they will be replaced with are

	$SID        => $user_record->student_id
	$FN         => $user_record->first_name
	$LN         => $user_record->last_name
	$SECTION    => $user_record->section
	$RECITATION => $user_record->recitation
	$EMAIL      => $user_record->email_address
	$LOGIN      => $user_record->user_id
    $STATUS     => $STATUS
    $COL[n]     => nth column of $merge_data
    $COL[-1]    => last column of $merge_data

=head2 createEmailSenderTransportSMTP

Usage: C<createEmailSenderTransportSMTP($ce)>

This returns an C<Email::Sender::Transport::SMTP> object for use in sending
emails. A valid C<WeBWorK::CourseEnvironment> object must be provided in C<$ce>.

=head2 generateURLs

Usage: C<generateURLs($c, %params)>

The parameter C<$c> must be a C<WeBWorK::Controller> object.

The following optional parameters may be passed:

=over

=item set_id

A problem set name.

=item problem_id

Problem id of a problem in the set.

=item url_type

This should a string with the value 'relative' or 'absolute' to return a single
URL, or undefined to return an array containing both URLs this subroutine could
be expanded to.

=back

=head2 getAssetURL

Usage: C<getAssetURL($ce, $file, $isThemeFile)>

Returns the URL for the asset specified in C<$file>.  If C<$isThemeFile> is
true, then the asset will be assumed to be located in a theme directory.  The
parameter C<$ce> must be a valid C<WeBWorK::CourseEnvironment> object.

=head2 x

Usage: C<x(@args)>

This is a dummy function used to mark constant strings for localization.  It
just returns C<@args>.

=cut
