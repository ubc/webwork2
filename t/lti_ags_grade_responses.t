#!/usr/bin/env perl

# A whole-class grade push (DelayedJob::PushClassGrades) of a big course takes hours.
# Before 2026-11-17 one score the LMS would never accept, such as a score for an
# unpublished Canvas assignment, failed the whole job, and TheSchwartz re-ran the
# entire push, which met the same rejection and failed again. UBC's largest course
# lost 3 hours of a class-job slot to that every day.
#
# _handleGradeResponses still reports such a rejection in {error}, so it reaches the
# error table and the LMS-rejection metrics, but it no longer marks the push as worth
# retrying. Any other failed score does.
#
# The real dependencies only exist in the built image, so this stands in for them.

use strict;
use warnings;

use Test::More;
use FindBin;

BEGIN {
	# Loaded by LTI1p3::Service::AssignmentAndGradeService but not installed in the test container.
	for my $module (qw(WeBWorK::Debug Net::OAuth HTTP::Request LWP::UserAgent WeBWorK::Utils::DateTime
		HTTP::Request::Common HTTP::Async LTI1p3::Service::AccessTokenRequest LTI1p3::ExtraLog Mojo::URL))
	{
		(my $file = "$module.pm") =~ s{::}{/}g;
		$INC{$file} = __FILE__;
	}
}

package WeBWorK::Debug {

	sub import {
		no strict 'refs';
		*{ caller() . '::debug' } = sub { }
	}
}

package FakeRequest {
	sub new     { return bless {}, shift }
	sub uri     {'https://lms.example.invalid/api/lti/courses/1/line_items/2/scores'}
	sub content {'{"scoreGiven":0.5,"userId":"lti-user-1"}'}
}

package FakeResponse {
	sub new         { my ($class, %args) = @_; return bless {%args}, $class }
	sub code        { $_[0]{code} }
	sub content     { $_[0]{content} }
	sub is_success  { $_[0]{code} >= 200 && $_[0]{code} < 300 }
	sub status_line {"$_[0]{code} Unknown"}
	sub request     { FakeRequest->new }
}

package FakeAsync {
	sub new                    { my ($class, @responses) = @_; return bless [@responses], $class }
	sub wait_for_next_response { return shift @{ $_[0] } }
}

package FakeExtraLog {
	sub new           { return bless {}, shift }
	sub logAGSRequest { }
}

package main;

use lib "$FindBin::Bin/../lib";
require LTI1p3::Service::AssignmentAndGradeService;

sub res { my ($code, $content) = @_; return FakeResponse->new(code => $code, content => $content) }

# Run one batch of score POST responses through the handler.
sub handle {
	my $service = LTI1p3::Service::AssignmentAndGradeService->new({}, undef);
	$service->_handleGradeResponses(FakeAsync->new(@_), FakeExtraLog->new);
	return $service;
}

my $ok = res(200, '{}');
my $unpublished =
	res(422, '{"errors":{"type":"unprocessable_entity","message":"This assignment is still unpublished"}}');
my $not_enrolled = res(403, 'User in requested score is not enrolled in the org unit');
my $bad_gateway  = res(502, '<html>Bad Gateway</html>');

my $service = handle($ok, $ok);
ok(!$service->{error},              'all scores accepted: no error');
ok(!$service->{error_is_retryable}, 'all scores accepted: nothing to retry');

$service = handle($ok, $unpublished, $ok);
like($service->{error}, qr/still unpublished/, 'an unpublished assignment is still reported as an error');
ok(!$service->{error_is_retryable}, '... but not as one a retry could fix');

$service = handle($not_enrolled);
like($service->{error}, qr/not enrolled/, 'a student missing from the Brightspace org unit is still reported');
ok(!$service->{error_is_retryable}, '... but not as one a retry could fix');

$service = handle($bad_gateway);
like($service->{error}, qr/Status: 502/, 'an LMS server error is reported');
ok($service->{error_is_retryable}, '... and makes the push worth retrying');

$service = handle($bad_gateway, $unpublished);
like($service->{error}, qr/still unpublished/, 'only the last error message is kept');
ok($service->{error_is_retryable}, 'an earlier retryable error still makes the push worth retrying');

done_testing();
