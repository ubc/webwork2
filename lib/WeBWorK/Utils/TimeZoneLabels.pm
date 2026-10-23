package WeBWorK::Utils::TimeZoneLabels;

# Time zone abbreviations that a jurisdiction officially uses but tzdata does
# not, applied to the labels WeBWorK prints (formatDateTime) and accepted back
# when set definition files are imported (parseDateTime).
#
# BC has stayed on UTC-7 since 2026-03-08: no fall back on 2026-11-01. tzdata
# (DateTime::TimeZone 2.68+) models that as America/Vancouver switching from
# PDT to "MST" on 2026-11-01, but BC's official name is Pacific Time, "PCT"
# (BC Citizens' Services news release 2026CITZ0009-001073, 2026-09-17). Only
# the abbreviation tzdata gives for the instant is replaced, so summer 2026
# still shows PDT, earlier winters PST, and other zones labelled MST (Edmonton,
# Phoenix, Dawson Creek) keep it. If tzdata adopts PCT itself, the label entry
# simply stops matching.
#
# Deliberately dependency free so it can be unit tested without DateTime.

use strict;
use warnings;

use Exporter 'import';
our @EXPORT_OK = qw(officialZoneLabel zoneNameForLabel);

# zone name => { tzdata abbreviation => official abbreviation }
my %OFFICIAL_LABELS = ('America/Vancouver' => { MST => 'PCT' });

# official abbreviation => zone name, for parsing
my %ZONE_FOR_LABEL =
	map {
		my $zone = $_;
		map { $_ => $zone } values %{ $OFFICIAL_LABELS{$zone} }
	} keys %OFFICIAL_LABELS;

# Replace the tzdata abbreviation in $text, which was formatted in $zone_name at
# an instant whose tzdata abbreviation is $abbreviation.
sub officialZoneLabel {
	my ($text, $zone_name, $abbreviation) = @_;
	return $text unless defined $zone_name && defined $abbreviation;
	my $official = $OFFICIAL_LABELS{$zone_name}{$abbreviation};
	return $text unless defined $official;
	return $text =~ s/\b\Q$abbreviation\E\b/$official/gr;
}

# The zone an official abbreviation stands for, or undef if it is not one.
sub zoneNameForLabel {
	my ($label) = @_;
	return undef unless defined $label && $label ne '';
	return $ZONE_FOR_LABEL{ uc $label };
}

1;
