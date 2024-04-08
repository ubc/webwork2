################################################################################
# WeBWorK Online Homework Delivery System
# Copyright &copy; 2000-2024 The WeBWorK Project, https://github.com/openwebwork
#
# This program is free software; you can redistribute it and/or modify it under
# the terms of either: (a) the GNU General Public License as published by the
# Free Software Foundation; either version 2, or (at your option) any later
# version, or (b) the "Artistic License" which comes with this package.
#
# This program is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
# FOR A PARTICULAR PURPOSE.  See either the GNU General Public License or the
# Artistic License for more details.
################################################################################

package WeBWorK::Authen::PreferExternalUnlessBypassed;
use Mojo::Base 'WeBWorK::Authen', -strict, -signatures;

use WeBWorK::Debug;

=head1 NAME

WeBWorK::Authen::PreferExternalUnlessBypassed - Same as Basic_TheLastOption,
but will insist users use the other external auth modules instead unless
explicitly told to bypass. This is also meant to be the last authen module in
the list and as such handles existing sessions that has already been authed.

=cut

sub request_has_data_for_this_verification_module ($self) {
	return 1;
}

sub do_verify ($self) {
	my $c    = $self->{c};
	
	if ($c->param('bypassShib')) {
		debug('Bypassing external auth to use internal login');
	}
	else {
		# make Login.pm tell users to use external auth, don't make internal
		# login available
		$self->{external_auth} = 1;
	}

	return $self->SUPER::do_verify(@_);
}

1;
