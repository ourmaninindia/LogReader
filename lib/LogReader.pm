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
#use LWP::Simple qw/head/;
use LWP::UserAgent;
use open qw(:std :utf8);

our $VERSION 		 = '0.1';
our $NGINX_ERROR_LOG = '/var/log/nginx';
our $ROWS_PER_PAGE   = 15;

hook after_request => sub 
{
    my $app = app();
    my $ses = session();
    $ses && $ses->is_dirty && $app->session_engine->flush( session => $ses );
};

get '/' => sub 
{
	my @domains = domains();
	my $i 		= 0;
	my $ua 		= LWP::UserAgent->new( ssl_opts => { verify_hostname => 0 } );

	while ($domains[0][$i]){
		
		my $url=$domains[0][$i]->{fqdn};

		$domains[0][$i]->{up} = 0; 

		if ( defined($url)>0 ) {
			my $response = $ua->head($url);
			debug $url;
			debug to_dumper($response);

			if ( $response->is_success ) {
				$domains[0][$i]->{up} = 1; 
			}
		}
		$i++;
    }
    template dashboard =>  {
    	domains     => @domains,
    };
};

get 'dns/:ip' => sub 
{
	my $host = gethostbyaddr(inet_aton(params->{ip}),AF_INET) // 'not found'; 
	insert_bots($host,params->{ip}) unless (index($host,'bot') == -1 || index($host,'spider') == -1);
    return $host;
};

get '/clients' => sub 
{
	template clients => 
	{ 
        clients => clients(),
    };
};

post '/clients/:option' => sub 
{
	if (params->{option} eq 'add')
	{ 
		insert_clients(params->{client},params->{email});
	} 
	elsif (params->{option} eq 'del')
	{ 
		delete_clients(params->{delete});
	}
	elsif (params->{option} eq 'update')
	{
		update_clients(params->{id},params->{client},params->{email});
	}

	redirect '../clients';
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
        clients     => clients(),
        name        => params->{name},
        dirs		=> \@dirs,
    };
};

post '/domains/:option' => sub 
{
	if (params->{option} eq 'add')
	{ 
		my $ok = insert_domains(params->{domain},params->{fqdn},params->{image_url});
	} 
	elsif (params->{option} eq 'del')
	{ 
		my $ok = delete_domains(params->{delete});
	}
	elsif (params->{option} eq 'update')
	{
		my $ok = update_domains(params->{id},params->{domain},params->{fqdn},params->{image_url},params->{client});
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

post '/error/domain' => sub 
{
	redirect '../error/'.params->{domain}.'/000';
};

any [ 'get', 'post' ] => '/error/*/**' => sub 
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

    template LogReader => 
    { 
    	pageno   	=> $pageno,
    	prevpage 	=> ($pageno == 1) ? 1 : ($pageno - 1),
    	lastpage 	=> $lastpage,
    	nextpage 	=> ($pageno +1),
        data 	 	=> ((scalar @data > 0) ? @data : ''),
        filterurl 	=> $filterurl,
        records		=> $rows,
        alert 	 	=> $alert,
        domains     => domains(),
        domain      => $domain,
        xImage  	=> $xImage,
        xBot        => $xBot,
        xCritic     => $xCritic,	
    };
};

any [ 'get', 'post' ] => '/access/*/**' => sub 
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
	my $xStatus 	= 0;

	if ($filterurl eq 'filter')	{
		$xImage 	= substr($pageno,0,1) // 0 ;
		$xBot 		= substr($pageno,1,1) // 0 ;
		$xStatus 	= substr($pageno,2,3) // 0 ;
		$pageno 	= 1;
		$filterurl 	= "$xImage$xBot$xStatus"; 
	};

	if ($filterurl eq 'insert')	{
		$alert = insert_accesslogs($domain);
		$pageno = 1;
	};

	if ($filterurl eq 'delete')	{
		my $date 	= get_epoch_from_eu(params->{deletedate});
		$alert 		= delete_accesslogs( $domain, $date );
		$pageno 	= 1;
	};

	if ($fix){
		$alert = update_accesslogs(params->{fix},$domain );

	};

	if ($domain ne 'domain')	{
		# domain has been selected, determine number of rows and pages
	    $rows	  = numrows_accesslogs($domain,$filterurl);
	    $lastpage = ceil($rows->{numrows}/$ROWS_PER_PAGE);

		# determine page number
		if ($pageno  > $lastpage) { $pageno = $lastpage;} 
		if ($pageno  < 1) 		  { $pageno = 1;} 
	    @data = accesslogs($domain,$filterurl,$pageno);
	}

    template access => 
    { 
    	pageno   	=> $pageno,
    	prevpage 	=> ($pageno == 1) ? 1 : ($pageno - 1),
    	lastpage 	=> $lastpage,
    	nextpage 	=> ($pageno +1),
        data 	 	=> ((scalar @data > 0) ? @data : ''),
        filterurl 	=> $filterurl,
        records		=> $rows,
        alert 	 	=> $alert,
        domains     => domains(),
        domain      => $domain,
        xImage  	=> $xImage,
        xBot        => $xBot,
        xStatus		=> $xStatus,
        codes 		=> codes_accesslogs($domain),	
    };
};

get '/status-codes' => sub {
	template status_codes => 
	{
		codes => status_codes(),
	}
};

post '/status-codes/:option' => sub 
{
	if ((params->{option} eq 'add') || (params->{option} eq 'update')) { 
		insert_status_codes(params->{code},params->{title},params->{explanation},params->{rfc});
	} elsif (params->{option} eq 'del'){ 
		delete_status_codes(params->{delete});
	}

	redirect '../status-codes';
};

get '/enter-status-codes' => sub {

    open (FH, '<:encoding(UTF-8)', "/home/alfred/webapps/statuscodes") or die "Cannot open file : $!";

    while (my $line = <FH>) 
    {
        my ($one,$expl) 	= split /\|/, $line; 
        my ($code,$titlex) 	= split / /,$one,2;
        my ($title,$rfc) 	= split /\(/,$titlex;
        $rfc =~ tr/)//;
      	insert_status_codes("$code","$title","$expl","$rfc");
    };
    close FH;
};

post '/access/domain' => sub 
{
	redirect '../access/'.params->{domain}.'/000';
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

sub month2num {
	my $month = shift;
	my %mon2num = qw(jan 1  feb 2  mar 3  apr 4  may 5  jun 6  jul 7  aug 8  sep 9  oct 10 nov 11 dec 12);
	return $mon2num{ lc substr($month, 0, 3) };
}

1;
