################################################################################
# WeBWorK Online Homework Delivery System
# Copyright © 2000-2018 The WeBWorK Project, http://openwebwork.sf.net/
# $CVSHeader: webwork2/lib/WeBWorK/DB/Record/LTIContexts.pm,v 1.47 2017/06/08 22:59:55 wheeler Exp $
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
package WeBWorK::DB::Record::LTIContexts;
use base WeBWorK::DB::Record;

=head1 NAME

WeBWorK::DB::Record::LTIContexts - represent a record from the lti contexts table.

=cut

use strict;
use warnings;

BEGIN {
	__PACKAGE__->_fields(
		client_id => { type=>"TINYBLOB NOT NULL", key=>1 },
		context_id => { type=>"TINYBLOB NOT NULL", key=>1 },
		course_id => { type=>"TEXT" },
		automatic_updates => { type=>"TINYINT" },

		# names and roles provising services
		context_memberships_url => { type=>"TINYBLOB" }
	);
}

1;
