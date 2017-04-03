package LogReader;

use strict;
use warnings;

use Data::Dumper;
use Dancer2;
use Dancer2::Plugin::Database;
use POSIX qw/ceil/;
use Time::Local;


our $VERSION 		 = '0.1';
our $NGINX_ERROR_LOG = '/home/alfred/webapps/LogReader/logs/error.log'; #'/var/log/nginx/summertimegoa/error.log';
our $ROWS_PER_PAGE   = 15;

hook after_request => sub {
    my $app = app();
    my $ses = session();
    $ses && $ses->is_dirty && $app->session_engine->flush( session => $ses );
};

prefix '/admin';

get '/log' => sub {
    redirect '/admin/log/domain/all/1';
};

get '/log/progress' => sub {
	return session('progress');
};

post '/log/domain' => sub {
	redirect '/admin/log/'.params->{domain}.'/all/1';
};

any [ 'get', 'post' ] => '/log/*/**' => sub { 

	# variables passed
	my ( $domain, $arg ) = splat;
	my $filterurl 	= @{$arg}[0] // 'all';
   	my $pageno 		= @{$arg}[1] // 0;
	my $fix    		= @{$arg}[2] // 0;
	
   	# declarations
	my $lastpage    = 1;
	my @data 		= ();
	my $alert 		= '';
	my $message		= '';
	my $rows        = 0;

	if ($filterurl eq 'filter'){
		$filterurl = params->{filterurl};
		$lastpage  = 1;
	};

	if ($filterurl eq 'insert'){
		$alert = insert_log($domain);
		$pageno = 1;
	};

	if ($filterurl eq 'delete'){
		$alert = delete_log($domain,params->{deletedate});
		$pageno = 1;
	};

	if ($fix){
		$alert = update_log($domain,params->{fix} );
	};

	if ($domain ne 'domain'){
		# domain has been selected, determine number of rows and pages
	    $rows	  = numrows($domain,$filterurl);
	    $lastpage = ceil($rows->{numrows}/$ROWS_PER_PAGE);

		# determine page number
		if ($pageno  > $lastpage) { $pageno = $lastpage;} 
		if ($pageno  < 1) 		  { $pageno = 1;} 

	    @data = read_log($domain,$filterurl,$pageno);
	}

	my @fqdn = domains();

    return template LogReader => { 
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
    };
};


# ------------- routines ----------------

sub domains {

    return database('sqlserver')->selectall_arrayref( "SELECT * from domains order by domain", { Slice => {} } );
}

sub euro_date{
	
	my $date = shift // '';
	my ($yyyy,$mm,$dd) = split /\//,$date;

	return "$dd/$mm/$yyyy";
}

sub delete_log {
    
    my $alert;
    my $date;

    if (params->{deletedate}){

    	$date = get_epoch_from_eu(params->{deletedate});
	    
	    my $qry = 'DELETE FROM error_log where date < ?';

	    my $sth = database('sqlserver')->prepare($qry);
	   	$sth->execute($date) or $alert->message="Unable to delete. ";
	   	$sth->finish;
   	}
   	

    $alert->{type}    = 'success';
	$alert->{message} = 'Log data up to '.params->{deletedate}. ' has been deleted from the database';

   	return $alert;
}

sub numrows {

	my $domain 		= shift // 'domain';
	my $filterurl 	= shift // 'all';

	return 0 unless ($domain ne 'domain');

    my 	$qry  = "SELECT count(*) as numrows, 
    					strftime('%d-%m-%Y',date(min(date),'unixepoch')) as firstdate, 
    					strftime('%d-%m-%Y',date(max(date),'unixepoch')) as lastdate 
    			FROM 	error_log where domain = ? and fix=0 ";

	if 		($filterurl eq 'images') 	{ $qry .= " and request like '%images%' GROUP BY request like '%images%'"; } 
	elsif 	($filterurl eq 'others')	{ $qry .= " and request not like '%images%' GROUP BY request not like '%images%'";	} 
	elsif 	($filterurl eq 'status')	{ $qry .= " GROUP BY status ";	}

	my $sth = database('sqlserver')->prepare($qry);
       $sth->execute($domain);
    my $row = $sth->fetchrow_hashref('NAME_lc');
       $sth->finish;

	return $row;
}

sub read_log {

	my $domain 	 		= shift // 'summertimegoa.com';
	my $filterurl 		= shift // 'all';
	my $pageno 			= shift // 1; 
	
	my $option 			= '';

	if 		($filterurl eq 'images') 	{ $option = " and request     like '%images%' GROUP BY request ";} 
	elsif 	($filterurl eq 'others')	{ $option = " and request not like '%images%' GROUP BY request ";} 
	elsif 	($filterurl eq 'status')	{ $option = " GROUP BY status, request ";	} 
	
    my $qry  = "SELECT strftime('%d-%m-%Y',date(date,'unixepoch')) as eudate, * 
    			FROM error_log WHERE domain like '$domain' and fix=0 $option 
    			ORDER BY date DESC 
    			LIMIT " .($pageno - 1) * $ROWS_PER_PAGE .", $ROWS_PER_PAGE";

    return database('sqlserver')->selectall_arrayref( $qry, { Slice => {} } );
}

