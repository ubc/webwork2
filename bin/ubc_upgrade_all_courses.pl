#!/usr/bin/env perl
#
# ubc custom
#
# Update tables for all courses.
# Use this if the upgrader in the admin course fails to load.

BEGIN {
	use Mojo::File qw(curfile);
	use Env        qw(WEBWORK_ROOT);

	$WEBWORK_ROOT = curfile->dirname->dirname;
}

use lib "$ENV{WEBWORK_ROOT}/lib";

use WeBWorK::CourseEnvironment;

use WeBWorK::DB;
use WeBWorK::Utils::CourseManagement qw(listCourses);
use WeBWorK::Utils::CourseDBIntegrityCheck;
use WeBWorK::Utils::CourseDirectoryIntegrityCheck qw(
	updateCourseDirectories
	updateCourseLinks
);

sub upgradeCourse {
	my ($upgrade_courseID) = @_;

	my $ce = WeBWorK::CourseEnvironment->new({
		webwork_dir => $ENV{WEBWORK_ROOT},
		courseName  => $upgrade_courseID,
	});
	#warn "do_upgrade_course: updating |$upgrade_courseID| from" , join("|",@upgrade_courseIDs);
	#############################################################################
	# Create integrity checker
	#############################################################################

	my @update_report;
	my $CIchecker = new WeBWorK::Utils::CourseDBIntegrityCheck($ce);

	#############################################################################
	# Add missing tables and missing fields to existing tables
	#############################################################################

	my ($tables_ok, $dbStatus) = $CIchecker->checkCourseTables($upgrade_courseID);
	my @schema_table_names = keys %$dbStatus;    # update tables missing from database;
	my @tables_to_create =
		grep { $dbStatus->{$_}->[0] == WeBWorK::Utils::CourseDBIntegrityCheck::ONLY_IN_A() } @schema_table_names;
	my @tables_to_alter =
		grep { $dbStatus->{$_}->[0] == WeBWorK::Utils::CourseDBIntegrityCheck::DIFFER_IN_A_AND_B() }
		@schema_table_names;
	push(@update_report, $CIchecker->updateCourseTables($upgrade_courseID, [@tables_to_create]));

	for my $table_name (@tables_to_alter) {
		push(@update_report, $CIchecker->updateTableFields($upgrade_courseID, $table_name));
	}

	# update course directories
	push(@update_report, @{ updateCourseDirectories($ce) });
	# update course symlinks to libraries
	push(@update_report, @{ updateCourseLinks($ce) });

	if (@update_report) {
		for (@update_report) {
			if ($_->[1]) {
				print "$_->[0]\n";
			} else {
				print STDERR "$_->[0]\n";
			}
		}
	} else {
		print "$upgrade_courseID Course Up to Date\n";
	}
}

my $adminCe = WeBWorK::CourseEnvironment->new({
	webwork_dir => $ENV{WEBWORK_ROOT},
	courseName  => 'admin',
});
my @courseIDs = listCourses($adminCe);
use Data::Dumper;

for my $courseID (@courseIDs) {
	print "-----------------------------------------\n";
	print "Upgrading $courseID\n";
	upgradeCourse($courseID);
	print "=========================================\n";
}
