#!/usr/bin/env perl
#
# ubc custom
#
# Update LTI created admin users in existing courses to the current password and MFA secret.

BEGIN {
	use Mojo::File qw(curfile);
	use Env        qw(WEBWORK_ROOT);

	$WEBWORK_ROOT = curfile->dirname->dirname;
}

use lib "$ENV{WEBWORK_ROOT}/lib";

use WeBWorK::CourseEnvironment;

use WeBWorK::DB;
use WeBWorK::Utils                   qw(cryptPassword);
use WeBWorK::Utils::CourseManagement qw(listCourses);
use MIME::Base32                     qw(decode_base32);

sub updateLtiAdminCourse {
	my ($upgrade_courseID) = @_;

	my $ce = WeBWorK::CourseEnvironment->new({
		webwork_dir => $ENV{WEBWORK_ROOT},
		courseName  => $upgrade_courseID,
	});
	my $db      = WeBWorK::DB->new($ce);
	my $user    = 'admin';
	my $newpass = $ENV{LTI_ADMIN_PASSWORD};
	my $newtotp = decode_base32($ENV{LTI_ADMIN_TOTP});

	my $passwordRecord = eval { $db->getPassword($user) };
	if ($passwordRecord) {
		my $cryptedPassword = cryptPassword($newpass);
		$passwordRecord->password($cryptedPassword);
		$passwordRecord->otp_secret($newtotp);
		eval { $db->putPassword($passwordRecord) };
		if ($@) {
			die "Errors $@ ";
		}
	} else {
		print "No admin user in course\n";
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
	print "Updating LTI admin user in $courseID\n";
	updateLtiAdminCourse($courseID);
}
