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
		"WebworkBridge::Bridges::LTILaunchBridge",
		"WebworkBridge::Bridges::LTILoginBridge",
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
	# could've ended the loop without finding a compatible bridge
	return 0;
}

sub useAuthenModule
{
	my ($self) = @_;
	my $bridge = $self->{bridge};
	return $bridge ? $bridge->useAuthenModule() : "";
}

sub getAuthenModule
{
	my ($self) = @_;
	my $bridge = $self->{bridge};
	return $bridge ? $bridge->getAuthenModule() : "";
}

sub getErrorDisplayModule
{
	my ($self) = @_;
	my $bridge = $self->{bridge};
	return $bridge ? $bridge->getErrorDisplayModule() : "";
}

sub useRedirect
{
	my ($self) = @_;
	my $bridge = $self->{bridge};
	return $bridge ? $bridge->useRedirect() : "";
}

sub getRedirect
{
	my ($self) = @_;
	my $bridge = $self->{bridge};
	return $bridge ? $bridge->getRedirect() : "";
}

1;
