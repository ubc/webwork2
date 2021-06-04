package LTIAdvantage::EntrypointManager;

##### Library Imports #####
use strict;
use warnings;
use WeBWorK::CourseEnvironment;
use WeBWorK::DB;
use WeBWorK::Debug;
use WeBWorK::Utils qw(runtime_use);

use LTIAdvantage::Importer::Error;

# Constructor
sub new
{
	my ($class, $r) = @_;
	my $self = {
		r => $r,
		entrypoint => undef
	};
	bless $self, $class;
	return $self;
}

sub run
{
	my ($self) = @_;
	my $r = $self->{r};

	debug("Importer running.");

	my @entrypoints = (
		"LTIAdvantage::Entrypoint::Launch",
		"LTIAdvantage::Entrypoint::Login",
	);

	# find a compatible entrypoint
	my $entrypoint;
	foreach (@entrypoints)
	{
		debug("Testing entrypoint $_ for compatibility.");
		runtime_use($_);
		$entrypoint = $_->new($r);
		last if ($entrypoint->accept());
	}

	if ($entrypoint->accept())
	{
		debug("Compatible entrypoint found!");
		$self->{entrypoint} = $entrypoint;
		return $entrypoint->run();
	}
	# could've ended the loop without finding a compatible entrypoint
	return 0;
}

sub useAuthenModule
{
	my ($self) = @_;
	my $entrypoint = $self->{entrypoint};
	return $entrypoint ? $entrypoint->useAuthenModule() : "";
}

sub getAuthenModule
{
	my ($self) = @_;
	my $entrypoint = $self->{entrypoint};
	return $entrypoint ? $entrypoint->getAuthenModule() : "";
}

sub getErrorDisplayModule
{
	my ($self) = @_;
	my $entrypoint = $self->{entrypoint};
	return $entrypoint ? $entrypoint->getErrorDisplayModule() : "";
}

sub useRedirect
{
	my ($self) = @_;
	my $entrypoint = $self->{entrypoint};
	return $entrypoint ? $entrypoint->useRedirect() : "";
}

sub getRedirect
{
	my ($self) = @_;
	my $entrypoint = $self->{entrypoint};
	return $entrypoint ? $entrypoint->getRedirect() : "";
}

1;
