#!/usr/bin/env perl

=head1 NAME

run_all_jobs - Script for all running delayed job workers

=head1 SYNOPSIS

run_all_jobs

=back

=cut

use strict;
use warnings;

BEGIN
{
    die "WEBWORK_ROOT not found in environment.\n" unless exists $ENV{WEBWORK_ROOT};
}

use lib "$ENV{WEBWORK_ROOT}/lib";
use WeBWorK::CourseEnvironment;
use Getopt::Long;
use Pod::Usage;
use WeBWorK::Debug;
use Data::Dumper;
use DelayedJob::Service;

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

my $delayed_job_service = DelayedJob::Service->new($ce);
$delayed_job_service->work();
