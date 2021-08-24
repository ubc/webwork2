################################################################################
# WeBWorK Online Homework Delivery System
# Copyright © 2000-2021 The WeBWorK Project, http://openwebwork.sf.net/
# $CVSHeader: webwork2/lib/WeBWorK/DB/Record/DelayedJob/Funcmap.pm,v 1.47 2021/05/19 22:59:55 wheeler Exp $
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
package WeBWorK::DB::Record::DelayedJob::Funcmap;
use base WeBWorK::DB::Record;

=head1 NAME

WeBWorK::DB::Record::DelayedJob::Funcmap

=cut

use strict;
use warnings;

BEGIN {
	__PACKAGE__->_fields(
		funcid => { type=>"INT UNSIGNED PRIMARY KEY NOT NULL AUTO_INCREMENT" },
		funcname => { type=>"VARCHAR(255) NOT NULL", key=>1 },
	);
}

1;
