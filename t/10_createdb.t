use strict;
use DBI;
use Test::PostgreSQL;
use Test::More;
use JSON::XS;
use Encode;
use Cwd;

my $dir = getcwd() . "/blib/lib";
my $pgsql = eval { Test::PostgreSQL->new( pg_config => qq|
 plperl.use_strict = on
 plperl.on_init    = 'use lib "$dir"; use ORM::Easy::SPI;'
 lc_messages       = 'C'
       |) }
        or plan skip_all => $@;
 
plan tests =>6; 

my $dbh = DBI->connect($pgsql->dsn);
ok(1);
$pgsql -> run_psql('-f', 'sql/00_idtype_int4.sql');
ok(1);
$pgsql -> run_psql('-f', 'sql/00_plperl.sql');
$pgsql -> run_psql('-f', 'sql/schema.sql');
$pgsql -> run_psql('-f', 'sql/id_seq.sql');
$pgsql -> run_psql('-f', 'sql/tables.sql');
$pgsql -> run_psql('-f', 'sql/rbac_tables.sql');
$pgsql -> run_psql('-f', 'sql/rbac_data.sql');
$pgsql -> run_psql('-f', 'sql/functions.sql');
$pgsql -> run_psql('-f', 'sql/rbac_functions.sql');
$pgsql -> run_psql('-f', 'sql/can_object.sql');
$pgsql -> run_psql('-f', 'sql/api_functions.sql');
$pgsql -> run_psql('-f', 'sql/store_file.sql');
$pgsql -> run_psql('-f', 'sql/presave__traceable.sql');
$pgsql -> run_psql('-f', 'sql/query__traceable.sql');
ok(1);

$dbh->do(q!CREATE TABLE public.object(id idtype, name text, x int) INHERITS (orm._traceable)!);
$dbh->do(q!INSERT INTO orm.metadata(name, public_readable) VALUES ('public.object', true)!);
$dbh->do(q!CREATE FUNCTION public.can_insert_object(user_id idtype, id_ text, data jsonb) RETURNS bool LANGUAGE plpgsql AS $$
	BEGIN
		RETURN true;
	END;
$$!);
$dbh->do(q!CREATE FUNCTION public.can_update_object(user_id idtype, id_ text, data jsonb) RETURNS bool LANGUAGE plpgsql AS $$
	BEGIN
		RETURN true;
	END;
$$!);
ok(1);
foreach my $i (1..100) {
	$dbh->do(qq!SELECT orm_interface.save('public','object', NULL, 0, '{"id":$i, "name": "x$i", "x": $i}', '{}')!);
}

is(normalize_json( $dbh->selectcol_arrayref(qq!SELECT orm_interface.mget('public', 'object', 0, 1, 1, '{"x":7,"_fields":["id","name","x","created_by"]}')!)->[0]),
   normalize_json( {n=> "1", list => [ { id=>"7", x=>"7", name => 'x7', created_by => "0" }]}),
   'x7'
);

$dbh->do(qq!SELECT orm_interface.msave('public','object', 0, 1, 2, '{"_order":"id"}', '{"name":"xyz"}', '{}')!);

is(normalize_json( $dbh->selectcol_arrayref(qq!SELECT orm_interface.mget('public', 'object', 0, 1, 4, '{"_order":"id","_fields":["id","name"]}')!)->[0]),
   normalize_json( {n=> "100", list => [ { id=>"1",name => 'xyz'}, { id=>"2",name => 'xyz'}, { id=>"3",name => 'x3'}, { id=>"4",name => 'x4'}]}),
   'msaved'
);



sub normalize_json {
	my ($x) = @_;
	my $json = JSON::XS->new->canonical(1);
	$x = $json->decode(Encode::encode_utf8($x)) unless ref($x);
	return $json->encode($x);
}




