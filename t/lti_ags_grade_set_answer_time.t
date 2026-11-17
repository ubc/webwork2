#!/usr/bin/env perl

# AssignmentAndGradeService::grade_set works out, for one student and one set, the
# score and the time of the latest answer (sent to the LMS as submittedAt). For the
# time it used to make two queries per problem: latestProblemPastAnswer, then
# getPastAnswer. A class grade push grades every set of every student, so in UBC's
# largest course those round trips were most of a push that took over 3 hours
# (2026-11-17). It now reads the set's past answers in one query.
#
# The answer time must not change: for each problem, the answer with the highest
# answer_id (what latestProblemPastAnswer returns), then the newest of those times.
# FakeDB serves both the per-problem methods and the table query from the same rows,
# so these tests describe the result either way, and count the queries.
#
# The real dependencies only exist in the built image, so this stands in for them.

use strict;
use warnings;

use Test::More;
use FindBin;

BEGIN {
	# Loaded by LTI1p3::Service::AssignmentAndGradeService but not installed in the test container.
	for my $module (qw(WeBWorK::Debug Net::OAuth HTTP::Request LWP::UserAgent WeBWorK::Utils::DateTime
		HTTP::Request::Common HTTP::Async LTI1p3::Service::AccessTokenRequest LTI1p3::ExtraLog Mojo::URL))
	{
		(my $file = "$module.pm") =~ s{::}{/}g;
		$INC{$file} = __FILE__;
	}
}

package WeBWorK::Debug {

	sub import {
		no strict 'refs';
		*{ caller() . '::debug' } = sub { }
	}
}

package FakeRecord {
	sub new { my ($class, %fields) = @_; return bless {%fields}, $class }
	our $AUTOLOAD;

	sub AUTOLOAD {
		my $self = shift;
		(my $name = $AUTOLOAD) =~ s/.*:://;
		return if $name eq 'DESTROY';
		return $self->{$name};
	}
}

# The past_answer table: get_fields_where as WeBWorK::DB::Schema::NewSQL::Std answers it.
package FakePastAnswerTable {
	sub new { my ($class, $db) = @_; return bless { db => $db }, $class }

	sub get_fields_where {
		my ($self, $fields, $where, $order) = @_;
		my $db = $self->{db};
		$db->{queries}++;
		my ($clause, $user_id, $set_id) = @$where;
		die "unexpected where clause $clause" unless $clause eq 'user_id_eq_set_id_eq';
		my @rows = grep { $_->{user_id} eq $user_id && $_->{set_id} eq $set_id } @{ $db->{answers} };
		@rows = sort { $a->{answer_id} <=> $b->{answer_id} } @rows if $order;
		return map {
			my $row = $_;
			[ map { $row->{$_} } @$fields ]
		} @rows;
	}
}

package FakeDB {

	sub new {
		my ($class, %args) = @_;
		my $self = bless { problems => $args{problems}, answers => $args{answers}, queries => 0 }, $class;
		$self->{past_answer} = FakePastAnswerTable->new($self);
		return $self;
	}

	sub getAllMergedUserProblems {
		my ($self, $user_id, $set_id) = @_;
		return @{ $self->{problems} };
	}

	sub getAllMergedProblemVersions {
		my ($self, $user_id, $set_id, $version_id) = @_;
		return @{ $self->{problems} };
	}

	# The per-problem lookups the old code made: highest answer_id, then that row.
	sub latestProblemPastAnswer {
		my ($self, $user_id, $set_id, $problem_id) = @_;
		$self->{queries}++;
		my @ids = sort { $a <=> $b } map { $_->{answer_id} }
			grep { $_->{user_id} eq $user_id && $_->{set_id} eq $set_id && $_->{problem_id} == $problem_id }
			@{ $self->{answers} };
		return $ids[-1];
	}

	sub getPastAnswer {
		my ($self, $answer_id) = @_;
		$self->{queries}++;
		my ($row) = grep { $_->{answer_id} == $answer_id } @{ $self->{answers} };
		return FakeRecord->new(%$row);
	}
}

package main;

use lib "$FindBin::Bin/../lib";
require LTI1p3::Service::AssignmentAndGradeService;

my $student = 'student-1';

sub problem {
	my ($problem_id, $status, $value) = @_;
	return FakeRecord->new(user_id => $student, problem_id => $problem_id, status => $status, value => $value);
}

sub answer {
	my ($answer_id, $problem_id, $timestamp, %other) = @_;
	return {
		answer_id  => $answer_id,
		user_id    => $other{user_id} // $student,
		set_id     => $other{set_id}  // 'set-1',
		problem_id => $problem_id,
		timestamp  => $timestamp
	};
}

# Grade one set and return (timestamp, status, total_right, total) and the query count.
sub grade {
	my (%args)  = @_;
	my $db      = FakeDB->new(problems => $args{problems}, answers => $args{answers});
	my $service = LTI1p3::Service::AssignmentAndGradeService->new({}, $db);
	my $set     = FakeRecord->new(set_id => 'set-1', version_id => $args{version_id});
	my @result  = $service->grade_set($set, $student, $args{version_id} ? 1 : 0);
	return (\@result, $db->{queries});
}

my @five_problems = map { problem($_, 1, 1) } 1 .. 5;

my ($result, $queries) = grade(
	problems => \@five_problems,
	answers  => [ answer(1, 1, 1000), answer(2, 2, 2000), answer(3, 3, 1500) ]
);
is($result->[0], 2000, 'the answer time is the newest of the problems\' latest answers');
cmp_ok($queries, '<=', 1, 'one query for the whole set, not two per problem') or diag("$queries queries");

($result) = grade(
	problems => [ problem(1, 1, 1),    problem(2, 1, 1) ],
	answers  => [ answer(10, 1, 5000), answer(11, 1, 4000), answer(12, 2, 4500) ]
);
is($result->[0], 4500,
	'a problem counts with its latest answer (highest answer_id), even when an earlier answer has a later time');

($result) = grade(
	problems => [ problem(1, 1, 1) ],
	answers  => [ answer(1, 1, 1000), answer(2, 7, 9000), answer(3, 1, 9500, set_id => 'set-2') ]
);
is($result->[0], 1000, 'answers to problems no longer in the set, and to other sets, are ignored');

($result) = grade(
	problems => [ problem(1, 1, 1),   problem(2, 1, 1) ],
	answers  => [ answer(1, 1, 1000), answer(2, 2, undef) ]
);
is($result->[0], 1000, 'a latest answer with no recorded time is skipped');

($result) = grade(
	problems   => [ problem(1, 1, 1), problem(2, 1, 1) ],
	version_id => 2,
	answers    => [
		answer(1, 1, 1000, set_id => 'set-1,v2'),
		answer(2, 2, 3000, set_id => 'set-1,v1'),
		answer(3, 2, 4000, set_id => 'set-1')
	]
);
is($result->[0], 1000, 'a test version uses only that version\'s answers ("set-1,v2")');

my $before = time;
($result) = grade(problems => \@five_problems, answers => []);
cmp_ok($result->[0], '>=', $before, 'with no answers at all the time defaults to now');

($result) = grade(
	problems => [ problem(1, 1, 2), problem(2, 0.5, 4), problem(3, 1.5, 1), problem(4, undef, undef) ],
	answers  => [ answer(1, 1, 1000) ]
);
is_deeply(
	[ @$result[ 1 .. 3 ] ],
	[ 0, 4, 8 ],
	'score unchanged: status x value, out-of-range status scores 0, missing value counts as 1'
);

done_testing();
