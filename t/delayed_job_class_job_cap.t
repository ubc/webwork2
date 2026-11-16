#!/usr/bin/env perl

# DELAYED_JOB_MAX_CLASS_JOBS caps how many whole-class jobs (roster syncs and class grade pushes) run at once
# across all the workers on one database. In a big course one of those jobs can hold a worker for hours. With no
# cap, a few of them held every worker while per-student grade passback and Caliper events queued behind them.
#
# A worker takes a class job only while it holds one of the cap's database locks. MariaDB named locks are
# server-wide and are dropped when the connection closes, so a worker that dies gives its slot back. A worker
# without a lock takes only the per-user jobs.
#
# The real dependencies only exist in the built image, so this stands in for them.

use strict;
use warnings;

use Test::More;
use FindBin;

my %locks;    # lock name => session holding it, shared like the server's named locks
my @log;      # what the service asked of the database and of TheSchwartz, in order

BEGIN {
	# Loaded by DelayedJob::Service but not installed in the test container.
	for my $module (qw(WeBWorK::CourseEnvironment WeBWorK::DB WeBWorK::Debug TheSchwartz TheSchwartz::Job
		Data::ObjectDriver::Driver::DBI DelayedJob::GetClassMembership DelayedJob::PushClassGrades
		DelayedJob::PushUserGrades DelayedJob::SendCaliperEvent))
	{
		(my $file = "$module.pm") =~ s{::}{/}g;
		$INC{$file} = __FILE__;
	}
}

