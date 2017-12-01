package WebworkBridge::BridgeManager;

##### Library Imports #####
use strict;
use warnings;
use WeBWorK::CourseEnvironment;
use WeBWorK::DB;
use WeBWorK::Debug;
use WeBWorK::Utils qw(runtime_use);

use WebworkBridge::Importer::Error;

# Constructor
sub new 
{
	my ($class, $r) = @_;
	my $self = {
		r => $r,
		bridge => undef
	};
	bless $self, $class;
	return $self;
}

sub run
{
	my ($self) = @_;
	my $r = $self->{r};

	debug("Importer running.");

	my @bridges = (
		"WebworkBridge::Bridges::LTIBridge",
	);

	# find a compatible bridge
	my $bridge;
	foreach (@bridges)
	{
		debug("Testing bridge $_ for compatibility.");
		runtime_use($_);
		$bridge = $_->new($r);
		last if ($bridge->accept());
	}

	if ($bridge->accept())
	{ 
		debug("Compatible bridge found!");
		$self->{bridge} = $bridge;
		return $bridge->run();
	}
	else
	{ # could've ended the loop without finding a compatible bridge
		debug("No compatible bridge found...");
		return error("Failed to find a compatible bridge.", "#e002");
	}
}

sub useAuthenModule
{
	my ($self) = @_;
	my $bridge = $self->{bridge};
	return $bridge ? $bridge->useAuthenModule() : "";
}

sub useDisplayModule
{
	my ($self) = @_;
	my $bridge = $self->{bridge};
	return $bridge ? $bridge->useDisplayModule() : "";
}

sub getAuthenModule
{
	my ($self) = @_;
	my $bridge = $self->{bridge};
	return $bridge ? $bridge->getAuthenModule() : "";
}

sub getDisplayModule
{
	my ($self) = @_;
	my $bridge = $self->{bridge};
	return $bridge ? $bridge->getDisplayModule() : "";
}

1;
