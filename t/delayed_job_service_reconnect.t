#!/usr/bin/env perl

# DelayedJob::Service has to give TheSchwartz a Data::ObjectDriver driver that knows
# its DSN. Data::ObjectDriver pings the handle before every query and reconnects from
# the DSN when the ping fails. A driver built from a bare handle has nothing to
# reconnect with, so after a database restart the LTI workers logged
# "Disabling DB ... because unknown" on every poll and stopped running jobs until
# the pods were restarted.
#
# The real dependencies only exist in the built image, so this stands in for them
# and checks what Service->new hands to the driver and to TheSchwartz.

use strict;
use warnings;

use Test::More;
use FindBin;

my (@driver_args, @schwartz_args, @calls);

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

package Data::ObjectDriver::Driver::DBI {

	sub new {
		my ($class, %args) = @_;
		push(@driver_args, \%args);
		push(@calls,       'driver');
		return bless {%args}, $class;
	}
	sub rw_handle { push(@calls, 'connect'); return 'handle' }
}

package TheSchwartz {

	sub new {
		my ($class, %args) = @_;
		push(@schwartz_args, \%args);
		push(@calls,         'TheSchwartz');
		return bless {}, $class;
	}
	sub can_do { }
}

package main;

use lib "$FindBin::Bin/../lib";
require DelayedJob::Service;

my $ce = {
	database_dsn      => 'DBI:MariaDB:database=webwork;host=db.example;port=3306',
	database_username => 'webworkWrite',
	database_password => 'not-a-real-password',
};
my $service = DelayedJob::Service->new($ce);

is(scalar(@driver_args), 1, 'one driver is built');
my %args = %{ $driver_args[0] };
is($args{dsn},      $ce->{database_dsn},      'the driver gets the DSN, so it can reconnect');
is($args{username}, $ce->{database_username}, 'the driver gets the username');
is($args{password}, $ce->{database_password}, 'the driver gets the password');
ok(!exists $args{dbh},     'the driver is not built from a bare handle');
ok(!exists $args{get_dbh}, 'the driver does not depend on a handle getter');
is($args{connect_options}{mariadb_auto_reconnect}, 1, 'MariaDB auto reconnect is still requested');

is_deeply(
	\@calls,
	[ 'driver', 'connect', 'TheSchwartz' ],
	'it connects before TheSchwartz reads the handle to identify the database'
);
isa_ok($schwartz_args[0]{databases}[0]{driver}, 'Data::ObjectDriver::Driver::DBI', 'the TheSchwartz database driver');
is($schwartz_args[0]{databases}[0]{driver}{dsn}, $ce->{database_dsn}, 'TheSchwartz uses the DSN-based driver');

done_testing;