package FakeHandle {

	sub new {
		my ($class, $session) = @_;
		return bless { session => $session }, $class;
	}

	sub selectrow_array {
		my ($self, $sql, $attr, @bind) = @_;
		die "unexpected SQL: $sql\n" unless $sql =~ /^SELECT GET_LOCK\(\?, 0\)$/;
		my $name = $bind[0];
		die "lock name over 64 characters: $name\n" if length($name) > 64;
		push(@log, "get_lock $name");
		return 0 if defined $locks{$name} && $locks{$name} ne $self->{session};
		$locks{$name} = $self->{session};
		return 1;
	}

	sub do {
		my ($self, $sql, $attr, @bind) = @_;
		die "unexpected SQL: $sql\n" unless $sql =~ /^DO RELEASE_LOCK\(\?\)$/;
		push(@log, "release_lock $bind[0]");
		delete $locks{ $bind[0] } if ($locks{ $bind[0] } // '') eq $self->{session};
		return 1;
	}
}

package Data::ObjectDriver::Driver::DBI {
	my $sessions = 0;

	sub new {
		my ($class, %args) = @_;
		return bless { args => \%args, handle => FakeHandle->new('worker-' . ++$sessions) }, $class;
	}

	sub rw_handle {
		my ($self) = @_;
		die "Can't connect to the database\n" if $self->{down};
		return $self->{handle};
	}
}

package TheSchwartz {

	sub new {
		my ($class, %args) = @_;
		return bless { abilities => [] }, $class;
	}
	sub can_do { push(@{ $_[0]{abilities} }, $_[1]) }

	sub work_once {
		my ($self, $job) = @_;
		push(@log, 'work_once' . ($job ? " $job->{funcname}" : ''));
		die $self->{dies} if $self->{dies};
		return $job ? 1 : $self->{finds_job};
	}

	sub find_job_for_workers {
		my ($self, $classes) = @_;
		push(@log, 'find ' . join(',', @$classes));
		return $self->{user_job};
	}
}

package main;

use lib "$FindBin::Bin/../lib";
require DelayedJob::Service;

my $ce = {
	database_dsn      => 'DBI:MariaDB:database=webwork;host=db.example;port=3306',
	database_name     => 'webwork',
	database_username => 'webworkWrite',
	database_password => 'not-a-real-password',
};

sub service_with_cap {
	my ($cap) = @_;
	local $ENV{DELAYED_JOB_MAX_CLASS_JOBS} = $cap;
	delete $ENV{DELAYED_JOB_MAX_CLASS_JOBS} unless defined $cap;
	return DelayedJob::Service->new($ce);
}

sub reset_state { %locks = (); @log = (); }

my $user_job = { funcname => 'DelayedJob::PushUserGrades' };

subtest 'all four job classes are still registered' => sub {
	my $service = service_with_cap(undef);
	is_deeply(
		[ sort @{ $service->{client}{abilities} } ],
		[
			'DelayedJob::GetClassMembership', 'DelayedJob::PushClassGrades',
			'DelayedJob::PushUserGrades',     'DelayedJob::SendCaliperEvent'
		],
		'the worker can still run every job class'
	);
};

subtest 'without the setting a worker works exactly as before' => sub {
	reset_state();
	my $service = service_with_cap(undef);
	$service->{client}{finds_job} = 1;
	is($service->work_once, 1, 'work_once reports the job it ran');
	is_deeply(\@log, ['work_once'], 'no locks are taken and TheSchwartz picks the job as before');

	reset_state();
	$service = service_with_cap(0);
	$service->{client}{finds_job} = 1;
	$service->work_once;
	is_deeply(\@log, ['work_once'], 'a cap of 0 also means no cap');
};

subtest 'a free slot lets the worker take any job, and the slot is given back afterwards' => sub {
	reset_state();
	my $service = service_with_cap(2);
	$service->{client}{finds_job} = 1;
	is($service->work_once, 1, 'work_once reports the job it ran');
	is(scalar(@log),        3, 'three steps');
	like($log[0], qr/^get_lock \S*class_job_slot_1\b/, 'it takes the first slot');
	is($log[1], 'work_once', 'then lets TheSchwartz pick any job, class jobs included');
	like($log[2], qr/^release_lock \S*class_job_slot_1\b/, 'then gives the slot back');
	is_deeply(\%locks, {}, 'no lock is left behind');
};

subtest 'when another worker holds the first slot it takes the next one' => sub {
	reset_state();
	my $service = service_with_cap(2);
	my $first   = $service->_class_job_lock_name(1);
	$locks{$first} = 'other-worker';
	$service->{client}{finds_job} = 1;
	$service->work_once;
	like($log[1], qr/^get_lock \S*class_job_slot_2\b/, 'it takes the second slot');
	is($log[2], 'work_once', 'and works on any job');
	is_deeply(\%locks, { $first => 'other-worker' }, 'only the other worker\'s lock remains');
};

subtest 'with every slot taken the worker runs only per-user jobs' => sub {
	reset_state();
	my $service = service_with_cap(2);
	$locks{ $service->_class_job_lock_name($_) } = 'other-worker' for 1, 2;
	$service->{client}{user_job}                 = $user_job;
	is($service->work_once, 1, 'it still runs a job');
	is_deeply(
		[ grep { !/^get_lock/ } @log ],
		[ 'find DelayedJob::PushUserGrades,DelayedJob::SendCaliperEvent', 'work_once DelayedJob::PushUserGrades' ],
		'it looks only for grade passback and Caliper jobs, and runs the one it found'
	);

	reset_state();
	$locks{ $service->_class_job_lock_name($_) } = 'other-worker' for 1, 2;
	$service->{client}{user_job}                 = undef;
	is($service->work_once, 0, 'no per-user job waiting: it reports no work, so the worker sleeps');
	ok(!grep({/^work_once/} @log), 'and it does not fall back to a class job');
};

subtest 'the slot is given back even if the job dies' => sub {
	reset_state();
	my $service = service_with_cap(1);
	$service->{client}{dies} = "job blew up\n";
	eval { $service->work_once };
	is($@, "job blew up\n", 'the error still reaches the caller');
	is_deeply(\%locks, {}, 'the slot was released');
};

subtest 'if the lock query fails the worker sticks to per-user jobs' => sub {
	reset_state();
	my $service = service_with_cap(2);
	$service->{driver}{down}     = 1;
	$service->{client}{user_job} = $user_job;
	is($service->work_once, 1,                                                  'it does not die');
	is($log[0], 'find DelayedJob::PushUserGrades,DelayedJob::SendCaliperEvent', 'and looks only for per-user jobs');
};

subtest 'lock names' => sub {
	my $service = service_with_cap(3);
	my @names   = map { $service->_class_job_lock_name($_) } 1 .. 3;
	is(scalar(keys %{ { map { $_ => 1 } @names } }), 3, 'each slot has its own lock');
	like($names[0], qr/webwork/, 'the name includes the database name, since named locks are server-wide');

	local $ce->{database_name} = 'x' x 64;
	$service = service_with_cap(12);
	ok(length($service->_class_job_lock_name(12)) <= 64, 'it fits MariaDB\'s 64-character limit');
	isnt($service->_class_job_lock_name(1), $service->_class_job_lock_name(12), 'and stays unique per slot');
};

subtest 'a setting that is not a whole number is ignored with a warning' => sub {
	reset_state();
	my @warnings;
	local $SIG{__WARN__} = sub { push(@warnings, @_) };
	my $service = service_with_cap('two');
	like($warnings[0] // '', qr/DELAYED_JOB_MAX_CLASS_JOBS/, 'it warns about the bad value');
	$service->{client}{finds_job} = 1;
	$service->work_once;
	is_deeply(\@log, ['work_once'], 'and runs without a cap');
};

done_testing;
