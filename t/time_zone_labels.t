#!/usr/bin/env perl

# WeBWorK::Utils::TimeZoneLabels swaps a tzdata abbreviation for the one a
# jurisdiction officially uses. BC has stayed on UTC-7 since 2026-03-08; tzdata
# (DateTime::TimeZone 2.68+) labels America/Vancouver "MST" from 2026-11-01,
# but BC's official name is Pacific Time, "PCT".

use strict;
use warnings;

use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";

use WeBWorK::Utils::TimeZoneLabels qw(officialZoneLabel zoneNameForLabel);

# formatDateTime output for 2026-12-01 23:59 in America/Vancouver.
is(
	officialZoneLabel('December 1, 2026, 11:59:00 PM MST', 'America/Vancouver', 'MST'),
	'December 1, 2026, 11:59:00 PM PCT',
	'student date format: MST becomes PCT in America/Vancouver'
);
is(
	officialZoneLabel('12/01/2026 at 11:59pm MST', 'America/Vancouver', 'MST'),
	'12/01/2026 at 11:59pm PCT',
	'set definition export format: MST becomes PCT'
);

# Only the abbreviation tzdata gave for this instant is touched.
is(
	officialZoneLabel('July 14, 2026, 11:59:00 PM PDT', 'America/Vancouver', 'PDT'),
	'July 14, 2026, 11:59:00 PM PDT',
	'summer 2026 keeps PDT'
);
is(
	officialZoneLabel('December 31, 2025, 11:59:00 PM PST', 'America/Vancouver', 'PST'),
	'December 31, 2025, 11:59:00 PM PST',
	'winter 2025 keeps PST'
);

# Other zones that tzdata also labels MST are really on Mountain Standard Time.
is(
	officialZoneLabel('12/01/2026 at 11:59pm MST', 'America/Edmonton', 'MST'),
	'12/01/2026 at 11:59pm MST',
	'America/Edmonton keeps MST'
);
is(
	officialZoneLabel('12/01/2026 at 11:59pm MST', 'America/Phoenix', 'MST'),
	'12/01/2026 at 11:59pm MST',
	'America/Phoenix keeps MST'
);
is(
	officialZoneLabel('12/01/2026 at 11:59pm MST', 'America/Dawson_Creek', 'MST'),
	'12/01/2026 at 11:59pm MST',
	'America/Dawson_Creek (BC, but on MST for decades) keeps MST'
);

# Whole-word replacement only, and missing inputs pass the text through.
is(officialZoneLabel('MSTX 11:59pm MST', 'America/Vancouver', 'MST'), 'MSTX 11:59pm PCT',
	'only the whole word changes');
is(officialZoneLabel('December 1, 2026', 'America/Vancouver', 'MST'), 'December 1, 2026', 'no label in the text');
is(officialZoneLabel('x MST',            undef,               undef), 'x MST', 'undefined zone and abbreviation');
is(officialZoneLabel('x MST',            'America/Vancouver', undef), 'x MST', 'undefined abbreviation');

# Parsing set definition files: PCT must lead back to the zone.
is(zoneNameForLabel('PCT'), 'America/Vancouver', 'PCT parses as America/Vancouver');
is(zoneNameForLabel('pct'), 'America/Vancouver', 'case-insensitive');
is(zoneNameForLabel('MST'), undef,               'MST is left to DateTime::TimeZone (a valid zone name)');
is(zoneNameForLabel(''),    undef,               'empty');
is(zoneNameForLabel(undef), undef,               'undefined');

done_testing();
