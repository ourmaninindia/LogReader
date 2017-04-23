package LogReader::Database;

use strict;
use warnings;

use Dancer2;
use Dancer2::Plugin::Database;

use Data::Dumper;
use Exporter qw{import};

our @EXPORT = qw{
    accesslogs
    numrows_accesslogs
    codes_accesslogs
    insert_accesslogs
    update_accesslogs
    delete_accesslogs
    bots
    get_id_bots
    insert_bots
    update_bots
    delete_bots
    clients
    insert_clients
    update_clients
    delete_clients
    domains 
    insert_domains
    update_domains
    delete_domains
    errorlogs
    numrows_errorlogs
    insert_errorlogs
    update_errorlogs
    delete_errorlogs
    logs 
    insert_logs
    delete_logs
    status_codes
    insert_status_codes
    update_status_codes
    delete_status_codes
    get_id_status_codes
};

our $VERSION = '0.1';

=head
access_log (date,status,ua,request,method,protocol,domain

drop table access_log;
CREATE TABLE access_log (
 id integer PRIMARY KEY,
 date integer NOT NULL,
 status text,
 ua text,
 request text,
 method text,
 protocol text,
 ip text,
 host text,
 size integer,
 domain integer);

drop table bots;
CREATE TABLE bots (
bots_id integer PRIMARY KEY,
ua text,
ip text,
datum integer NOT NULL,
spam integer);

drop table clients;
CREATE TABLE clients (
clients_id integer PRIMARY KEY,
client text,
email text);

drop table domains;
CREATE TABLE domains (
domains_id integer PRIMARY KEY,
domain text,
fqdn text,
port integer,
image_url,
clients_id integer);

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
 domain integer);

drop table logs;
CREATE TABLE logs (
id_logs integer PRIMARY KEY,
log text,
url text);

drop table status_codes;
CREATE TABLE status_codes (
 id integer PRIMARY KEY,
 code integer,
 title text,
 rfc text,
 explanation text);

ALTER TABLE domains ADD COLUMN url text;

Sort access by Response Codes
cat access.log | cut -d '"' -f3 | cut -d ' ' -f2 | sort | uniq -c | sort -rn

Broken links
awk '($9 ~ /404/)' access.log | awk '{print $7}' | sort | uniq -c | sort -rn

Most requested URLs
awk -F\" '{print $2}' access.log | awk '{print $2}' | sort | uniq -c | sort -r

Most requested URLs containing XYZ
awk -F\" '($2 ~ "ref"){print $2}' access.log | awk '{print $2}' | sort | uniq -c | sort -r


=cut


sub accesslogs 
{
  my $domain      = shift // 'domain';
  my $filterurl   = shift // '00000';
  my $pageno      = shift // 1; 
  
  my $option      = '';
  my @array       = ();

    return @array unless ($domain ne 'domain');
    # filter on images
    if (substr($filterurl,0,1) == 1) { 
        $option .= " and RIGHT(request,4) = 'jpeg' OR RIGHT(request,3) IN ('jpg', 'gif', 'png', 'svg') ";
    } 
    elsif (substr($filterurl,0,1) == 2) {
        $option .= " and RIGHT(request,4) <> 'jpeg' OR RIGHT(request,3) NOT IN ('jpg', 'gif', 'png','svg') ";
    } 

    # filter on bots
    if (substr($filterurl,1,1)==1) { 
        $option .= " and bots.ip is null"; 
    }
    elsif (substr($filterurl,1,1)==2){
        $option .= " and bots.ip is not null"; 
    }
  
    # filter on status code
    if (int(substr($filterurl,2,3)) > 0){ 
        $option .= ' and status = '.substr($filterurl,2,3).' '; 
    }
 
    my $qry  = "SELECT count(*) as cnt, strftime('%d-%m-%Y %H:%M',datetime(a.date,'unixepoch')) as eudate, a.id as theid, 
                    date,status,a.ua,a.ip,host,request,method,protocol,domain,size, bots.ua as bot 
                    FROM access_log a LEFT JOIN bots on a.ip = bots.ip 
                    WHERE domain like '$domain' $option 
                    GROUP BY request 
                    ORDER BY a.date DESC LIMIT " .($pageno - 1) * $LogReader::ROWS_PER_PAGE .','. $LogReader::ROWS_PER_PAGE;

    return database('sqlserver')->selectall_arrayref( $qry, { Slice => {} } );
}


