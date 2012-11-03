#!/usr/bin/env perl
# -*-mode:cperl; indent-tabs-mode: nil-*-

## Test using MariaDB as a database target
## It should be a dropin for MySQL, but we break it out just in case

use 5.008003;
use strict;
use warnings;
use Data::Dumper;
use lib 't','.';
use DBD::Pg;
use Test::More;
use MIME::Base64;

use vars qw/ $bct $dbhX $dbhA $dbhB $dbhC $dbhD $res $command $t %pkey $SQL %sth %sql/;

## Must have the DBD::mysql module
my $evalok = 0;
eval {
    require DBD::mysql;
    $evalok = 1;
};
if (!$evalok) {
    plan (skip_all =>  'Cannot test MariaDB unless the Perl module DBD::mysql is installed');
}

## MariaDB must be up and running
$evalok = 0;
my $dbh;
my $dbuser = 'root';
eval {
    $dbh = DBI->connect('dbi:mysql:database=test', $dbuser, '',
                         {AutoCommit=>1, PrintError=>0, RaiseError=>1});
    $evalok = 1;
};
if (!$evalok) {
    plan (skip_all =>  "Cannot test MariaDB as we cannot connect to a running MariaDB database");
}

## Need to ensure this is really MariaDB, not MySQL
my $ver = $dbh->selectall_arrayref('SELECT version()')->[0][0];
if ($ver !~ /MariaDB/) {
    plan (skip_all =>  "Cannot test MariaDB: MySQL port is being used by MySQL");
}

use BucardoTesting;

## For now, remove the bytea table type as we don't have full support yet
delete $tabletypemariadb{bucardo_test8};

my $numtabletypes = keys %tabletypemariadb;
plan tests => 151;

## Drop the test database if it exists
my $dbname = 'bucardo_test';

eval {
    $dbh->do("DROP DATABASE $dbname");
};
## Create the test database
$dbh->do("CREATE DATABASE $dbname");

## Reconnect to the new database
$dbh = DBI->connect("dbi:mysql:database=$dbname", $dbuser, '',
                    {AutoCommit=>1, PrintError=>0, RaiseError=>1});

## Yes, this must be turned on manually!
$dbh->do("SET sql_mode='ANSI_QUOTES'");

## Create one table for each table type
for my $table (sort keys %tabletypemariadb) {

    my $pkeyname = $table =~ /test5/ ? q{"id space"} : 'id';
    my $pkindex = $table =~ /test2/ ? '' : 'PRIMARY KEY';
    $SQL = qq{
            CREATE TABLE "$table" (
                $pkeyname    $tabletypemariadb{$table} NOT NULL $pkindex};
    $SQL .= $table =~ /X/ ? "\n)" : qq{,
                data1 VARCHAR(100)           NULL,
                inty  SMALLINT               NULL,
                booly BOOLEAN                NULL, -- Alias for TINYINT
                bite1 VARBINARY(999)         NULL,
                bite2 VARBINARY(999)         NULL,
                email VARCHAR(100)           NULL UNIQUE
            )
            };

    $dbh->do($SQL);

    if ($table =~ /test2/) {
        $dbh->do(qq{ALTER TABLE "$table" ADD CONSTRAINT multipk PRIMARY KEY ($pkeyname,data1)});
    }

}

$bct = BucardoTesting->new() or BAIL_OUT "Creation of BucardoTesting object failed\n";
$location = 'mariadb';

pass("*** Beginning MariaDB tests");

END {
    $bct and $bct->stop_bucardo($dbhX);
    $dbhX and  $dbhX->disconnect();
    $dbhA and $dbhA->disconnect();
    $dbhB and $dbhB->disconnect();
    $dbhC and $dbhC->disconnect();
    $dbhD and $dbhD->disconnect();
}

## Get Postgres database A and B and C created
$dbhA = $bct->repopulate_cluster('A');
$dbhB = $bct->repopulate_cluster('B');
$dbhC = $bct->repopulate_cluster('C');

## Create a bucardo database, and install Bucardo into it
$dbhX = $bct->setup_bucardo('A');

## Tell Bucardo about these databases

## Three Postgres databases will be source, source, and target
for my $name (qw/ A B C /) {
    $t = "Adding database from cluster $name works";
    my ($dbuser,$dbport,$dbhost) = $bct->add_db_args($name);
    $command = "bucardo add db $name dbname=bucardo_test user=$dbuser port=$dbport host=$dbhost";
    $res = $bct->ctl($command);
    like ($res, qr/Added database "$name"/, $t);
}

$t = 'Adding mariadb database Q works';
$command =
"bucardo add db Q dbname=$dbname type=mariadb dbuser=$dbuser";
$res = $bct->ctl($command);
like ($res, qr/Added database "Q"/, $t);

