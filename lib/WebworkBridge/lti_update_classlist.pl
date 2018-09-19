#!/usr/bin/env perl

=head1 NAME

lti_update_classlist - Will try to update all courses with automatic_updates enabled

=head1 SYNOPSIS

lti_update_classlist

=back

=cut

use strict;
use warnings;

BEGIN
{
	die "WEBWORK_ROOT not found in environment.\n"
		unless exists $ENV{WEBWORK_ROOT};
}

use lib "$ENV{WEBWORK_ROOT}/lib";
use WeBWorK::CourseEnvironment;
use Getopt::Long;
use Pod::Usage;
use WeBWorK::Debug;
use Data::Dumper;
use WeBWorK::DB;
use WeBWorK::Authen::LTIAdvantage::NamesAndRoleService;
use WebworkBridge::Importer::CourseUpdater;

my $man = 0;
my $help = 0;

GetOptions (
	'help|?' => \$help,
	man => \$man
);

pod2usage(1) if $help;

# bring up a minimal course environment
my $ce = WeBWorK::CourseEnvironment->new({
	webwork_dir => $ENV{WEBWORK_ROOT},
});
my $db = new WeBWorK::DB($ce->{dbLayout});

# LTI Update

my @lti_contexts = $db->getAllLTIContextsByAutomaticUpdates(1);

# get unique list of course ids from lti_contexts
my $course_hash = {};
foreach my $lti_context (@lti_contexts) {
	my $course_id = $lti_context->course_id();

	unless(exists $course_hash->{$course_id}) {
		$course_hash->{$course_id} = 1;
	}
}
my @course_ids = keys %{$course_hash};

foreach my $course_id (@course_ids) {
	my $tmp_ce = WeBWorK::CourseEnvironment->new({
		webwork_dir => $ENV{WEBWORK_ROOT},
		courseName => $course_id
	});
	my $tmp_db = new WeBWorK::DB($tmp_ce->{dbLayout});

	eval {
		my $names_and_roles_service = WeBWorK::Authen::LTIAdvantage::NamesAndRoleService->new($tmp_ce, $tmp_db);
		my $membership = $names_and_roles_service->getAllNamesAndRole();
		unless ($membership) {
			return "There was an issue fetching the class roster. ".$names_and_roles_service->{error};
		}
		my $updater = WebworkBridge::Importer::CourseUpdater->new($tmp_ce, $tmp_db, $membership);
		my $ret = $updater->updateCourse();
		if ($ret) {
			die "Update Class Roster failed: $ret";
		}
	};
	if ($@) {
		print "Automatic LTI Classlist update for $course_id Failed.\n$@\n";
	} else {
		print "Automatic LTI Classlist update for $course_id Successful.\n";
	}
}
