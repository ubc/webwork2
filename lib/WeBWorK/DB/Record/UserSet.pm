################################################################################
# WeBWorK Online Homework Delivery System
# Copyright � 2000-2006 The WeBWorK Project, http://openwebwork.sf.net/
# $CVSHeader: webwork2/lib/WeBWorK/DB/Record/UserSet.pm,v 1.15 2006/12/01 17:04:03 glarose Exp $
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

package WeBWorK::DB::Record::UserSet;
use base WeBWorK::DB::Record;

=head1 NAME

WeBWorK::DB::Record::UserSet - represent a record from the set_user table.

=cut

use strict;
use warnings;

BEGIN {
	__PACKAGE__->_fields(
		user_id                   => { type=>"TINYBLOB NOT NULL", key=>1 },
		set_id                    => { type=>"TINYBLOB NOT NULL", key=>1 },
		psvn                      => { type=>"INT UNIQUE NOT NULL AUTO_INCREMENT" },
		set_header                => { type=>"TEXT" },
		hardcopy_header           => { type=>"TEXT" },
		open_date                 => { type=>"BIGINT" },
		due_date                  => { type=>"BIGINT" },
		answer_date               => { type=>"BIGINT" },
		published                 => { type=>"INT" },
		assignment_type           => { type=>"TEXT" },
		attempts_per_version      => { type=>"INT" },
		time_interval             => { type=>"INT" },
		versions_per_interval     => { type=>"INT" },
		version_time_limit        => { type=>"INT" },
		version_creation_time     => { type=>"BIGINT" },
		problem_randorder         => { type=>"INT" },
		version_last_attempt_time => { type=>"BIGINT" },
		problems_per_page         => { type=>"INT" },
                hide_score                => { type=>"ENUM('0','1','2')" },
                hide_work                 => { type=>"ENUM('0','1','2')" },
		time_limit_cap            => { type=>"ENUM('0','1')" },
	);
}

1;
