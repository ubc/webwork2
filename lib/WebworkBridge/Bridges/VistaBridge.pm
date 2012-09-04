package WebworkBridge::Bridges::VistaBridge;
use base qw(WebworkBridge::Bridge);

##### Library Imports #####
use strict;
use warnings;
use WeBWorK::CourseEnvironment;
use WeBWorK::DB;
use WeBWorK::Debug;
use WeBWorK::Utils qw(runtime_use readFile cryptPassword);

use Net::OAuth;
use HTTP::Request::Common;
use LWP::UserAgent;

use WebworkBridge::Importer::Error;
use WebworkBridge::Bridges::VistaParser;

# Constructor
sub new 
{
	my ($class, $r) = @_;
	my $self = $class->SUPER::new($r);
	bless $self, $class;
	return $self;
}

sub accept
{
	my $self = shift;
	my $r = $self->{r};
	
	if ($r->param("vistawebworkimport") ||
		$r->param("vistalogin"))
	{
		return 1;
	}

	return 0;
}

# In order to simplify, we use the Webwork root URL for all LTI actions,
# e.g.: http://137.82.12.77/webworkdev/
# Cases to handle:
# * The course does not yet exist
# ** If user is instructor, ask if want to create course
# ** If user is student, inform that course does not exist
# * The course exists
# ** SSO login

sub run
{
	my $self = shift;
	my $r = $self->{r};
	my $ce = $r->ce;

	if ($r->param("vistawebworkimport"))
	{
		debug(("-" x 80) . "\n");
		debug("Vista data import requested.\n");

		$self->{useDisplayModule} = 1;
		
		if (!$r->param("vistaid") || !$r->param("userfirst") ||
			!$r->param("userlast") || !$r->param("userlast") ||
			!$r->param("lcid"))
		{
			return error("Vista data import failed, missing parameters.\n", "#e007");
		}

		debug("Parameters looks good. Vista data import in progress.\n");
		return $self->_runImport();
	}

	my ($login_enable, $login_course, $login_section);
	if (exists $ce->{bridge}{vista_login_options})
	{
		$login_enable = $ce->{bridge}{vista_login_options}{"enable_param"};
		$login_course = $ce->{bridge}{vista_login_options}{"course_param"};
		$login_section = $ce->{bridge}{vista_login_options}{"section_param"};
	}
	else
	{
		return error("Missing configuration values for Vista Login", "#e001");
	}


	if ($r->param($login_enable) && $ce->{"courseName"})
	{ # we have both the courseID and we want Vista login
		debug("Using Vista's Login2 module, we have a course ID.\n");
		$self->{useAuthenModule} = 1;
	}
	elsif ($r->param($login_enable) && $r->param($login_course))
	{ # we want vista login, but we don't have the courseID, will have to 
		# redirect to put the courseID in
		debug("Using Vista's Login2 module, redirecting to get a course ID.\n");
		my $parser = WebworkBridge::Bridges::VistaParser->new($r);

		my $courseName = $parser->getCourseName(
			$r->param($login_course),
			$r->param($login_section)
		);
		use CGI;
		my $q = CGI->new();
		print $q->redirect($r->uri . "$courseName/?" . $r->args);

	}
}

sub getAuthenModule
{
	my $self = shift;
	my $r = $self->{r};
	return WeBWorK::Authen::class($r->ce, "vista_login");
}

sub _runImport
{
	my $self = shift;
	my $r = $self->{r};

	# get data from java import
	my $data = "";
	my $ret = $self->_runJavaImport(\$data);
	if ($ret)
	{
		return error("Unable to run importer for Vista data: $data", "#e004");
	}
	# parse
	my %course = ();
	my @students = ();
	my $parser = WebworkBridge::Bridges::VistaParser->new($r, \%course, \@students);
	$ret = $parser->parse($data);
	if ($ret)
	{
		return error("Parsing of Vista import failed.", "#e002");
	}
	$course{'profid'} = $r->param('vistaid');
	my %prof = (
		firstname => $r->param('userfirst'),
		lastname => $r->param('userlast'),
		loginid => $course{'profid'},
		studentid => substr($course{'profid'}, 1),
		permission => $r->{ce}->{userRoles}{professor},
		email => '',
		password => '',
	);

	push(@students, \%prof);

	# store user data in loginlist
	$self->_updateLoginList($course{'profid'}, $course{'id'}, $course{'name'}, 
		$course{'vistaname'});
	# make ce, check for course existence
	my $tmpce = WeBWorK::CourseEnvironment->new({
			%WeBWorK::SeedCE,
			courseName => $course{'name'}
		});
	# update or create as needed
	if (-e $tmpce->{courseDirs}->{root})
	{
		return $self->updateCourse(\%course, \@students);
	}
	else
	{
		return $self->createCourse(\%course, \@students);
	}
}

sub _runJavaImport
{
	my ($self, $res) = @_;
	my $r = $self->{r};
	my $profid = $r->param('vistaid');
	my $courseid = $r->param('lcid');
	my $jar = $r->ce->{bridge}{vista_importer};

	my $cmd = "java -jar $jar $profid $courseid";
	return WebworkBridge::Importer::CourseCreator::customExec($cmd, $res);
}

sub _updateLoginList
{
	my ($self, $profid, $courseid, $course, $vistaname) = @_;

	my $file = $self->{r}->ce->{bridge}{vista_loginlist};
	my $time = POSIX::strftime("%Y-%m-%d %H:%M:%S", localtime);

	my $info = "$profid\t$courseid\t$course\t$vistaname\t$time\n";

	if (-e $file)
	{
		my $ret = open FILE, "+<$file";
		if (!$ret)
		{
			return error("Update Login List Failed: Unable to open the loginlist file.","#e011");
		}
		my @lines = <FILE>;
		foreach (@lines)
		{
			my @line = split(/\t/,$_);
			if ($line[0] eq $profid && $line[1] eq $courseid)
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
