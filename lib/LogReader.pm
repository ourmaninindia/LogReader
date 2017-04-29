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
use LWP::UserAgent;
use LWP::Protocol::https;

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
	my $ref 	= $domains[0];
	my @ref 	= @$ref;
	my $size 	= scalar @ref;

	for (my $i = 0; $i < $size; $i++) 
	{
		if ($domains[0][$i]->{domain} eq 'LogReader') {
			$domains[0][$i]->{up} = 1;
		} 
		elsif (length $domains[0][$i]->{fqdn})
		{	
			my $response = $ua->head($domains[0][$i]->{fqdn});
			$domains[0][$i]->{up} = ( $response->is_success ) ? 1 : 0; 
	    }
    }

    template dashboard =>  {
    	domains => @domains,
    };
};

post '/access/domain' => sub 
{
	redirect '../access/'.params->{domain}.'/000';
};


any [ 'get', 'post' ] => '/access/*/**' => sub 
{ 
	# variables passed
	my ( $domain, $arg ) = splat;
	my $filter 		= @{$arg}[0] // '000';
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

	$xImage 	= substr($filter,0,1) // 0 ;
	$xBot 		= substr($filter,1,1) // 0 ;
	$xStatus 	= substr($filter,2,3) // 0 ;

	if ($fix eq 'insert')	{
		$alert = insert_accesslogs($domain);
	} elsif ($fix eq 'delete')	{
		my $date = get_epoch_from_eu(params->{deletedate});
		$alert = delete_accesslogs( $domain, $date );
	} elsif ($fix eq 'fix'){
		$alert = update_accesslogs(params->{fix},$domain );
	};

	if ($domain ne 'domain')	{
		# domain has been selected, determine number of rows and pages
	    $rows	  = numrows_accesslogs($domain,$filter);
	    $lastpage = ceil($rows/$ROWS_PER_PAGE);

		# determine page number
		if ($pageno  > $lastpage) { $pageno = $lastpage;} 
		if ($pageno  < 1) 		  { $pageno = 1;} 
	    @data = accesslogs($domain,$filter,$pageno);
	}

    template access => 
    { 
    	pageno   	=> $pageno,
    	prevpage 	=> ($pageno == 1) ? 1 : ($pageno - 1),
    	lastpage 	=> $lastpage,
    	nextpage 	=> ($pageno +1),
        data 	 	=> ((scalar @data > 0) ? @data : ''),
        filtr 		=> $filter,
        records		=> $rows,
        alert 	 	=> $alert,
        domains     => domains(),
        domain      => $domain,
        xImage  	=> $xImage,
        xBot        => $xBot,
        xStatus		=> $xStatus,
        codes 		=> codes_accesslogs($domain),
        dates 		=> dates_accesslogs($domain),
        rows     	=> $rows,	
    };
};

get '/bots' => sub 
{
	my @bots = bots();

	template bots => 
	{ 
        bots => @bots,
    };
};

post '/bot/:ip' => sub
{
	my $host = gethostbyaddr(inet_aton(params->{ip}),AF_INET); 
	insert_bots($host,params->{ip});
};

post '/bots/:option' => sub 
{
	if (params->{option} eq 'add'){ 
		insert_bots(params->{ua},params->{ip},params->{spam});
	} elsif (params->{option} eq 'del'){ 
		delete_bots(params->{delete});
	} elsif (params->{option} eq 'update'){
		update_bots(params->{bots_id},params->{ua},params->{ip},params->{date},params->{spam});
	}

	redirect '../bots',
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
	my $alert;

	opendir(my $handle, $NGINX_ERROR_LOG) or $alert = "danger: Can't opendir $NGINX_ERROR_LOG: $!";

    while (my $folder = readdir($handle)) 
    {
	    next if ($folder =~ /^..?$/);  # skip . and ..
	    my $path = $NGINX_ERROR_LOG . '/' . $folder;
	    next unless (-d $path);   # skip anything that isn't a directory
	    push @dirs, $folder;
    }

    closedir($handle);

    @dirs = sort @dirs;

	template domains => 
	{ 
        domains     => domains(),
        clients     => clients(),
        name        => params->{name},
        dirs		=> \@dirs,
        alert       => $alert,
    };
};

post '/domains/:option' => sub 
{
	if (params->{option} eq 'add')
	{ 
		insert_domains(params->{domain},params->{fqdn},params->{port},params->{image_url},params->{clients_id});
	} 
	elsif (params->{option} eq 'del')
	{ 
		delete_domains(params->{domains_id});
	}
	elsif (params->{option} eq 'update')
	{
		update_domains(params->{domains_id},params->{domain},params->{fqdn},params->{port},params->{image_url},params->{clients_id});
	}

	redirect '../domains';
};

get 'dns/:ip' => sub 
{
	my $host = gethostbyaddr(inet_aton(params->{ip}),AF_INET) // 'not found'; 
	insert_bots($host,params->{ip}) unless (index($host,'bot'   ) == -1);
	insert_bots($host,params->{ip}) unless (index($host,'spider') == -1);
    return $host;
};

post '/error/domain' => sub 
{
	redirect '../error/'.params->{domain}.'/000';
};

any [ 'get', 'post' ] => '/error/*/**' => sub 
{ 
	# variables passed
	my ( $domain, $arg ) = splat;
	my $filter	 	= @{$arg}[0] // '000';
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

	$xImage 	= substr($filter,0,1);
	$xBot 		= substr($filter,1,1);
	$xStatus 	= substr($filter,2,1);

	if ($fix eq 'insert')	{
		$alert = insert_errorlogs($domain);
	} elsif ($fix eq 'delete')	{
		my $date 	= get_epoch_from_eu(params->{deletedate});
		$alert 		= delete_errorlogs( $domain, $date, params->{deletedate} );
	} elsif ($fix eq 'fix'){
		$alert = update_errorlogs(params->{fix},$domain );
	};

	if ($domain ne 'domain')	{
		# domain has been selected, determine number of rows and pages
	    $rows	  = numrows_errorlogs($domain,$filter);
	    $lastpage = ceil($rows->{numrows}/$ROWS_PER_PAGE);

		# determine page number
		if ($pageno  > $lastpage) { $pageno = $lastpage;} 
		if ($pageno  < 1) 		  { $pageno = 1;} 
	    @data = errorlogs($domain,$filter,$pageno);
	}

    template LogReader => 
    { 
    	pageno   	=> $pageno,
    	prevpage 	=> ($pageno == 1) ? 1 : ($pageno - 1),
    	lastpage 	=> $lastpage,
    	nextpage 	=> ($pageno +1),
        data 	 	=> ((scalar @data > 0) ? @data : ''),
        filtr 	 	=> $filter,
        records		=> $rows,
        alert 	 	=> $alert,
        domains     => domains(),
        domain      => $domain,
        xImage  	=> $xImage,
        xBot        => $xBot,
        xStatus     => $xStatus,	
    };
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
		insert_logs(params->{name},params->{url});
	} 
	elsif (params->{option} eq 'del')
	{ 
		delete_logs(params->{delete});
	}

	redirect '../logs';
};

get '/progress' => sub 
{
	return session('progress');
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



# ------------- routines ----------------

sub get_epoch {
	
	my $date = shift // '00-00-0000';
	my $time = shift // '0:0:0';

	my $standard_time 	   = 0;
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
	
	my ($dd, $mm,  $yyyy ) = (split /\//,$date)[0,1,2];
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