package LogReader::Database;

use strict;
use warnings;

use Dancer2;
use Dancer2::Plugin::Database;

use Data::Dumper;
use Exporter qw{import};

our @EXPORT = qw{
    domains 
    insert_domains
    delete_domains
    bots
    get_id_bots
    insert_bots
    delete_bots
    logs
    numrows_logs
    insert_logs
    update_logs
    delete_logs
};

our $VERSION = '0.1';

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

INSERT INTO domains (domain) VALUES ('odyssey.co.in');
INSERT INTO domains (domain) VALUES ('abc.co.in');

drop table bots;
CREATE TABLE bots (
 id integer PRIMARY KEY,
 ua text,
 ip text,
 referer text,
 date integer NOT NULL,
 spam integer);

Sort access by Response Codes
cat access.log | cut -d '"' -f3 | cut -d ' ' -f2 | sort | uniq -c | sort -rn

Broken links
awk '($9 ~ /404/)' access.log | awk '{print $7}' | sort | uniq -c | sort -rn

Most requested URLs
awk -F\" '{print $2}' access.log | awk '{print $2}' | sort | uniq -c | sort -r

Most requested URLs containing XYZ
awk -F\" '($2 ~ "ref"){print $2}' access.log | awk '{print $2}' | sort | uniq -c | sort -r


=cut
sub bots 
{
    return database('sqlserver')->selectall_arrayref( "SELECT * from bots order by id", { Slice => {} } );
}

sub get_id_bots 
{
    my $ip = shift // 'no ip';

    my $sth = database('sqlserver')->prepare(q/SELECT id from bots where ip like ?/);
       $sth->execute($ip);
    my $id = $sth->fetchrow_arrayref;
       $sth->finish;
    return $id;
}

sub insert_bots 
{
    my ($ua, $ip, $referer, $spam) = @_ ;

    if ( defined get_id_bots($ip) ) 
    {
        # update
        my $sth = database('sqlserver')->prepare(q/UPDATE bots SET date = ?, spam = ? /);
           $sth->execute( time(), $spam ) or die "Cannot update bots with ip=$ip";
           $sth->finish;
    }
    else 
    {
        if (length $ip > 0) {
            # insert
            my $sth = database('sqlserver')->prepare(q/INSERT INTO bots (ua,ip,referer,date,spam) VALUES (?,?,?,?,?);/);
               $sth->execute( $ua,$ip,$referer,time(),$spam );
               $sth->finish;
        }
    }
    return
}

sub delete_bots 
{
  my $id = shift // 0;

  return 0 unless ($id > 0 );

  my $sth = database('sqlserver')->prepare(q/delete from bots where id = ?;/);
     $sth->execute($id) 
        or die "Unable to delete.";
    $sth->finish;
  return 1; 
}

sub domains 
{
    return database('sqlserver')->selectall_arrayref( "SELECT * from domains order by domain", { Slice => {} } );
}

sub insert_domains 
{
  my $domain = shift // '';

  return 0 unless (length($domain) != 0 );

  my $qry = qq(INSERT INTO domains (domain) VALUES (?);); 

  my $sth = database('sqlserver')->prepare($qry);
    $sth->execute("$domain") 
      or die "Unable to insert.";
    $sth->finish;

  return 1; 
}

sub delete_domains 
{
  my $domain = shift // '';

  return 0 unless (length($domain) != 0 );

  my $qry = qq(delete from domains where domain like ?;); 

  my $sth = database('sqlserver')->prepare($qry);
    $sth->execute("$domain") 
      or die "Unable to delete.";
    $sth->finish;

    return 1; 
}


sub logs 
{
  my $domain      = shift // 'domain';
  my $filterurl   = shift // 'all';
  my $pageno      = shift // 1; 
  
  my $option      = '';
  my @array       = ();

  return @array unless ($domain ne 'domain');

  if    ($filterurl eq 'images')  { $option = " and request     like '%images%' GROUP BY request ";} 
  elsif   ($filterurl eq 'others')  { $option = " and request not like '%images%' GROUP BY request ";} 
  elsif   ($filterurl eq 'status')  { $option = " GROUP BY status, request "; } 
  
    my $qry  = "SELECT strftime('%d-%m-%Y',date(date,'unixepoch')) as eudate, * 
          FROM error_log WHERE domain like '$domain' and fix=0 $option 
          ORDER BY date DESC 
          LIMIT " .($pageno - 1) * $LogReader::ROWS_PER_PAGE .','. $LogReader::ROWS_PER_PAGE;

    return database('sqlserver')->selectall_arrayref( $qry, { Slice => {} } );
}