## Teach Bucardo about all pushable tables, adding them to a new herd named "therd"
$t = q{Adding all tables on the master works};
$command =
"bucardo add tables all db=A herd=therd pkonly";
$res = $bct->ctl($command);
like ($res, qr/Creating herd: therd.*New tables added: \d/s, $t);

## Add all sequences, and add them to the newly created herd
$t = q{Adding all sequences on the master works};
$command =
"bucardo add sequences all db=A herd=therd";
$res = $bct->ctl($command);
like ($res, qr/New sequences added: \d/, $t);

## Create a new database group
$t = q{Created a new database group};
$command =
"bucardo add dbgroup qx A:source B:source C Q";
$res = $bct->ctl($command);
like ($res, qr/Created database group "qx"/, $t);

## Create a new sync
$t = q{Created a new sync};
$command =
"bucardo add sync mariadb herd=therd dbs=qx autokick=false";
$res = $bct->ctl($command);
like ($res, qr/Added sync "mariadb"/, $t);

## Create a second sync, solely for multi-sync interaction issues
$bct->ctl('bucardo add dbgroup t1 A:source B C');
$bct->ctl('bucardo add sync tsync1 herd=therd dbs=t1 autokick=false status=inactive');

## Start up Bucardo with these new syncs
$bct->restart_bucardo($dbhX);

## Boolean values
my (@boolys) = qw( xxx true false null false true null );

## Get the statement handles ready for each table type
for my $table (sort keys %tabletypemariadb) {

    $pkey{$table} = $table =~ /test5/ ? q{"id space"} : 'id';

    ## INSERT
    for my $x (1..6) {
        $SQL = $table =~ /X/
            ? qq{INSERT INTO "$table"($pkey{$table}) VALUES (?)}
                : qq{INSERT INTO "$table"($pkey{$table},data1,inty,booly) VALUES (?,'foo',$x,$boolys[$x])};
        $sth{insert}{$x}{$table}{A} = $dbhA->prepare($SQL);
        if ('BYTEA' eq $tabletypemariadb{$table}) {
            $sth{insert}{$x}{$table}{A}->bind_param(1, undef, {pg_type => PG_BYTEA});
        }
    }

    ## SELECT
    $sql{select}{$table} = qq{SELECT inty, booly FROM "$table" ORDER BY $pkey{$table}};
    $table =~ /X/ and $sql{select}{$table} =~ s/inty/$pkey{$table}/;

    ## DELETE ALL
    $SQL = qq{DELETE FROM "$table"};
    $sth{deleteall}{$table}{A} = $dbhA->prepare($SQL);

    ## DELETE ONE
    $SQL = qq{DELETE FROM "$table" WHERE inty = ?};
    $sth{deleteone}{$table}{A} = $dbhA->prepare($SQL);

    ## TRUNCATE
    $SQL = qq{TRUNCATE TABLE "$table"};
    $sth{truncate}{$table}{A} = $dbhA->prepare($SQL);
    ## UPDATE
    $SQL = qq{UPDATE "$table" SET inty = ?};
    $sth{update}{$table}{A} = $dbhA->prepare($SQL);
}

## Add one row per table type to A
for my $table (keys %tabletypemariadb) {
    my $type = $tabletypemariadb{$table};
    my $val1 = $val{$type}{1};
    $sth{insert}{1}{$table}{A}->execute($val1);
}

## Before the commit on A, B, C, and Q should be empty
for my $table (sort keys %tabletypemariadb) {
    my $type = $tabletypemariadb{$table};
    $t = qq{B has not received rows for table $table before A commits};
    $res = [];
    bc_deeply($res, $dbhB, $sql{select}{$table}, $t);
    bc_deeply($res, $dbhC, $sql{select}{$table}, $t);
    bc_deeply($res, $dbh, $sql{select}{$table}, $t);
}

## Commit, then kick off the sync
$dbhA->commit();
$bct->ctl('bucardo kick mariadb 0');
$bct->ctl('bucardo kick mariadb 0');

## Check B and C for the new rows
for my $table (sort keys %tabletypemariadb) {

    my $type = $tabletypemariadb{$table};
    $t = qq{Row with pkey of type $type gets copied to B};

    $res = [[1,1]];
    bc_deeply($res, $dbhB, $sql{select}{$table}, $t);
    bc_deeply($res, $dbhC, $sql{select}{$table}, $t);
}

