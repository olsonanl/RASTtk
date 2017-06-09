=head1 Create a PATRIC login token.

    p3-login username [options]

    Create a PATRIC login token, used with workspace operations

=cut

#
# Create a PATRIC login token.
#

use strict;
use LWP::UserAgent;
use Getopt::Long::Descriptive;
use Term::ReadKey;
use Data::Dumper;
use P3DataAPI;

our $have_config_simple;
eval {
    require Config::Simple;
    $have_config_simple = 1;
};

my $auth_url = "https://user.patricbrc.org/authenticate";
my $token_path = $P3DataAPI::token_path || "$ENV{HOME}/.patric_token";
my $max_tries = 3;

my($opt, $usage) = describe_options("%c %o username",
				    ["help|h" => "Show this help message."],
				    );
print($usage->text), exit 0 if $opt->help;
die($usage->text) unless @ARGV == 1;

my $username = shift;

$username =~ s/\@patricbrc.org$//;

my $ua = LWP::UserAgent->new;

for my $try (1..$max_tries)
{
    my $password = get_pass();
    
    my $req = {
	username => $username,
	password => $password,
    };

    my $res = $ua->post($auth_url, $req);
    if ($res->is_success)
    {
	my $token = $res->content;
	if ($token =~ /un=([^|]+)/)
	{
	    my $un = $1;
	    open(T, ">", $token_path) or die "Cannot write token file $token_path: $!\n";
	    print T "$token\n";
	    chmod 0600, \*T;
	    close(T);

	    #
	    # Write to our config files too.
	    #
	    if ($have_config_simple)
	    {
		write_config("$ENV{HOME}/.patric_config", "P3Client.token", $token, "P3Client.user_id", $un);
		write_config("$ENV{HOME}/.kbase_config", "authentication.token", $token, "authentication.user_id", $un);
	    }
	    else
	    {
		warn "Perl library Config::Simple not available; not updating .patric_config or .kbase_config\n";
	    }
	    print "Logged in with username $un\n";
	    exit 0;
	}
	else
	{
	    die "Token has unexpected format\n";
	}
    }
    else
    {
	print "Sorry, try again.\n";
    }
}

die "Too many incorrect login attempts; exiting.\n";

sub write_config
{
    my($file, @pairs) = @_;
    my $cfg = Config::Simple->new(syntax => 'ini');
    if (-f $file)
    {
	$cfg->read($file);
    }
    while (@pairs)
    {
	my($key, $val) = splice(@pairs, 0, 2);
	$cfg->param($key, $val);
    }
    $cfg->save($file);
}

sub get_pass {
    if ($^O eq 'MSWin32')
    {
	$| = 1;
	print "Password: ";
	ReadMode('noecho');
	my $password = <STDIN>;
	chomp($password);
	print "\n";
	ReadMode(0);
	return $password;
    }
    else
    {
	my $key  = 0;
	my $pass = "";
	print "Password: ";
	ReadMode(4);
	while ( ord($key = ReadKey(0)) != 10 ) {
	    # While Enter has not been pressed
	    if (ord($key) == 127 || ord($key) == 8) {
		chop $pass;
		print "\b \b";
	    } elsif (ord($key) < 32) {
		# Do nothing with control chars
	    } else {
		$pass .= $key;
		print "*";
	    }
	}
	ReadMode(0);
	print "\n";
	return $pass;
    }
}

