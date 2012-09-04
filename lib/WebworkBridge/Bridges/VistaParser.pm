#use lib "$ENV{WEBWORK_ROOT}/lib";

package WebworkBridge::Bridges::VistaParser;
use base qw(WebworkBridge::Parser);

use strict;
use warnings;

use WeBWorK::Debug;
use WebworkBridge::Importer::Error;

##### Exported Functions #####
sub new
{
	my ($class, $r, $course_ref, $students_ref) = @_;
	my $self = $class->SUPER::new($r, $course_ref, $students_ref);
	bless $self, $class;
	return $self;
}

sub parse
{
	my ($self, $param) = @_;
	my $course = $self->{course};
	my $students = $self->{students};
	my @lines = split(/\n/, $param);
	my $count = 0;

	%{$course} = ();
	@{$students} = ();

	foreach (@lines)
	{
		if (/^\s*$/)
		{ # ignore empty lines
			next;
		}
		elsif (substr($_,0,2) eq ':)')
		{ # we can ignore status reports preceded by :)
			next;
		}
		elsif (substr($_,0,6) eq 'Course')
		{
			%{$course} = $self->parseCourse($_);
			unless (%{$course})
			{
				return error("Parsing of course data from Vista failed on this line: " . $_ . " END", "#e012");
			}
		}
		elsif (substr($_,0,9) eq 'Firstname')
		{
			my %tmp = $self->parseStudent($_);
			if ($tmp{'drop'})
			{
				next;
			}
			unless (%tmp)
			{
				return error("Parsing of student data from Vista failed on this line: " . $_ . " END","#e013");
			}
			push(@{$students}, \%tmp);
		}
		else
		{ # an error occurred
			return error("Parsing of data from Vista failed on this line: " . $_ . " END","#e014");
		}
		
		$count++;
	}

	unless (%{$course} && @{$students})
	{
		return error("Missing course and/or student information from the import.", "#e019");
	}
	return 0;
}

##### Helper Functions #####

sub parseStudent
{
	my ($self, $param) = @_;
	my $r = $self->{r};
	my %student;
	# our data is tab delimited
	my @data = split(/\t/, $param);
	# start processing data
	foreach (@data)
	{ # start processing data
		my @setting = split(/=/, $_); # data in the form of <name>=<val>
		if ($setting[0] eq 'Firstname')
		{ # sets student number, e.g.: John
			$student{'firstname'} = $setting[1];
		}
		elsif ($setting[0] eq 'Lastname')
		{ #	sets the student name, e.g.: Smith
			$student{'lastname'} = $setting[1];
		}
		elsif ($setting[0] eq 'Password')
		{ #	sets the student section, e.g.: password 
			$student{'password'} = $setting[1];
		}
		elsif ($setting[0] eq 'Webctid')
		{ #	sets the Vista learning context id (lcid) e.g.: s12345678
			$student{'loginid'} = $setting[1];
			$student{'studentid'} = substr($setting[1], 1);
			foreach ($r->ce->{bridge}{vista_blacklist})
			{
				if ($student{'loginid'} =~ m/$_/)
				{
					debug("Blacklisted student ".$student{'loginid'}.
						" dropped from import");
					$student{'drop'} = 1;
				}
			}
		}
	}
	$student{'email'} = ""; # no email address from Vista, unfortunately
	$student{'permission'} = $r->{ce}->{userRoles}{student};
	unless (defined $student{'firstname'} && 
			defined $student{'lastname'} &&
			defined $student{'password'} &&
			defined $student{'loginid'} &&
			defined $student{'studentid'})
	{ # any missing data means we've failed
		return;
	}
	return %student;
}

sub parseCourse
{
	my ($self, $param) = @_;
	my %course;
	# our data is tab delimited
	my @data = split(/\t/, $param);
	# start processing data
	foreach (@data)
	{ # start processing data
		my @setting = split(/=/, $_); # data in the form of <name>=<val>
		if ($setting[0] eq 'Course')
		{ # sets course number, e.g.: MATH 101
			$course{'course'} = $setting[1];
		}
		elsif ($setting[0] eq 'Name')
		{ #	sets the course name, e.g.: Integral Calculus
			$course{'title'} = $setting[1];
		}
		elsif ($setting[0] eq 'Section')
		{ #	sets the course section, e.g.: 100 
			$course{'section'} = $setting[1]; # only used locally
		}
		elsif ($setting[0] eq 'Sectionid')
		{ #	sets the Vista learning context id (lcid) e.g.: 23152160021
			$course{'id'} = $setting[1];
		}
	}

	unless (defined $course{'title'} &&
			defined $course{'course'} &&
			defined $course{'section'} &&
			defined $course{'id'})
	{ # any missing data means we've failed
		return;
	}
	$course{'name'} = $self->getCourseName($course{'course'}, $course{'section'});
	$course{'vistaname'} = $course{'course'} . ' - ' . $course{'section'};
	delete($course{'course'});
	delete($course{'section'});
	return %course;
}

# test code
#open FILE, "sampleoutput" or die "Cannot open XML file. $!";
#
#my $input = join("",<FILE>);
#
#my %course = ();
#my @students = ();
#
#my $parser = WebworkBridge::Bridges::VistaParser->new(\%course, \@students);
#my $ret = $parser->parse($input, \%course, \@students);
#print "Returned: $ret\n";
#
#$Data::Dumper::Indent = 3;
#print "Course Info: \n";
#print Dumper(\%course);
#
#print "\n\nStudents List: \n";
#print Dumper(\@students);

1;