sub numrows_logs 
{
  my $domain      = shift // 'domain';
  my $filterurl   = shift // 'all';

  return 0 unless ($domain ne 'domain');

  my  $qry  = "SELECT count(*) as numrows, 
              strftime('%d-%m-%Y',date(min(date),'unixepoch')) as firstdate, 
              strftime('%d-%m-%Y',date(max(date),'unixepoch')) as lastdate 
              FROM  error_log where domain = ? and fix=0 ";

  if      ($filterurl eq 'images')  { $qry .= " and request like '%images%' GROUP BY request like '%images%'"; } 
  elsif   ($filterurl eq 'others')  { $qry .= " and request not like '%images%' GROUP BY request not like '%images%'";  } 
  elsif   ($filterurl eq 'status')  { $qry .= " GROUP BY status ";  }

  my $sth = database('sqlserver')->prepare($qry);
     $sth->execute($domain);
  my $row = $sth->fetchrow_hashref('NAME_lc');
     $sth->finish;

  return $row;
}

sub insert_logs 
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

  # start the work
  while (my $line = <FH>) 
  {
      $counter += 1; 
      
      # start splittng the line into fields
      my @vars  = split / /, $line, 6;
      my @vars2 = split /,/, $vars[5];

      # determine the date of this entry
      my $thisdate = LogReader::get_epoch( $vars[0], $vars[1] ); 
      # not all logs have a date
      $thisdate = time() unless $thisdate;
      # only enter new data
      next if ($thisdate < $lastdate);

      # update the progress session to monitor the progress
      if (($counter%100) == 0) 
      {
        LogReader::session( 'progress' => (int($counter / $progress_total * 100)) ) ;
        $application->session_engine->flush( session => $my_session );
      }

      my $date      = LogReader::get_epoch( $vars[0], $vars[1] );

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
        
        my $qry = qq(INSERT INTO error_log (date,status,client,server,request,method,host,error,fix,domain) 
                    VALUES      (?,?,?,?,?,?,?,?,0,?);); 

        my $sth = database('sqlserver')->prepare($qry);
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

sub update_logs 
{
  my $domain  = shift // 0;
  my @ids     = shift;

  my $error   = 0;
  my $alert;
  my $i       = 0;
  
  my $qry = q/UPDATE error_log SET fix = 1 WHERE domain = ? and request = (SELECT request FROM error_log WHERE domain = ? and id = ?)/;
  my $sth = database('sqlserver')->prepare($qry);
    
  if ( ref($ids[0]) ne 'ARRAY')
  {
    eval 
    {
      $sth->execute($domain,$domain,@ids) 
        or die "Unable to update. id: @ids";
    };

    if($@) 
    { 
      $error = 1;
    }

    $sth->finish;
    }
    else 
    {
    while ($ids[0][$i] > 0 ) 
    {
      my $key = $ids[0][$i];
      
      eval 
      {
        $sth->execute($domain,$domain,$key) 
          or die "Unable to update. id: $key";
      };

      if($@) 
      { 
        $error = 1;
      }

      $sth->finish;

      $i += 1;
    } 
  }

    if ($error) 
    {
      $alert->{type}    = 'warning';
      $alert->{message} = "Unable to update an entry ";
    }    

    return $alert;
}

sub delete_logs 
{    
    my  $domain = shift // 'domain';
    my  $date   = shift // '01-01-1970';
    my  $alert;

    my  $qry = 'DELETE FROM error_log where domain like ? and date < ?';
    my  $sth = database('sqlserver')->prepare($qry);
        $sth->execute($domain,$date) or $alert->message="Unable to delete. ";
        $sth->finish;
    
    $alert->{type}    = 'success';
    $alert->{message} = "Log data up to $date has been deleted from the database.";

    return $alert;
}


1;
