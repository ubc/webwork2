package WebworkBridge::Bridge;

##### Library Imports #####
use strict;
use warnings;
use WeBWorK::CourseEnvironment;
use WeBWorK::DB;
use WeBWorK::Debug;

use WebworkBridge::Importer::Error;
use WebworkBridge::Importer::CourseCreator;
use WebworkBridge::Importer::CourseUpdater;

# Constructor
sub new
{
	my ($class, $r) = @_;
	my $self = {
		r => $r,
		useAuthenModule => 0,
		useDisplayModule => 0,
		homeworkSet => 0,
		quizSet => 0
	};
	bless $self, $class;
	return $self;
}

sub accept
{
	my $self = shift;
	return 0;
}

sub run
{
	my $self = shift;
	die "Not implemented";
}

# Returns whether this module requires the use of a custom display module
sub useDisplayModule
{
	my $self = shift;
	return $self->{useDisplayModule};
}

# Returns whether this module requires the use of a custom authen module
sub useAuthenModule
{
	my $self = shift;
	return $self->{useAuthenModule};
}

sub getDisplayModule
{
	my $self = shift;
	return "WeBWorK::ContentGenerator::WebworkBridgeStatus";
}

sub getAuthenModule
{
	my $self = shift;
	die "Not implemented";
}

sub getHomeworkSet
{
	my $self = shift;
	return $self->{homeworkSet};
}

sub getQuizSet
{
	my $self = shift;
	return $self->{quizSet};
}

sub createCourse
{
	my ($self, $course, $users) = @_;

	my $creator = WebworkBridge::Importer::CourseCreator->new($self->{r}, $course, $users);
	my $ret = $creator->createCourse();
	if ($ret)
	{
		return error("Failed to create course: $ret", "#e004");
	}

	return 0;
}

sub updateCourse
{
	my ($self, $course, $users) = @_;

	my $creator = WebworkBridge::Importer::CourseUpdater->new($self->{r}, $course, $users);
	my $ret = $creator->updateCourse();
	if ($ret)
	{
		return error("Failed to update course: $ret", "#e004");
	}

	return 0;
}

sub updateLoginList
{
	# fieldsList is required to have
	# Element 0 as the user id
	# Element 1 is the course name in webwork
	# so that we can check duplicate entries
	my ($self, $file, $fieldsList) = @_;
	my @fields = @{$fieldsList};

	my $time = POSIX::strftime("%Y-%m-%d %H:%M:%S", localtime);
	my $info = "";

	foreach (@fields)
	{
		$info .= "$_\t";
	}
	$info .= "$time\n";

	if (-e $file)
	{
		my $ret = open FILE, "+<$file";
		if (!$ret)
		{
			return error("Update Login List Failed. Unable to open the loginlist file: $file","#e011");
		}
		my @lines = <FILE>;
		foreach (@lines)
		{
			my @line = split(/\t/,$_);
			# if an entry already exists for the same course, ignore
			if ($line[1] eq $fields[1])
			{
				return 0;
			}
		}
		print FILE $info;
		close FILE;
	}
	else
	{
		open FILE, ">$file";
		print FILE $info;
		close FILE;
	}
	return 0;
}

1;
