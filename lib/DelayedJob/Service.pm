package DelayedJob::Service;

##### Library Imports #####
use strict;
use warnings;
use WeBWorK::CourseEnvironment;
use WeBWorK::DB;
use WeBWorK::Debug;
use Data::Dumper;
use TheSchwartz;
use TheSchwartz::Job;
use Data::ObjectDriver::Driver::DBI;
use DelayedJob::GetClassMembership;
use DelayedJob::PushClassGrades;
use DelayedJob::PushUserGrades;
use DelayedJob::SendCaliperEvent;
use JSON;

#$WeBWorK::Debug::Enabled = 1;

# Jobs that work on a whole course. In a big course one of these can hold a worker for hours (a roster sync of a
# 6,000-student course ran for over 2.5 hours), while the per-user jobs take about a second each.
my @CLASS_JOBS = ('DelayedJob::GetClassMembership', 'DelayedJob::PushClassGrades');
my @USER_JOBS  = ('DelayedJob::PushUserGrades',     'DelayedJob::SendCaliperEvent');

# Constructor
sub new {
	my ($class, $ce) = @_;
	# Give the driver the DSN and credentials, not a connected handle. Data::ObjectDriver pings its handle before
	# every query and reconnects from the DSN when the ping fails. Built from a handle alone it has no DSN to
	# reconnect with, so after a database restart a worker logged "Disabling DB ... because unknown" every poll
	# and never ran another job until the pod was restarted. Data::ObjectDriver adds RaiseError, PrintError => 0
	# and AutoCommit itself.
	my $driver = Data::ObjectDriver::Driver::DBI->new(
		dsn             => $ce->{database_dsn},
		username        => $ce->{database_username},
		password        => $ce->{database_password},
		connect_options => { mariadb_auto_reconnect => 1 },
	);
	# Connect now: TheSchwartz->new reads the live handle to identify the database, and a database that is down
	# should still fail here, as before, rather than on the first job.
	$driver->rw_handle;
	my $prioritize = $ENV{DELAYED_JOB_PRIORITIZE} // 0;
	my $client     = TheSchwartz->new(
		databases => [ { driver => $driver } ],
		verbose   => sub {
			my $msg = shift;
			$msg =~ s/\s+$//;
			print STDERR scalar localtime() . ": $msg\n";
		},
		prioritize => $prioritize
	);
	$client->can_do($_) for (@CLASS_JOBS, @USER_JOBS);
	my $self = {
		ce             => $ce,
		client         => $client,
		driver         => $driver,
		max_class_jobs => _max_class_jobs(),
	};
	bless $self, $class;
	return $self;
}

# DELAYED_JOB_MAX_CLASS_JOBS: how many class jobs may run at once across all the workers on this database.
# Unset or 0 means no limit, which was the only behaviour before this setting existed.
sub _max_class_jobs {
	my $value = $ENV{DELAYED_JOB_MAX_CLASS_JOBS} // '';
	return 0          if $value eq '';
	return 0 + $value if $value =~ /^\d+$/;
	warn "DELAYED_JOB_MAX_CLASS_JOBS must be a whole number, not '$value'. Running without a limit on class jobs.\n";
	return 0;
}

sub work {
	my ($self) = @_;
	my $sleep = $ENV{DELAYED_JOB_SLEEP} // 10;
	$self->{client}->work($sleep);
}

sub work_until_done {
	my ($self) = @_;
	$self->{client}->work_until_done();
}

sub work_once {
	my ($self) = @_;
	my $client = $self->{client};
	return $client->work_once() unless $self->{max_class_jobs};

	# With a limit, a worker may start a class job only while it holds one of max_class_jobs database locks. That
	# way a few big courses can't occupy every worker while grade passback and Caliper events wait behind them.
	# The database drops a named lock when its connection closes, so a worker that dies gives its slot back.
	my $slot = $self->_take_class_job_slot;
	if ($slot) {
		my $didWork = eval { $client->work_once() };
		my $error   = $@;
		$self->_release_class_job_slot($slot);
		die $error if $error;
		return $didWork;
	}

	# Every slot is in use, so run only per-user jobs.
	my $job = $client->find_job_for_workers([@USER_JOBS]);
	return $job ? $client->work_once($job) : 0;
}

sub _take_class_job_slot {
	my ($self) = @_;
	# If the database is unreachable, take no slot; TheSchwartz finds and reports the outage itself.
	my $dbh = eval { $self->{driver}->rw_handle } or return;
	for my $slot (1 .. $self->{max_class_jobs}) {
		# Returns 1 if this connection now holds the lock, 0 if another connection does. Never waits.
		my ($got) = eval { $dbh->selectrow_array('SELECT GET_LOCK(?, 0)', undef, $self->_class_job_lock_name($slot)) };
		return $slot if $got;
	}
	return;
}

sub _release_class_job_slot {
	my ($self, $slot) = @_;
	# If the connection was replaced during a long job, the lock went with the old connection and this does nothing.
	eval { $self->{driver}->rw_handle->do('DO RELEASE_LOCK(?)', undef, $self->_class_job_lock_name($slot)) };
	return;
}

# Named locks are server-wide, so the name includes the database. MariaDB allows at most 64 characters.
sub _class_job_lock_name {
	my ($self, $slot) = @_;
	my $suffix = "class_job_slot_$slot";
	return substr($self->{ce}{database_name} // 'webwork', 0, 63 - length($suffix)) . ".$suffix";
}

sub pushUserGradesOnSubmit {
	my ($self, $user_id, $set_id) = @_;
	my $job = TheSchwartz::Job->new(
		funcname => 'DelayedJob::PushUserGrades',
		# try to vary the priority a bit, as too few variations makes the db
		# index on priority useless, which make sorting by priority very slow
		priority => 50 + int(rand(20)),
		arg      => {
			courseName => $self->{ce}->{courseName},
			user_id    => $user_id,
			set_id     => $set_id
		},
	);
	$self->{client}->insert($job);
}

sub pushClassGrades {
	my ($self) = @_;
	my $job = TheSchwartz::Job->new(
		funcname => 'DelayedJob::PushClassGrades',
		priority => 100 + int(rand(20)),
		arg      => {
			courseName => $self->{ce}->{courseName}
		},
	);
	$self->{client}->insert($job);
}

sub getClassMembership {
	my ($self) = @_;
	my $job = TheSchwartz::Job->new(
		funcname => 'DelayedJob::GetClassMembership',
		priority => 80 + int(rand(20)),
		arg      => {
			courseName => $self->{ce}->{courseName}
		},
	);
	$self->{client}->insert($job);
}

sub sendEvents {
	my ($self, $c, $json_array_of_events) = @_;
	my $args = {
		courseName           => $c->ce->{courseName},
		json_array_of_events => $json_array_of_events
	};
	$args = encode_json($args);
	my $job = TheSchwartz::Job->new(
		funcname => 'DelayedJob::SendCaliperEvent',
		priority => 0 + int(rand(20)),
		arg      => $args,
	);
	$self->{client}->insert($job);
}

1;
