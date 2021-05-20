################################################################################
# WeBWorK Online Homework Delivery System
# Copyright © 2000-2021 The WeBWorK Project, http://openwebwork.sf.net/
# $CVSHeader: webwork2/lib/WeBWorK/DB/Record/LTIAdvantage/ResourceLink.pm,v 1.47 2021/05/19 22:59:55 wheeler Exp $
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
package WeBWorK::DB::Record::LTIAdvantage::ResourceLink;
use base WeBWorK::DB::Record;

=head1 NAME

WeBWorK::DB::Record::LTIAdvantage::ResourceLink - represent a record from the lti resource link table.

=cut

use strict;
use warnings;

BEGIN {
	__PACKAGE__->_fields(
		client_id => { type=>"TINYBLOB NOT NULL", key=>1 },
		context_id => { type=>"TINYBLOB NOT NULL", key=>1 },
		resource_link_id => { type=>"TINYBLOB NOT NULL", key=>1 },
		set_id => { type=>"TINYBLOB" },

		# assignment and grade services
		lineitems_url => { type=>"TINYBLOB" },
		lineitem_url => { type=>"TINYBLOB" },
		scope_lineitem => { type=>"TINYBLOB" },
		scope_lineitem_read_only => { type=>"TINYBLOB" },
		scope_result_readonly => { type=>"TINYBLOB" },
		scope_result_score => { type=>"TINYBLOB" },

		# resource link is valid or not
		is_valid => { type=>"TINYINT DEFAULT 1" }
	);
}

1;