sub insert_log {

	# variable passed
	my $domain = shift // 0;

	# initialise variables
	my @data;
	my $alert;
    my $fh;
    my $ph;
    my $counter  	  = 0;
    my $progress 	  = 0;
    my $progress_last = 0;
    my $progress_file = $domain.'.prog.txt';

 	# determine the last date entered
	my 	$lastdate = database('sqlserver')->selectrow_array("SELECT max(date) as lastdate FROM error_log WHERE domain like '%$domain%';");
		$lastdate = $lastdate // 0;

	# obtain the files handler
    unless (open (FH, '<:encoding(UTF-8)', $NGINX_ERROR_LOG)) {
    	$alert->{type} 		= 'warning';
    	$alert->{message}	= "Cannot open log file: $!";
    	return $alert;
    }

    # determine number of lines in the file
 	my @lines = <FH>;
 	my $progress_total = scalar @lines;
	seek FH, 0, 0;

	# prepare session variables
	my $application = app();
    my $session 	= session();

	# start the work
    while (my $line = <FH>) {

    	$counter += 1; 
    	
    	# start splittng the line into fields
		my @vars  = split / /, $line, 6;
		my @vars2 = split /,/, $vars[5];

		# determine the date of this entry
		my $thisdate = get_epoch( $vars[0], $vars[1] ); 
		# not all logs have a date
		$thisdate = time() unless $thisdate;
		# only enter new data
		next if ($thisdate < $lastdate);

		# update the progress session to monitor the progress
		if (($counter%100) == 0) {
			session 'progress' => (int($counter / $progress_total * 100) ) ;
			$application->session_engine->flush( session => $session );
		}

	    my $date		= get_epoch( $vars[0], $vars[1] );

		my $status 		= $vars[2] // '';
		   $status  	=~ s/[\[\]]//g;

		my $client      = $vars2[1] // '';
		my @client  	= split /:/, $client;
		   $client  	= $client[1] // '';
		   $client  	=~ s/^\s+|\s+$//g; # remove leading and trailing spaces

		my $server      = $vars2[2]  // '' ;
		my @server 		= split /:/, $server;
		   $server  	= $server[1] // '' ;
		   $server  	=~ s/^\s+|\s+$//g;

		my $requests 	= $vars2[3]  // '' ;
		   $requests 	=~ s/["]//g;
		my @requests 	= split /:/, $requests;
		my $requestz 	= $requests[1] // '   ';
		my @requestz 	= split / /, $requestz;
		my $request		= $requestz[2] // '';

	    my $method		= $requestz[1] // '' ;

	    my $host        = $vars2[4] // '' ;
		my @host 		= split /:/, $host;
		   $host    	= $host[1] // '' ;
		   $host    	=~ s/["]//g;
		   $host    	=~ s/^\s+|\s+$//g; 

		my $error   	= $vars2[0] // '' ;
		   $error   	=~ s/["]//g;
		   $error   	=~ s/open()//g;

	    # fields not utilised (as yet);
	    # $field->{three}  = $vars[3];
	    # $field->{four }  = $vars[4];
	    # $body_bytes_sent = $vars2[0];
	    
	    my $qry = qq(INSERT INTO error_log 	(date,status,client,server,request,method,host,error,fix,domain) 
	        			 	VALUES 			(?,?,?,?,?,?,?,?,0,?);); 

	    my $sth = database('sqlserver')->prepare($qry);
        $sth->execute("$date","$status","$client","$server","$request","$method","$host","$error","$domain") 
        	or die "Unable to insert.";
        $sth->finish;
    };
    close FH;

    session 'progress' => 100 ;
	$application->session_engine->flush( session => $session );

    $alert->{type}    = 'success';
	$alert->{message} = 'Log data inserted into the database';

	return $alert;
}


sub update_log {

    my $domain 	= shift // 0;
 	my @ids 	= shift;

 	my $error 	= 0;
 	my $alert;
 	my $i 		= 0;
 	
	my $qry = "UPDATE error_log SET fix = 1 WHERE domain = ? and request = 
 			(SELECT request FROM error_log WHERE domain = ? and id = ?)";
    my $sth = database('sqlserver')->prepare($qry);
   	
	if ( ref($ids[0]) ne 'ARRAY'){
	
		eval {
        	$sth->execute($domain,$domain,@ids) 
				or die "Unable to update. id: @ids";
		};

		if($@) { 
			$error = 1;
    	}

        $sth->finish;
    }
    else {
	
		while ($ids[0][$i] > 0 ) {
		
			my $key = $ids[0][$i];
	 		
			eval {
	        	$sth->execute($domain,$domain,$key) 
					or die "Unable to update. id: $key";
			};

			if($@) { 
				$error = 1;
	    	}

	        $sth->finish;

			$i += 1;
		} 
	}

    if ($error) {
  		$alert->{type}    = 'warning';
	   	$alert->{message} = "Unable to update an entry ";
    }    

    return $alert;
}

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

=head

drop table error_log;
CREATE TABLE error_log (
 id integer PRIMARY KEY,
 date integer NOT NULL,
 body_bytes_sent text , 
 status text,
 client text,
 server text,
 request text,
 method text,
 host text,
 error text,
 fix integer,
 domain integer);

drop table domains;
CREATE TABLE domains (
id integer PRIMARY KEY,
domain text);

INSERT INTO domains (domain) VALUES ('summertimegoa.com');
INSERT INTO domains (domain) VALUES ('odyssey.co.in');
INSERT INTO domains (domain) VALUES ('travellers-palm.com');
INSERT INTO domains (domain) VALUES ('solita.co.in');

=cut

1;