sub numrows_accesslogs 
{
    my $domain      = shift // 'domain';
    my $filterurl   = shift // '00000';
    my $option      = '';
    
    return 0 unless ($domain ne 'domain');

    # filter on images
    if (substr($filterurl,0,1) == 1) { 
        $option .= " and RIGHT(request,4) = 'jpeg' OR RIGHT(request,3) IN ('jpg', 'gif', 'png', 'svg') ";
    } 
    elsif (substr($filterurl,0,1) == 2) {
        $option .= " and RIGHT(request,4) <> 'jpeg' OR RIGHT(request,3) NOT IN ('jpg', 'gif', 'png','svg') ";
    } 

    # filter on bots
    if (substr($filterurl,1,1)==1) { 
        $option .= " and bots.ip is null"; 
    }
    elsif (substr($filterurl,1,1)==2){
        $option .= " and bots.ip is not null"; 
    }

    # filter on status code  
    if (substr($filterurl,2,3) > 0){ 
        $option .= ' and status = '.substr($filterurl,2,3).' '; 
    }
 
    my  $qry = "SELECT  count(*) as numrows, 
                        strftime('%d-%m-%Y %H:%M',datetime(min(firstdate),'unixepoch')) as firstdate, 
                        strftime('%d-%m-%Y %H:%M',datetime(max(lastdate ),'unixepoch')) as lastdate 
                FROM 
                (
                  SELECT  count(*) as numrows,  
                          datetime(min(date) as firstdate, 
                          datetime(max(date) as lastdate  
                  FROM    access_log 
                  WHERE   domain like ? $option 
                )";

    my $sth = database('sqlserver')->prepare($qry);
    $sth->execute($domain);
    my $row = $sth->fetchrow_hashref('NAME_lc');
    $sth->finish;

    return $row;
}

sub codes_accesslogs {

    my $domain  = shift // 'code'; 
    my $qry     = "SELECT status, title FROM access_log a left join status_codes s on a.status=s.code WHERE domain like '$domain' GROUP BY status";
    return database('sqlserver')->selectall_arrayref( $qry, { Slice => {} } );
}

sub insert_accesslogs 
{
  # variable passed
  my $domain = shift // 0;

  # initialise variables
  my @data;
  my $alert;
  my $fh;
  my $ph;
  my $counter       = 0;
  my $progress      = 0;
  my $progress_last = 0;

  # determine the last date entered
  my  $lastdate = database('sqlserver')->selectrow_array("SELECT max(date) as lastdate FROM access_log WHERE domain like '%$domain%';");
      $lastdate = $lastdate // 0;

    # obtain the files handler
    unless (open (FH, '<:encoding(UTF-8)', $LogReader::NGINX_ERROR_LOG."/$domain/access.log")) {
        $alert->{type}    = 'warning';
        $alert->{message} = "Cannot open log file ".$LogReader::NGINX_ERROR_LOG."/$domain/access.log: $!";
        return $alert;
    }

    # determine number of lines in the file
    my @lines = <FH>;
    my $progress_total = scalar @lines // 1;
    seek FH, 0, 0;

    # prepare session variables
    my $application = app();
    my $my_session  = LogReader::session();

    my $qry = q/INSERT INTO access_log (date,status,ua,ip,host,request,method,protocol,domain,size) 
               VALUES (?,?,?,?,?,?,?,?,?,?);/; 
    my $sth = database('sqlserver')->prepare($qry);

    # start the work
    while (my $line = <FH>) 
    {
        $counter += 1; 

        # start splittng the line into fields
        my @vars    = split / /, $line, 9;
        my $ip      = $vars[0]; 
        my @status  = split / /,$vars[8];
        my $size    = $status[1];
        my $status  = $status[0];
        my @quotes  = $line =~ /"([^"]*)"/g;
        my $host    = $quotes[1];
        my $ua      = $quotes[2];
        my ($method,$request,$protocol) = split / /,$quotes[0];
          
        # determine the date of this entry
        my ($dd,$mm,$year) = split /\//, (substr $vars[3],1);
        my ($yyyy,$hour,$min,$sec) = split /:/,$year;
        my $thisdate  = LogReader::timelocal($sec, $min, $hour, $dd, LogReader::month2num($mm) -1, ($yyyy - 1900));
        my $date      = $thisdate // time();

        # only enter new data
        next if ($thisdate < $lastdate);

        # update the progress session to monitor the progress
        if (($counter%100) == 0) {
            LogReader::session( 'progress' => (int($counter / $progress_total * 100)) ) ;
            $application->session_engine->flush( session => $my_session );
        }

        $sth->execute("$date","$status","$ua","$ip","$host","$request","$method","$protocol","$domain",$size) 
            or die 'Unable to insert.';
        $sth->finish;
    };
    close FH;

    LogReader::session( 'progress' => 100 );
    $application->session_engine->flush( session => $my_session );

    $alert->{type}    = 'success';
    $alert->{message} = 'Log data inserted into the database';

    return $alert;
}


