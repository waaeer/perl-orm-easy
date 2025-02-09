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
 
plan tests =>16; 

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
$pgsql -> run_psql('-f', 'sql/foreign_keys.sql');
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

$dbh->do(qq!CREATE TABLE public.test_table (id idtype, a text, b date, c daterange)!);
$dbh->do(q!CREATE FUNCTION public.can_insert_test_table(user_id idtype, id_ text, data jsonb) RETURNS bool LANGUAGE sql AS $$ SELECT true; $$!);

$dbh->do(qq!SELECT orm_interface.save('public','test_table', NULL, 0, '{"id":1, "c": [ "2018-02-01", null ]}', '{}')!);
$dbh->do(qq!SELECT orm_interface.save('public','test_table', NULL, 0, '{"id":2, "c": [ null, "2018-02-01" ]}', '{}')!);
$dbh->do(qq!SELECT orm_interface.save('public','test_table', NULL, 0, '{"id":3, "c": [ null, "2018-02-01" , "(]" ]}', '{}')!);

is($dbh->selectcol_arrayref(qq!SELECT c FROM test_table WHERE id = 1!)->[0], '[2018-02-01,infinity)', 'save_daterange1');
is($dbh->selectcol_arrayref(qq!SELECT c FROM test_table WHERE id = 2!)->[0], '(-infinity,2018-02-01)', 'save_daterange2');
is($dbh->selectcol_arrayref(qq!SELECT c FROM test_table WHERE id = 3!)->[0], '(-infinity,2018-02-02)', 'save_daterange3');


## check abstract foreign keys
$dbh->do(qq!CREATE SCHEMA schema1!);
$dbh->do(qq!CREATE SCHEMA schema2!);
$dbh->do(qq!CREATE TABLE schema1.some_base_class (id idtype PRIMARY KEY, name text ) !);
$dbh->do(qq!CREATE TABLE schema1.first_subclass (  ) INHERITS (schema1.some_base_class)!);
$dbh->do(qq!CREATE TABLE schema1.other_subclass (  ) INHERITS (schema1.some_base_class)!);
$dbh->do(qq!CREATE TABLE schema2.some_referencing_class (id idtype PRIMARY KEY, some_ref idtype)!);
$dbh->do(qq!INSERT INTO orm.abstract_foreign_key VALUES ('schema2', 'some_referencing_class', 'some_ref', 'schema1', 'some_base_class')!);

$dbh->do(qq!INSERT INTO schema1.first_subclass VALUES (1,'XXX'),(2,'YYY'),(3,'ZZZ')!);
$dbh->do(qq!INSERT INTO schema2.some_referencing_class VALUES (4,2)!);

$dbh->do(qq!INSERT INTO schema2.some_referencing_class VALUES (5,5)!);
is(dbh_error(), "schema2.some_referencing_class.some_ref = 5 should reference to schema1.some_base_class.id", 'abstract FK insert');

my $n = $dbh->selectcol_arrayref(qq!SELECT count(*) FROM schema2.some_referencing_class!)->[0];
is($n,1, 'abstract FK n');

$dbh->do(qq!DELETE FROM schema1.first_subclass WHERE id=2!);
is(dbh_error(), "Referenced object deletion: schema1.some_base_class.id = schema2.some_referencing_class.some_ref", 'abstract FK delete');

my $m = $dbh->selectcol_arrayref(qq!SELECT count(*) FROM schema1.first_subclass!)->[0];
is($m,3, 'abstract FK deleted');

## check array foreign keys

$dbh->do(qq!CREATE TABLE schema1.t1 (id idtype)!);
$dbh->do(qq!CREATE TABLE schema2.t2 (id idtype, refs idtype[])!);
$dbh->do(qq!INSERT INTO orm.array_foreign_key VALUES ('schema2', 't2', 'refs', 'schema1', 't1')!);

$dbh->do(qq!INSERT INTO schema1.t1 VALUES (1), (2), (3)!);

$dbh->do(qq!INSERT INTO schema2.t2 VALUES (4, ARRAY[1,2])!);
$dbh->do(qq!INSERT INTO schema2.t2 VALUES (5, ARRAY[5])!);
is(dbh_error(), "schema2.t2.refs = 5 should reference schema1.t1.id", 'array FK insert');
$dbh->do(qq!INSERT INTO schema2.t2 VALUES (6, ARRAY[1,NULL])!);
is(dbh_error(), "schema2.t2.refs =  should reference schema1.t1.id", 'array FK insert 2');
$dbh->do(qq!DELETE FROM schema1.t1 WHERE id = 1!);
is(dbh_error(), "Referenced object deletion: schema1.t1.id in schema2.t2.refs", 'array FK delete');





sub dbh_error { 
	my $err = $dbh->errstr;
	$err =~ s/^ERROR:\s+//;
	$err =~ s/\s+at line \d+\..*$//s;
	$err =~ s/\s*\n.*$//s;
	return $err;
}

sub normalize_json {
	my ($x) = @_;
	my $json = JSON::XS->new->canonical(1);
	$x = $json->decode(Encode::encode_utf8($x)) unless ref($x);
	return $json->encode($x);
}




