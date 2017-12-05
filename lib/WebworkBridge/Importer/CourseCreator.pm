package WebworkBridge::Importer::CourseCreator;

##### Library Imports #####
use strict;
use warnings;
#use lib "$ENV{WEBWORK_ROOT}/lib"; # uncomment for shell invocation

use WeBWorK::CourseEnvironment;
use WeBWorK::DB;
use WeBWorK::Debug;
use WeBWorK::Utils qw(runtime_use readFile cryptPassword);

use WebworkBridge::Importer::Error;

use App::Genpass;
use Text::CSV;

# Constructor
sub new
{
	my ($class, $r, $course_ref, $students_ref) = @_;
	my $self = {
		r => $r,
		course => $course_ref,
		students => $students_ref
	};
	bless $self, $class;
	return $self;
}

sub createCourse
{
	my $self = shift;

	my $error = $self->createClassList();
	if ($error) { return $error; }

	$error = $self->runAddCourse();
	if ($error) { return $error; }

	return 0;
}

sub runAddCourse
{
	my $self = shift;
	my $ce = $self->{r}->ce;

	my $classlistfile = $self->getClasslistdir();
	my $profid = $self->{course}->{profid};
	my $course = $self->{course}->{name};

	# notice admin id
	my $cmd = "addcourse --users='$classlistfile' --professors=$profid,admin $course";
	if ($ce->{bridge}{course_template})
	{
		$cmd .= " --templates-from=" . $ce->{bridge}{course_template};
	}
	if (!defined $ENV{WEBWORK_ROOT})
	{
		if (%WeBWorK::SeedCE)
		{
			$ENV{WEBWORK_ROOT} = $WeBWorK::SeedCE{webwork_dir};
		}
		else
		{
			return error("Add course failed, WEBWORK_ROOT not defined in environment.","#e017");
		}
	}
	$cmd = $ENV{WEBWORK_ROOT}."/bin/$cmd";
	my $msg;
	my $ret = customExec($cmd, \$msg);
	if ($ret != 0)
	{ # script failed for some reason
		return error("Add course failed, script failure: $msg", "e018");
	}

	if ($ce->{bridge}{hide_new_courses}) {
		my $message = 'Place a file named "hide_directory" in a course or other directory '.
			'and it will not show up in the courses list on the WeBWorK home page. '.
			'It will still appear in the Course Administration listing.';
		my $coursesDir = $ce->{webworkDirs}->{courses};
		local *HIDEFILE;
		if (open (HIDEFILE, ">","$coursesDir/$course/hide_directory")) {
			print HIDEFILE "$message";
			close HIDEFILE;
		} else {
			return error("Add course failed, hide directory failure", "e022");
		}
	}

	my $tmpce = WeBWorK::CourseEnvironment->new({
		%WeBWorK::SeedCE,
		courseName => $course
	});
	my $db = new WeBWorK::DB($tmpce->{dbLayout});
	if ($self->{course}->{title}) {
		$db->setSettingValue('courseTitle',$self->{course}->{title});
	}

	return 0;
}

sub createClassList
{
	my $self = shift;
	my $r = $self->{r};	
	my $ce = $self->{r}->{ce};

	my %course = %{$self->{course}};
	my @students = @{$self->{students}};

	my $classlistfile = $self->getClasslistdir();

	my $ret = open FILE, ">$classlistfile";
	if (!$ret)
	{
		return error("Course Creation Failed: Unable to create a classlist file.","#e010");
	}
	print FILE "# studentid, lastname, firstname, status, comment, section, recitation, email, loginid, password, permission\n";

	# write students
	# profid may be a comma separated list of ids, to support multiple profs
	my @profid = split(/,/, $course{profid});
	my $genpass = App::Genpass->new(length=>16);
	foreach my $i (@students)
	{
		my $id = $i->{'loginid'};
		print FILE "$i->{'studentid'},"; # student id
		print FILE "\"$i->{'lastname'}\","; # last name
		print FILE "\"$i->{'firstname'}\","; # first name
		($i->{'permission'} > $ce->{userRoles}{student}) ? 
			print FILE "P," : 
			print FILE "C,"; # status
		print FILE ","; # comment
		print FILE ","; # section
		print FILE ","; # recitation
		$i->{email} ? 
			print FILE $i->{email} ."," : 
			print FILE $self->getEmaillistEntry($i->{'studentid'}) .",";
		print FILE "$id,"; # login id
		$i->{password} ? 
			print FILE cryptPassword($i->{password})."," : 
			print FILE $genpass->generate,","; # password
		print FILE "$i->{'permission'}\n"; # permission
	}

	# add admin user
	my $adminstring = "admin,admin,admin,P,,,,,admin," .
		cryptPassword($r->ce->{bridge}{adminuserpw}) . ",10\n";
	print FILE $adminstring;

	close FILE;

	return 0;
}

sub getClasslistdir
{
	my $self = shift;
	my $course = $self->{course}->{name};
	return $self->{r}->ce->{bridge}{classlistdir} . $course;
}

sub getEmaillistEntry
{
	my ($self, $id) = @_;

	my $file = $self->{r}->ce->{bridge}{emaillist};
	if (-e $file)
	{
		my $ret = open EMAILLISTFILE, "+<$file";
		if (!$ret)
		{
			error("Unable to open the emaillist file.","#e019");
			return "";
		}

		my $csv = Text::CSV->new();

		my @lines = <EMAILLISTFILE>;
		foreach (@lines)
		{
			if ($csv->parse($_))
			{
				my @line = $csv->fields();
				if ($line[2] eq $id)
				{
					debug("Email match found for $id on line $_");
					return $line[3];
				}
			}
		}
		close EMAILLISTFILE;
	}

	return "";
}

# Perl 5.8.8 doesn't let you override `` for testing. This sub gets
# around that since we can still override subs.
sub customExec
{
	my $cmd = shift;
	my $msg = shift;

	$$msg = `$cmd 2>&1`;
	if ($?)
	{
		return 1;	
	}
	return 0;
}

1;