sub update_accesslogs 
{
    my @ids     = shift;
    my $domain  = shift;
    my $error   = 0;
    my $alert;
    my $i       = 0;
      
    my $qry = q/DELETE FROM access_log WHERE domain like ? and request = 
      (
        SELECT request FROM error_log WHERE domain like ? and id = ?
      )/;
    my $sth = database('sqlserver')->prepare($qry);
        
    if ( ref($ids[0]) ne 'ARRAY') {
        eval { $sth->execute($domain,$domain,@ids) or die "Unable to update. id: @ids";};

        if($@) { 
            $error = 1;
        }
        $sth->finish;
    }
    else {
        while ($ids[0][$i] > 0 ) 
        {
            eval { $sth->execute($domain,$domain,$ids[0][$i]) or die 'Unable to update. id: '.$ids[0][$i]; };

            if($@) { 
                $error = 1;
            }
            $sth->finish;
            $i += 1;
        } 
    }
    if ($error){
        $alert->{type}    = 'warning';
        $alert->{message} = "Unable to update an entry: $qry";
    }    

    return $alert;
}



sub bots 
{
    return database('sqlserver')->selectall_arrayref( "SELECT 
      strftime('%d-%m-%Y %H:%M',datetime(datum,'unixepoch')) as eudate, 
      * FROM bots ORDER BY bots_id", { Slice => {} } );
}

sub get_id_bots 
{
    my $ip  = shift // 'no ip';
    my $sth = database('sqlserver')->prepare(q/SELECT bots_id from bots where ip like ?/);
       $sth->execute($ip);
    my $id  = $sth->fetchrow_arrayref;
       $sth->finish;
    return $id;
}

sub insert_bots 
{
    my ($ua, $ip, $spam) = @_ ;

    if ( defined get_id_bots($ip) ) 
    {
        # update
        my $sth = database('sqlserver')->prepare(q/UPDATE bots SET datum = ?, spam = ? /);
           $sth->execute( time(), $spam ) or die "Cannot update bots with ip=$ip";
           $sth->finish;
    }
    else 
    {
        if (length $ip > 0) {
            # insert
            my $sth = database('sqlserver')->prepare(q/INSERT INTO bots (ua,ip,datum,spam) VALUES (?,?,?,?);/);
               $sth->execute( $ua,$ip,time(),$spam );
               $sth->finish;
        }
    }
    return
}

sub update_bots 
{
    my $bots_id = shift // 0;
    my $ua      = shift // '';
    my $ip      = shift // '';
    my $date    = shift;
    my $spam    = shift // 0;

    $date = $date ? LogReader::get_epoch_from_eu($date) : time();

    my $sth = database('sqlserver')->prepare(q/UPDATE bots SET ua=?,ip=?,datum=?,spam=? WHERE bots_id = ?;/);
    $sth->execute( $ua,$ip,$date,$spam,$bots_id );
    $sth->finish;
    
    return
}

sub delete_bots 
{
    my $id = shift // 0;

    return 0 unless ($id > 0 );

    my $sth = database('sqlserver')->prepare(q/DELETE FROM bots WHERE id = ?;/);
    $sth->execute($id) or die "Unable to delete.";
    $sth->finish;
    return 1; 
}



sub clients 
{
    return database('sqlserver')->selectall_arrayref( "SELECT * from clients order by client", { Slice => {} } );
}

sub insert_clients 
{
  my $client    = shift // '';
  my $email     = shift // '';
  
  return 0 unless (length($client) != 0 );

  my $qry = q/INSERT INTO clients (client,email) VALUES (?,?);/; 

  my $sth = database('sqlserver')->prepare($qry);
     $sth->execute("$client","$email") or die "Unable to insert.";
     $sth->finish;

  return 1; 
}

sub update_clients 
{
  my $id        = shift // 0;
  my $client    = shift // '';
  my $email     = shift // '';
  
  return 0 unless ($id);

  my $qry = q/UPDATE clients SET client=?,email=? WHERE clients_id=?;/; 

  my $sth = database('sqlserver')->prepare($qry);
     $sth->execute("$client","$email",$id) or die "Unable to update.";
     $sth->finish;

  return 1; 
}

sub delete_clients 
{
    my $id = shift // 0;

    return 0 unless ($id != 0 );

    my $qry = q/DELETE FROM clients WHERE clients_id = ?;/; 

    my $sth = database('sqlserver')->prepare($qry);
    $sth->execute($id) or die "Unable to delete.";
    $sth->finish;

    return 1; 
}




sub domains 
{
    return database('sqlserver')->selectall_arrayref( "SELECT * FROM domains d LEFT JOIN clients c ON d.clients_id=c.clients_id order by client,domain", { Slice => {} } );
}

sub insert_domains 
{
    my $domain     = shift // '';
    my $fqdn       = shift // '';
    my $port       = shift // 0;
    my $image_url  = shift // '1600x900.png';
    my $clients_id = shift // 0;

  return 0 unless (length($domain) != 0 );

  my $qry = qq(INSERT INTO domains (domain,fqdn,port,image_url,clients_id) VALUES (?,?,?,?,?);); 

  my $sth = database('sqlserver')->prepare($qry);
     $sth->execute("$domain","$fqdn",$port,"$image_url",$clients_id) or die "Unable to insert.";
     $sth->finish;

  return 1; 
}

sub update_domains 
{
  my $id         = shift // 0;
  my $domain     = shift // '';
  my $fqdn       = shift // '';
  my $port       = shift // 0;
  my $image_url  = shift // '';
  my $clients_id = shift // '';

  return 0 unless ($id);

  my $qry = q/UPDATE domains SET domain=?,fqdn=?,port=?,image_url=?,clients_id=? WHERE domains_id=?;/; 

  my $sth = database('sqlserver')->prepare($qry);
     $sth->execute("$domain","$fqdn",$port,"$image_url",$clients_id,$id) or die "Unable to update.";
     $sth->finish;

  return 1; 
}

sub delete_domains 
{
    my $domains_id = shift // 0;

    return 0 unless ($domains_id != 0 );

    my $qry = q/DELETE FROM domains WHERE domains_id = ?;/; 

    my $sth = database('sqlserver')->prepare($qry);
    $sth->execute($domains_id) or die "Unable to delete.";
    $sth->finish;

    return 1; 
}



sub errorlogs 
{
  my $domain      = shift // 'domain';
  my $filterurl   = shift // '000';
  my $pageno      = shift // 1; 
  
  my $option      = '';
  my @array       = ();

    return @array unless ($domain ne 'domain');
    # filter on images
    if (substr($filterurl,0,1) == 1) { 
        $option .= " and request like '%images%' ";
    } 
    elsif (substr($filterurl,0,1) == 2) {
        $option .= " and request not like '%images%' ";
    } 

    # filer on bots
    if (substr($filterurl,1,1)==1) { 
        $option .= " and bots.ip is null"; 
    }
    elsif (substr($filterurl,1,1)==2){
        $option .= " and bots.ip is not null"; 
    }
  
    # filter on status
    if (substr($filterurl,2,1)==1){ 
        $option .= " and status like 'error' "; 
    }
    elsif (substr($filterurl,2,1)==2){ 
        $option .= " and status like 'crit' "; 
    }
 
    my $qry  = "SELECT count(*) as cnt, strftime('%d-%m-%Y %H:%M',datetime(e.date,'unixepoch')) as eudate, e.id as theid, * 
                    FROM error_log e LEFT JOIN bots on e.client = bots.ip 
                    WHERE domain like '$domain' $option 
                    GROUP BY request 
                    ORDER BY e.date DESC LIMIT " .($pageno - 1) * $LogReader::ROWS_PER_PAGE .','. $LogReader::ROWS_PER_PAGE;

    return database('sqlserver')->selectall_arrayref( $qry, { Slice => {} } );
}

sub numrows_errorlogs 
{
    my $domain      = shift // 'domain';
    my $filterurl   = shift // '000';
    my $option      = '';
    
    return 0 unless ($domain ne 'domain');

    # filter on images
    if (substr($filterurl,0,1) == 1) { 
        $option .= " and request like '%images%' ";
    } 
    elsif (substr($filterurl,0,1) == 2) {
        $option .= " and request not like '%images%' ";
    } 

    # filer on bots
    if (substr($filterurl,1,1)==1) { 
        $option .= " and bots.ip is null"; 
    }
    elsif (substr($filterurl,1,1)==2){
        $option .= " and bots.ip is not null"; 
    }
  
    # filter on status
    if (substr($filterurl,2,1)==1){ 
        $option .= " and status like 'error' "; 
    }
    elsif (substr($filterurl,2,1)==2){ 
        $option .= " and status like 'crit' "; 
    }
 
    my  $qry  =  "SELECT  count(*) as numrows, 
                          strftime('%d-%m-%Y %H:%M',datetime(min(firstdate),'unixepoch')) as firstdate, 
                          strftime('%d-%m-%Y %H:%M',datetime(max(lastdate ),'unixepoch')) as lastdate 
                  FROM 
                  (
                    SELECT  min(e.date) as firstdate, 
                            max(e.date) as lastdate  
                    FROM    error_log e LEFT JOIN bots on e.client = bots.ip 
                    WHERE   domain like ? $option  GROUP BY request
                  );";

    my $sth = database('sqlserver')->prepare($qry);
    $sth->execute($domain);
    my $row = $sth->fetchrow_hashref('NAME_lc');
    $sth->finish;

    return $row;
}


sub insert_errorlogs 
{
  # variable passed
  my $domain = shift // 0;

  # initialise variables
  my @data;
  my $alert;
  my $fh;
  my $ph;
  my $counter       = 0;
  my $progress      = 0;
  my $progress_last = 0;

  # determine the last date entered as not to enter old entries twice
  my  $lastdate = database('sqlserver')->selectrow_array("SELECT max(date) as lastdate FROM error_log WHERE domain like '%$domain%';");
      $lastdate = $lastdate // 0;

  # obtain the files handler
  unless (open (FH, '<:encoding(UTF-8)', $LogReader::NGINX_ERROR_LOG."/$domain/error.log")) {
    $alert->{type}    = 'warning';
    $alert->{message} = "Cannot open log file ".$LogReader::NGINX_ERROR_LOG."/$domain/error.log: $!";
    return $alert;
  }

  # determine number of lines in the file
  my @lines = <FH>;
  my $progress_total = scalar @lines // 1;
  seek FH, 0, 0;

  # prepare session variables
  my $application = app();
  my $my_session  = LogReader::session();

    my $qry = q/INSERT INTO error_log (date,status,client,server,request,method,host,error,fix,domain) 
                VALUES (?,?,?,?,?,?,?,?,0,?);/; 
    my $sth = database('sqlserver')->prepare($qry);

  # start the work
  while (my $line = <FH>) 
  {
      $counter += 1; 
      
      # start splittng the line into fields
      my @vars  = split / /, $line, 6;
      my @vars2 = split /,/, $vars[5];

      # determine the date of this entry
      my $thisdate = LogReader::get_epoch( $vars[0], $vars[1] ); 
      my $date     = $thisdate;
      # not all logs have a date     
      $thisdate = time() unless $thisdate > 0;
      # only enter new data
      next if ($thisdate < $lastdate);
      
debug $vars[0]." this date=$date last date = $lastdate";
      
      # update the progress session to monitor the progress
      if (($counter%100) == 0) 
      {
        LogReader::session( 'progress' => (int($counter / $progress_total * 100)) ) ;
        $application->session_engine->flush( session => $my_session );
      }
      
      my $status    = $vars[2] // '';
         $status    =~ s/[\[\]]//g;

      my $client    = $vars2[1] // '';
      my @client    = split /:/, $client;
         $client    = $client[1] // '';
         $client    =~ s/^\s+|\s+$//g; # remove leading and trailing spaces

      my $server      = $vars2[2]  // '' ;
      my @server    = split /:/, $server;
         $server    = $server[1] // '' ;
         $server    =~ s/^\s+|\s+$//g;

      my $requests  = $vars2[3]  // '' ;
         $requests  =~ s/["]//g;
      my @requests  = split /:/, $requests;
      my $requestz  = $requests[1] // '   ';
      my @requestz  = split / /, $requestz;
      my $request   = $requestz[2] // '';

      my $method    = $requestz[1] // '' ;

      my $host      = $vars2[4] // '' ;
      my @host      = split /:/, $host;
         $host      = $host[1] // '' ;
         $host      =~ s/["]//g;
         $host      =~ s/^\s+|\s+$//g; 

      my $error     = $vars2[0] // '' ;
         $error     =~ s/["]//g;
         $error     =~ s/open()//g;

        # fields not utilised (as yet);
        # $field->{three}  = $vars[3];
        # $field->{four }  = $vars[4];
        # $body_bytes_sent = $vars2[0];

        next if (index($request,'.well-known') > -1); # a known PHP google bot
        
        $sth->execute("$date","$status","$client","$server","$request","$method","$host","$error","$domain") 
            or die "Unable to insert.";
        $sth->finish;
  };
  close FH;

  LogReader::session( 'progress' => 100 );
  $application->session_engine->flush( session => $my_session );

  $alert->{type}    = 'success';
  $alert->{message} = 'Log data inserted into the database';

  return $alert;
}

sub update_errorlogs 
{
    my @ids     = shift;
    my $domain  = shift;
    my $error   = 0;
    my $alert;
    my $i       = 0;
      
    my $qry = q/DELETE FROM error_log WHERE domain like ? and request = (SELECT request FROM error_log WHERE domain like ? and id = ?)/;
    my $sth = database('sqlserver')->prepare($qry);
        
    if ( ref($ids[0]) ne 'ARRAY') {
        eval { $sth->execute($domain,$domain,@ids) or die "Unable to update. id: @ids";};

        if($@) { 
            $error = 1;
        }
        $sth->finish;
    }
    else {
        while ($ids[0][$i] > 0 ) 
        {
            eval { $sth->execute($domain,$domain,$ids[0][$i]) or die 'Unable to update. id: '.$ids[0][$i]; };

            if($@) { 
                $error = 1;
            }
            $sth->finish;
            $i += 1;
        } 
    }
    if ($error){
        $alert->{type}    = 'warning';
        $alert->{message} = "Unable to update an entry: $qry";
    }    

    return $alert;
}

sub delete_errorlogs 
{    
    my  $domain = shift // 'domain';
    my  $date   = shift // '01-01-1970';
    my  $eudate = shift // 'the selected date';
    my  $alert;

    my  $qry = 'DELETE FROM error_log where domain like ? and date < ?';
    my  $sth = database('sqlserver')->prepare($qry);
        $sth->execute($domain,$date) or $alert->message="Unable to delete. ";
        $sth->finish;
    
    $alert->{type}    = 'success';
    $alert->{message} = "Log data up to $eudate has been deleted from the database.";

    return $alert;
}


sub logs 
{
    return database('sqlserver')->selectall_arrayref( "SELECT * FROM logs ORDER BY log", { Slice => {} } );
}

sub insert_logs 
{
  my $log = shift // '';
  my $url = shift // '';

  return 0 unless (length($log) != 0 );

  my $qry = q/INSERT INTO logs (log,url) VALUES (?,?);/; 

  my $sth = database('sqlserver')->prepare($qry);
    $sth->execute("$log","$url") or die "Unable to insert.";
    $sth->finish;

  return 1; 
}

sub delete_logs 
{
    my $log = shift // '';

    return 0 unless (length($log) != 0 );

    my $qry = q/DELETE FROM logs WHERE id_logs = ?;/; 

    my $sth = database('sqlserver')->prepare($qry);
    $sth->execute("$log") or die "Unable to delete.";
    $sth->finish;

    return 1; 
}



sub status_codes 
{
    return database('sqlserver')->selectall_arrayref( "SELECT * from status_codes order by code", { Slice => {} } );
}

sub insert_status_codes 
{
    my ($code, $title, $explanation, $rfc) = @_ ;

    $title       =~ s/"/\"/g;
    $explanation =~ s/"/\"/g;
    $explanation =~ s/'/\'/g;

    if ( defined get_id_status_codes($code) ) 
    {
        # update
        my $sth = database('sqlserver')->prepare(q/UPDATE status_codes SET title = ?, explanation = ?, rfc = ? WHERE code = ?/);
           $sth->execute( $title,$explanation, $rfc, $code ) or die "Cannot update status codes with code=$code";
           $sth->finish;
    }
    else 
    {
        if (length $code > 0) {
            # insert
            my $sth = database('sqlserver')->prepare(q/INSERT INTO status_codes (code, title, explanation, rfc) VALUES (?,?,?,?);/);
               $sth->execute( $code, $title,$explanation, $rfc );
               $sth->finish;
        }
    }
    return
}

sub get_id_status_codes 
{
    my $code = shift // 'no code';

    my $sth = database('sqlserver')->prepare(q/SELECT id from status_codes where code = ?/);
       $sth->execute($code);
    my $id = $sth->fetchrow_arrayref;
       $sth->finish;
    return $id;
}

sub delete_status_codes 
{
    my $id = shift // 0;

    return 0 unless ($id > 0 );

    my $sth = database('sqlserver')->prepare(q/DELETE FROM status_codes WHERE id = ?;/);
    $sth->execute($id) or die "Unable to delete.";
    $sth->finish;
    return 1; 
}


1;
