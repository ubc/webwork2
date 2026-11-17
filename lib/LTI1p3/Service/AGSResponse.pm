package LTI1p3::Service::AGSResponse;

# Classifies the Canvas LTI Assignment and Grades Service (AGS) error responses
# that AssignmentAndGradeService handles specially.
#
# Match on the numeric status code, never on $res->status_line. The status line
# carries the reason phrase, and Canvas does not always send one: over HTTP/2
# there is no reason phrase at all, and the client reports "422 Unknown".
# Comparing status_line to '422 Unprocessable Entity' therefore silently missed
# every "This course has concluded" response (248 in the week to 2026-09-28 on
# UBC prod), so auto sync was never disabled for concluded courses and their
# whole-class grade push was re-queued and rejected every night.
#
# Deliberately dependency free (anything with ->code and ->content works, e.g.
# HTTP::Response) so it can be unit tested without a course environment.

use strict;
use warnings;

use Exporter 'import';
our @EXPORT_OK = qw(
	isConcludedCourse isCourseOutOfDates isMissingResourceLink
	isStudentViewUser isUnpublishedAssignment isExpiredAccessToken
	isPermanentScoreRejection
);

sub _is {
	my ($res, $code, @bodies) = @_;
	return 0 unless defined $res && ($res->code // 0) == $code;
	my $content = $res->content // '';
	return (grep { $content eq $_ } @bodies) ? 1 : 0;
}

# 422 once the course has concluded. Needs the
# ags_improved_course_concluded_response_codes Canvas feature flag.
sub isConcludedCourse {
	return _is(shift, 422,
		'{"errors":{"type":"unprocessable_entity","message":"This course has concluded. AGS requests will no longer be accepted for this course."}}'
	);
}

# 404 when the Canvas course is upcoming or concluded (outside its start and
# end dates), from a LineItem GET.
sub isCourseOutOfDates {
	return _is(shift, 404, '{"errors":[{"message":"The specified resource does not exist."}]}');
}

# 404 with an empty body is how a deleted Canvas assignment shows up.
sub isMissingResourceLink {
	return _is(shift, 404, '');
}

# 422 for the Canvas Student View user (Test Student).
sub isStudentViewUser {
	return _is(shift, 422,
		'{"errors":{"type":"unprocessable_entity","message":"User not found in course or is not a student"}}');
}

# 422 for a score pushed to an unpublished Canvas assignment, in the older body
# only. Canvas now sends a different body, which this does not match, so those
# responses are reported as errors (see isPermanentScoreRejection).
sub isUnpublishedAssignment {
	return _is(shift, 422,
		'{"errors":[{"field":"grade","message":"cannot be changed at this time: This assignment is still unpublished","error_code":null}]}'
	);
}

# A score POST the LMS rejected for a reason that only someone in the LMS can
# clear: publish the assignment, or enrol the student. Retrying cannot help, and
# for a whole-class push a retry re-runs hours of work only to be rejected again.
# The rejection is still an error (it belongs in the error table and the
# LMS-rejection metrics); this only says a retry is pointless.
#
# Matched on code plus message text, not the whole body: Canvas has sent the
# unpublished error in two JSON shapes, and on 2026-11-17 sent
# {"errors":{"type":"unprocessable_entity","message":"This assignment is still unpublished"}}.
sub isPermanentScoreRejection {
	my ($res) = @_;
	return 0 unless defined $res;
	my $code    = $res->code    // 0;
	my $content = $res->content // '';
	# Canvas: the assignment is unpublished.
	return 1 if $code == 422 && index($content, 'This assignment is still unpublished') >= 0;
	# Brightspace (D2L): the student is not enrolled in the org unit.
	return 1 if $code == 403 && index($content, 'User in requested score is not enrolled in the org unit') >= 0;
	return 0;
}

# 401 when a cached access token expired during a long sync.
sub isExpiredAccessToken {
	return _is(
		shift, 401,
		# Saw one instance of this error message
		'{"errors":{"type":"unauthorized","message":"Invalid access token field/s: the JWT has expired"}}',
		# More common error msg
		'{"errors":{"type":"unauthorized","message":"Access token expired"}}'
	);
}

1;
