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
use DBI;
use DelayedJob::GetClassMembership;
use DelayedJob::PushClassGrades;
use DelayedJob::PushUserGrades;
use DelayedJob::SendCaliperEvent;

#$WeBWorK::Debug::Enabled = 1;

# Constructor
sub new
{
	my ($class, $ce) = @_;
	my $dbh = DBI->connect(
        $ce->{database_dsn},
        $ce->{database_username},
        $ce->{database_password},
        {
            RaiseError => 1,
            PrintError => 0,
            AutoCommit => 1,
            mariadb_auto_reconnect => 1,
        },
	);
	my $driver = Data::ObjectDriver::Driver::DBI->new(dbh => $dbh);
	my $client = TheSchwartz->new(
		databases => [{ driver => $driver }],
		verbose => 1,
		prioritize => 1
	);
	$client->can_do('DelayedJob::GetClassMembership');
	$client->can_do('DelayedJob::PushClassGrades');
	$client->can_do('DelayedJob::PushUserGrades');
	$client->can_do('DelayedJob::SendCaliperEvent');
	my $self = {
		ce => $ce,
		client => $client
	};
	bless $self, $class;
	return $self;
}

sub work {
	my ($self) = @_;
	$self->{client}->work(15);
}

sub work_until_done {
	my ($self) = @_;
	$self->{client}->work_until_done();
}

sub pushUserGradesOnSubmit {
	my ($self, $user_id, $set_id) = @_;
	my $job = TheSchwartz::Job->new(
		funcname => 'DelayedJob::PushUserGrades',
		priority => 100,
		arg => {
			courseName => $self->{ce}->{courseName},
			user_id => $user_id,
			set_id => $set_id
		},
	);
	$self->{client}->insert($job);
}

sub pushClassGrades {
	my ($self) = @_;
	my $job = TheSchwartz::Job->new(
		funcname => 'DelayedJob::PushClassGrades',
		priority => 100,
		arg => {
			courseName => $self->{ce}->{courseName}
		},
	);
	$self->{client}->insert($job);
}

sub getClassMembership {
	my ($self) = @_;
	my $job = TheSchwartz::Job->new(
		funcname => 'DelayedJob::GetClassMembership',
		priority => 50,
		arg => {
			courseName => $self->{ce}->{courseName}
		},
	);
	$self->{client}->insert($job);
}

sub sendEvents {
	my ($self, $json_array_of_events) = @_;
	my $job = TheSchwartz::Job->new(
		funcname => 'DelayedJob::SendCaliperEvent',
		priority => 0,
		arg => {
			courseName => $self->{ce}->{courseName},
			json_array_of_events => $json_array_of_events
		},
	);
	debug("Delayed Job sendEvents");
	debug(Dumper($job));
	$self->{client}->insert($job);
}

1;
