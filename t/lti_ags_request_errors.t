#!/usr/bin/env perl

# Every failure in a grade push other than a permanent score rejection must leave the
# push marked as worth retrying (AssignmentAndGradeService {error_is_retryable}).
# DelayedJob::PushClassGrades only asks TheSchwartz for a retry when that flag is set,
# so an error site that forgot it would turn, say, a Canvas outage during the nightly
# push into a failure that is never retried. This drives the real request code into
# each of those failures: line item create, line item GET, results GET and access token.
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
	sub new     { my ($class, $uri) = @_; return bless { uri => $uri }, $class }
	sub uri     { $_[0]{uri} }
	sub content {''}
}

# Every LMS request in this test fails with a 500.
package FakeResponse {
	sub new         { my ($class, $uri) = @_; return bless { uri => $uri }, $class }
	sub code        {500}
	sub content     {'<html>Internal Server Error</html>'}
	sub is_success  {0}
	sub status_line {'500 Internal Server Error'}
	sub request     { FakeRequest->new($_[0]{uri}) }
}

package LWP::UserAgent {
	sub new            { return bless {}, shift }
	sub default_header { }
	sub get            { my ($self, $uri) = @_; return FakeResponse->new("$uri") }
	sub post           { my ($self, $uri) = @_; return FakeResponse->new("$uri") }
}

package Mojo::URL {
	use overload '""' => sub { $_[0]{url} }, fallback => 1;
	sub new   { my ($class, $url) = @_; return bless { url => $url }, $class }
	sub query { }

	sub path {
		my ($self, $path) = @_;
		$self->{url} = "https://lms.example.invalid$path" if defined $path;
		return '/line_items/2';
	}
}

package LTI1p3::ExtraLog {
	sub new           { return bless {}, shift }
	sub logAGSRequest { }
}

# Hands out a token unless a test says the LMS refuses one.
our $token = 'a-token';

package LTI1p3::Service::AccessTokenRequest {
	sub new            { return bless {}, shift }
	sub getAccessToken {$main::token}
}

package FakeLink {
	sub new                   { my ($class, %args) = @_; return bless {%args}, $class }
	sub client_id             {'client-1'}
	sub context_id            {'context-1'}
	sub resource_link_id      {'link-1'}
	sub set_id                {'set-1'}
	sub scope_result_score    {1}
	sub scope_lineitem        { $_[0]{scope_lineitem} }
	sub scope_result_readonly { $_[0]{scope_result_readonly} }
	sub lineitem_url          { $_[0]{lineitem_url} }
	sub lineitems_url         {'https://lms.example.invalid/line_items'}
}

package main;

use lib "$FindBin::Bin/../lib";
require LTI1p3::Service::AssignmentAndGradeService;

# Push one resource link with no grades through the real request code.
sub push_link {
	my $service = LTI1p3::Service::AssignmentAndGradeService->new({ courseName => 'TEST_COURSE' }, undef);
	$service->_performAssignmentAndGradeRequests(
		[ { lti_resource_link => FakeLink->new(@_), grades_to_update => [] } ]);
	return $service;
}

my $service = push_link(lineitem_url => '', scope_lineitem => 1, scope_result_readonly => 0);
like($service->{error}, qr/LineItems POST\) request failed/, 'creating the line item fails');
ok($service->{error_is_retryable}, '... and the push is worth retrying');

$service = push_link(
	lineitem_url          => 'https://lms.example.invalid/line_items/2',
	scope_lineitem        => 1,
	scope_result_readonly => 0
);
like($service->{error}, qr/LineItem GET\) request failed/, 'reading the line item fails');
ok($service->{error_is_retryable}, '... and the push is worth retrying');

$service = push_link(
	lineitem_url          => 'https://lms.example.invalid/line_items/2',
	scope_lineitem        => 0,
	scope_result_readonly => 1
);
like($service->{error}, qr/LineItem Result GET\) request failed/, 'reading the existing results fails');
ok($service->{error_is_retryable}, '... and the push is worth retrying');

$token   = undef;
$service = push_link(
	lineitem_url          => 'https://lms.example.invalid/line_items/2',
	scope_lineitem        => 1,
	scope_result_readonly => 0
);
like($service->{error}, qr/unable to get an access token/, 'the LMS gives no access token');
ok($service->{error_is_retryable}, '... and the push is worth retrying');

done_testing();
