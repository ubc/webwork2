package LTI1p3::EntrypointManager;

##### Library Imports #####
use strict;
use warnings;
use WeBWorK::CourseEnvironment;
use WeBWorK::DB;
use WeBWorK::Debug;
use WeBWorK::Utils qw(runtime_use);

use LTI1p3::Importer::Error;

# Constructor
sub new {
	my ($class, $c) = @_;
	my $self = {
		c          => $c,
		entrypoint => undef
	};
	bless $self, $class;
	return $self;
}

sub run {
	my ($self) = @_;
	my $c = $self->{c};

	debug("Importer running.");

	my @entrypoints = ("LTI1p3::Entrypoint::Launch", "LTI1p3::Entrypoint::Login",);

	# find a compatible entrypoint
	my $entrypoint;
	foreach (@entrypoints) {
		debug("Testing entrypoint $_ for compatibility.");
		runtime_use($_);
		$entrypoint = $_->new($c);
		last if ($entrypoint->accept());
	}

	if ($entrypoint->accept()) {
		debug("Compatible entrypoint found!");
		$self->{entrypoint} = $entrypoint;
		return $entrypoint->run();
	}
	# could've ended the loop without finding a compatible entrypoint
	return 0;
}

sub useAuthenModule {
	my ($self) = @_;
	my $entrypoint = $self->{entrypoint};
	return $entrypoint ? $entrypoint->useAuthenModule() : "";
}

sub getAuthenModule {
	my ($self) = @_;
	my $entrypoint = $self->{entrypoint};
	return $entrypoint ? $entrypoint->getAuthenModule() : "";
}

sub getErrorDisplayModule {
	my ($self) = @_;
	my $entrypoint = $self->{entrypoint};
	return $entrypoint ? $entrypoint->getErrorDisplayModule() : "";
}

sub useRedirect {
	my ($self) = @_;
	my $entrypoint = $self->{entrypoint};
	return $entrypoint ? $entrypoint->useRedirect() : "";
}

sub getRedirect {
	my ($self) = @_;
	my $entrypoint = $self->{entrypoint};
	return $entrypoint ? $entrypoint->getRedirect() : "";
}

1;