## Check that MariaDB has the new rows
for my $table (sort keys %tabletypemariadb) {
    $t = "MariaDB table $table has correct number of rows after insert";
    $SQL = qq{SELECT * FROM "$table"};
    my $sth = $dbh->prepare($SQL);
    my $count = $sth->execute();
    is ($count, 1, $t);

    $t = "MariaDB table $table has correct entries";
    my $info = $sth->fetchall_arrayref({})->[0];
    my $type = $tabletypemariadb{$table};
    my $id = $val{$type}{1};
    my $pkeyname = $table =~ /test5/ ? 'id space' : 'id';

    ## For now, binary is stored in escaped form, so we skip this one
    next if $table =~ /test8/;

    ## Datetime has no time zone thingy at the end
    $tabletypemariadb{$table} =~ /DATETIME/ and $id =~ s/\+.*//;

    is_deeply(
        $info,
        {
            $pkeyname => $id,
            inty => 1,
            booly => 1,
            email => undef,
            bite1 => undef,
            bite2 => undef,
            data1 => 'foo',
        },

        $t);
}

## Update each row
for my $table (keys %tabletypemariadb) {
    $sth{update}{$table}{A}->execute(42);
}
$dbhA->commit();
$bct->ctl('bucardo kick mariadb 0');

for my $table (keys %tabletypemariadb) {
    $t = "MariaDB table $table has correct number of rows after update";
    $SQL = qq{SELECT * FROM "$table"};
    my $sth = $dbh->prepare($SQL);
    my $count = $sth->execute();
    is ($count, 1, $t);

    $t = "MariaDB table $table has updated value";
    my $info = $sth->fetchall_arrayref({})->[0];
    is ($info->{inty}, 42, $t);
}

## Delete each row
for my $table (keys %tabletypemariadb) {
    $sth{deleteall}{$table}{A}->execute();
}
$dbhA->commit();
$bct->ctl('bucardo kick mariadb 0');

for my $table (keys %tabletypemariadb) {
    $t = "MariaDB table $table has correct number of rows after delete";
    $SQL = qq{SELECT * FROM "$table"};
    my $sth = $dbh->prepare($SQL);
    (my $count = $sth->execute()) =~ s/0E0/0/;
    $sth->finish();
    is ($count, 0, $t);
}

## Insert two rows, then delete one of them
## Add one row per table type to A
for my $table (keys %tabletypemariadb) {
    my $type = $tabletypemariadb{$table};
    my $val1 = $val{$type}{1};
    $sth{insert}{1}{$table}{A}->execute($val1);
    my $val2 = $val{$type}{2};
    $sth{insert}{2}{$table}{A}->execute($val2);
}
$dbhA->commit();
$bct->ctl('bucardo kick mariadb 0');

for my $table (keys %tabletypemariadb) {
    $t = "MariaDB table $table has correct number of rows after double insert";
    $SQL = qq{SELECT * FROM "$table"};
    my $sth = $dbh->prepare($SQL);
    my $count = $sth->execute();
    $sth->finish();
    is ($count, 2, $t);
}

## Delete one of the rows
for my $table (keys %tabletypemariadb) {
    $sth{deleteone}{$table}{A}->execute(2); ## inty = 2
}
$dbhA->commit();
$bct->ctl('bucardo kick mariadb 0');

for my $table (keys %tabletypemariadb) {
    $t = "MariaDB table $table has correct number of rows after single deletion";
    $SQL = qq{SELECT * FROM "$table"};
    my $sth = $dbh->prepare($SQL);
    my $count = $sth->execute();
    $sth->finish();
    is ($count, 1, $t);
}

## Insert two more rows
for my $table (keys %tabletypemariadb) {
    my $type = $tabletypemariadb{$table};
    my $val3 = $val{$type}{3};
    $sth{insert}{3}{$table}{A}->execute($val3);
    my $val4 = $val{$type}{4};
    $sth{insert}{4}{$table}{A}->execute($val4);
}
$dbhA->commit();
$bct->ctl('bucardo kick mariadb 0');

for my $table (keys %tabletypemariadb) {
    $t = "MariaDB table $table has correct number of rows after more inserts";
    $SQL = qq{SELECT * FROM "$table"};
    my $sth = $dbh->prepare($SQL);
    my $count = $sth->execute();
    is ($count, 3, $t);

    $t = "MariaDB table $table has updated values";
    my $info = $sth->fetchall_arrayref({});
    $info = [ sort { $a->{inty} <=> $b->{inty} } @$info ];
    my ($val1, $val3, $val4) = @{$val{$tabletypemariadb{$table}}}{1, 3, 4};

    my $pkeyname = $table =~ /test5/ ? 'id space' : 'id';
    my(@invar) = ( data1 => 'foo', 'email' => undef, bite1 => undef, bite2 => undef );
    is_deeply ($info, [{ $pkeyname=>$val1, inty=>1, booly=>1,     @invar },
                       { $pkeyname=>$val3, inty=>3, booly=>undef, @invar },
                       { $pkeyname=>$val4, inty=>4, booly=>0,     @invar }], $t) || diag explain $info;

    $sth->finish();

}


exit;
