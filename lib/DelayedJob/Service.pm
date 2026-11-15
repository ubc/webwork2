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
	$client->can_do('DelayedJob::GetClassMembership');
	$client->can_do('DelayedJob::PushClassGrades');
	$client->can_do('DelayedJob::PushUserGrades');
	$client->can_do('DelayedJob::SendCaliperEvent');
	my $self = {
		ce     => $ce,
		client => $client
	};
	bless $self, $class;
	return $self;
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
	return $self->{client}->work_once();
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
