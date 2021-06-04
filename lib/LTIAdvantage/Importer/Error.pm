#!/usr/bin/env perl
use strict;
use warnings;

##### Module Creation #####
package LTIAdvantage::Importer::Error;
use Exporter;
our @ISA = ('Exporter');
our @EXPORT = ('error');

##### Library Imports #####
use WeBWorK::Debug;

##### Module Wide Variables #####
sub error
{
	my ($msg, $code) = @_;
	unless (defined $msg && defined $code)
	{
		my $error = "Missing parameters when calling error reporting function!";
		debug($error);
		die $error;
	}

	$msg = $msg . " EC: " . $code;
	debug($msg);
	return $msg;
}
