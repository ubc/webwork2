package WeBWorK::ContentGenerator::WebworkBridgeStatus;
use base qw(WeBWorK::ContentGenerator);

=head1 NAME

WeBWorK::ContentGenerator::WebworkBridgeStatus - Webwork Bridge Status.

=cut

use strict;
use warnings;
use WeBWorK::CGI;
use WeBWorK::Debug;

use constant MP2 => ( exists $ENV{MOD_PERL_API_VERSION} and $ENV{MOD_PERL_API_VERSION} >= 2 );

sub body {
	my ($self) = @_;
	my $r = $self->r;
	my $ce = $r->ce;

	# check for error messages to display
	my $error_message = MP2 ? $r->notes->get("error_message") : $r->notes("error_message");
	print $error_message;

	return "";
}

1;
