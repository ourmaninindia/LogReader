package LogReader;

use strict;
use warnings;

use Dancer2;
use Dancer2::Plugin::Database;
use LogReader::Database;

use Data::Dumper;
use POSIX qw/ceil/;
use Time::Local;
use Socket;

our $VERSION 		 = '0.1';
our $NGINX_ERROR_LOG = '/var/log/nginx/';
our $ROWS_PER_PAGE   = 15;

hook after_request => sub 
{
    my $app = app();
    my $ses = session();
    $ses && $ses->is_dirty && $app->session_engine->flush( session => $ses );
};

get '/' => sub 
{
    template dashboard => 
    {
    	domains     => domains(),
    };
};

get 'dns/:ip' => sub 
{
	my $host = gethostbyaddr(inet_aton(params->{ip}),AF_INET) // 'not found'; 
	insert_bots($host,params->{ip}) unless (index($host,'bot') == -1 || index($host,'spider') == -1);
    return $host;
};

get '/domains' => sub 
{
	my @dirs=();
	opendir(DIR, $NGINX_ERROR_LOG) or die "Can't opendir $NGINX_ERROR_LOG: $!";
 
    while (my $sub_folders = readdir(DIR)) 
    {
	    next if ($sub_folders =~ /^..?$/);  # skip . and ..
	    my $path = $NGINX_ERROR_LOG . '/' . $sub_folders;
	    next unless (-d $path);   # skip anything that isn't a directory
	    push @dirs, $sub_folders;
    }

    closedir(DIR);

	template domains => 
	{ 
        domains     => domains(),
        name        => params->{name},
        dirs		=> \@dirs,
    };
};

post '/domains/:option' => sub 
{
	if (params->{option} eq 'add')
	{ 
		my $ok = insert_domains(params->{name});
	} 
	elsif (params->{option} eq 'del')
	{ 
		my $ok = delete_domains(params->{delete});
	}

	redirect '../domains';
};


get '/logs' => sub 
{
	my @dirs=();
	opendir(DIR, $NGINX_ERROR_LOG) or die "Can't opendir $NGINX_ERROR_LOG: $!";
 
    while (my $sub_folders = readdir(DIR)) 
    {
	    next if ($sub_folders =~ /^..?$/);  # skip . and ..
	    my $path = $NGINX_ERROR_LOG . '/' . $sub_folders;
	    next unless (-d $path);   # skip anything that isn't a directory
	    push @dirs, $sub_folders;
    }

    closedir(DIR);

	template logs => 
	{ 
        logs        => logs(),
        name        => params->{name},
        url         => params->{url},
        dirs		=> \@dirs,
    };
};

post '/logs/:option' => sub 
{
	if (params->{option} eq 'add')
	{ 
		debug ;
		my $ok = insert_logs(params->{name},params->{url});
	} 
	elsif (params->{option} eq 'del')
	{ 
		my $ok = delete_logs(params->{delete});
	}

	redirect '../logs';
};


post '/bot/:ip' => sub
{
	my $host = gethostbyaddr(inet_aton(params->{ip}),AF_INET); 
	insert_bots($host,params->{ip});
};


get '/bots' => sub 
{
	my @bots = bots();

	template bots => 
	{ 
        bots => @bots,
    };
};

post '/bots/:option' => sub 
{
	if (params->{option} eq 'add'){ 
		my $ok = insert_bots(params->{ua},params->{ip});
	} elsif (params->{option} eq 'del'){ 
		my $ok = delete_bots(params->{delete});
	}

	redirect '../bots',
};


get '/progress' => sub 
{
	return session('progress');
};

post '/domain' => sub 
{
	redirect '/'.params->{domain}.'/000';
};

any [ 'get', 'post' ] => '/*/**' => sub 
{ 
	# variables passed
	my ( $domain, $arg ) = splat;
	my $filterurl 	= @{$arg}[0] // '000';
   	my $pageno 		= @{$arg}[1] // 0;
	my $fix    		= @{$arg}[2] // 0;
	
   	# declarations
	my $lastpage    = 1;
	my @data 		= ();
	my $alert 		= '';
	my $message		= '';
	my $rows        = 0;
	my $xImage 		= 0;
	my $xBot 		= 0;
	my $xCritic 	= 0;

	if ($filterurl eq 'filter')	{
		$xImage 	= substr($pageno,0,1);
		$xBot 		= substr($pageno,1,1);
		$xCritic 	= substr($pageno,2,1);
		$pageno 	= 1;
		$filterurl 	= "$xImage$xBot$xCritic"; 
	};

	if ($filterurl eq 'insert')	{
		$alert = insert_errorlogs($domain);
		$pageno = 1;
	};

	if ($filterurl eq 'delete')	{
		my $date 	= get_epoch_from_eu(params->{deletedate});
		$alert 		= delete_errorlogs( $domain, $date );
		$pageno 	= 1;
	};

	if ($fix){
		$alert = update_errorlogs(params->{fix},$domain );

	};

	if ($domain ne 'domain')	{
		# domain has been selected, determine number of rows and pages
	    $rows	  = numrows_errorlogs($domain,$filterurl);
	    $lastpage = ceil($rows->{numrows}/$ROWS_PER_PAGE);

		# determine page number
		if ($pageno  > $lastpage) { $pageno = $lastpage;} 
		if ($pageno  < 1) 		  { $pageno = 1;} 
	    @data = errorlogs($domain,$filterurl,$pageno);
	}

	my @fqdn = domains();

    template LogReader => 
    { 
    	pageno   	=> $pageno,
    	prevpage 	=> ($pageno == 1) ? 1 : ($pageno - 1),
    	lastpage 	=> $lastpage,
    	nextpage 	=> ($pageno +1),
        data 	 	=> @data,
        filterurl 	=> $filterurl,
        records		=> $rows,
        alert 	 	=> $alert,
        domains     => @fqdn,
        domain      => $domain,
        xImage  	=> $xImage,
        xBot        => $xBot,
        xCritic     => $xCritic,	
    };
};


# ------------- routines ----------------

sub get_epoch {
	
	my $date = shift // 0;
	my $time = shift // 0;

	my $standard_time = 0;

	my ($yyyy, $mm,  $dd ) = (split /\//,$date)[0,1,2];
	my ($hour, $min, $sec) = (split /:/ ,$time)[0,1,2];

	if (defined $mm && $mm > 0) {
		$standard_time = timelocal($sec, $min, $hour, $dd, $mm -1, ($yyyy - 1900));
	} 
	
	return $standard_time;
}

sub get_epoch_from_eu {
	
	my $date = shift // '00-00-0000';
	my $time = shift // '0:0:0';

	my $standard_time = 0;
	
	my ($dd, $mm,  $yyyy ) = (split /-/,$date)[0,1,2];
	my ($hour, $min, $sec) = (split /:/,$time)[0,1,2];
	
	if ($mm > 0) {
		$standard_time = timelocal($sec, $min, $hour, $dd, $mm -1, ($yyyy - 1900));
	} 
	
	return $standard_time;
}


1;
