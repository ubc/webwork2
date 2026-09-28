#!/usr/bin/env perl

# LTI1p3::Service::AGSResponse classifies Canvas AGS error responses by status
# CODE and body. Before 2026-09-28 AssignmentAndGradeService compared
# $res->status_line to strings like '422 Unprocessable Entity', but Canvas sends
# the "course has concluded" 422 without a reason phrase and the client reports
# '422 Unknown', so concluded courses never had auto sync disabled.

use strict;
use warnings;

use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";

use LTI1p3::Service::AGSResponse qw(
	isConcludedCourse isCourseOutOfDates isMissingResourceLink
	isStudentViewUser isUnpublishedAssignment isExpiredAccessToken
);

# Minimal stand-in for HTTP::Response: the classifier only needs code/content,
# and status_line is here to show it is NOT consulted.
{

	package FakeResponse;
	sub new         { my ($c, %a) = @_; return bless {%a}, $c }
	sub code        { $_[0]{code} }
	sub content     { $_[0]{content} }
	sub status_line {"$_[0]{code} $_[0]{message}"}
}

sub res {
	my ($code, $message, $content) = @_;
	FakeResponse->new(code => $code, message => $message, content => $content);
}

my $concluded =
	'{"errors":{"type":"unprocessable_entity","message":"This course has concluded. AGS requests will no longer be accepted for this course."}}';

# The regression: exactly what UBC prod receives from Canvas.
my $prod_concluded = res(422, 'Unknown', $concluded);
is($prod_concluded->status_line, '422 Unknown', 'prod response has no reason phrase');
ok($prod_concluded->status_line ne '422 Unprocessable Entity', 'so the old status_line comparison could never match');
ok(isConcludedCourse($prod_concluded),                         'concluded course detected with "422 Unknown"');
ok(isConcludedCourse(res(422, 'Unprocessable Entity', $concluded)),        'and with the full reason phrase');
ok(!isConcludedCourse(res(422, 'Unknown', '{"errors":"something else"}')), 'other 422 bodies are not "concluded"');
ok(!isConcludedCourse(res(404, 'Not Found', $concluded)), 'the body alone is not enough: code must be 422');

ok(isCourseOutOfDates(res(404, '', '{"errors":[{"message":"The specified resource does not exist."}]}')),
	'course out of dates (404) without reason phrase');
ok(!isCourseOutOfDates(res(404, 'Not Found', '')), 'empty 404 is not out-of-dates');

ok(isMissingResourceLink(res(404,  '',          '')),    'deleted assignment: empty 404 without reason phrase');
ok(isMissingResourceLink(res(404,  'Not Found', undef)), 'undefined body counts as empty');
ok(!isMissingResourceLink(res(404, 'Not Found', '{"errors":[]}')), 'non-empty 404 is not a missing link');

ok(
	isStudentViewUser(res(
		422, 'Unknown',
		'{"errors":{"type":"unprocessable_entity","message":"User not found in course or is not a student"}}'
	)),
	'Canvas Student View user'
);

ok(
	isUnpublishedAssignment(res(
		422,
		'Unprocessable Entity',
		'{"errors":[{"field":"grade","message":"cannot be changed at this time: This assignment is still unpublished","error_code":null}]}'
	)),
	'unpublished assignment (as seen on prod, with reason phrase)'
);

ok(
	isExpiredAccessToken(res(
		401, 'Unknown', '{"errors":{"type":"unauthorized","message":"Access token expired"}}')),
	'expired token, common message, no reason phrase'
);
ok(
	isExpiredAccessToken(res(
		401, 'Unauthorized',
		'{"errors":{"type":"unauthorized","message":"Invalid access token field/s: the JWT has expired"}}'
	)),
	'expired token, JWT message'
);
ok(!isExpiredAccessToken(res(401, 'Unauthorized', '{"errors":{"type":"unauthorized","message":"Invalid key"}}')),
	'other 401s are not treated as an expired token');

ok(!isConcludedCourse(undef), 'undef response is handled');

done_testing();
