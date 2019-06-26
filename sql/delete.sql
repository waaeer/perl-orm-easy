CREATE OR REPLACE FUNCTION orm_interface.delete (schema text, tablename text, id text, user_id bigint, context jsonb)  RETURNS jsonb LANGUAGE PLPERL SECURITY DEFINER AS $perl$

    my ($schema, $tablename, $id, $user_id, $context) = @_;
# todo: засунуть user_id в сессионный контекст, чтобы подхватить его из триггеров - и то же в orm_interface.remove для триггера delete_history 
#	warn "Called delete($schema, $tablename, $id, $user_id, $context)\n";

  	$context &&= ORM::Easy::SPI::from_json($context);
	
    ## права на каждую таблицу определяются отдельной функцией (user_id,id,data)

    ## toDo надо обработать ситуацию отсутствия этой функции

#	warn "try $schema.can_delete_$tablename\n";
    if( ORM::Easy::SPI::spi_run_query_bool(q!SELECT EXISTS(SELECT * FROM pg_proc p JOIN pg_namespace s ON p.pronamespace = s.oid WHERE p.proname = $2 AND s.nspname = $1)!,
			[ 'name', 'name'], [ $schema, "can_delete_$tablename"])) {
		ORM::Easy::SPI::spi_run_query_bool('select '.quote_ident($schema).'.'.quote_ident("can_delete_$tablename").'($1,$2,$3)', ['bigint', 'text'], [$user_id, $id])
		or die("ORM: ".ORM::Easy::SPI::to_json({error=> "AccessDenied", user=>$user_id, class=>"$schema.$tablename", id=>$id, action=>'delete'}));
    }


# smart pre-triggers for all superclasses
	my $superclasses = ORM::Easy::SPI::spi_run_query(q! SELECT * FROM orm.get_inheritance_tree($1, $2) !, ['text', 'text'], [$schema, $tablename]);
	my $old_data;

	foreach my $o ( @{ $superclasses->{rows} }) { 
		my $func = ORM::Easy::SPI::spi_run_query(q! SELECT * FROM pg_proc p JOIN pg_namespace s ON p.pronamespace = s.oid WHERE p.proname = $2 AND s.nspname = $1!,
			[ 'name', 'name'], [ $o->{schema}, "predelete_$o->{tablename}"] )->{rows};
#		warn "try pre $o->{schema} $o->{tablename}\n";
		if(@$func) { 
			$old_data ||= ORM::Easy::SPI::to_json(
				ORM::Easy::SPI::spi_run_query('SELECT * FROM '.quote_ident($schema).'.'.quote_ident($tablename).' WHERE id = $1', ['bigint' ], [$id])->{rows}->[0]
			);

#			warn "call $o->{schema}.predelete_$o->{tablename}\n";
			my $changes = ORM::Easy::SPI::spi_run_query('select '.quote_ident($o->{schema}).'.'.quote_ident("predelete_$o->{tablename}").'($1, $2, $3) AS x',
				[ 'bigint', 'bigint', 'json' ],
				[ $user_id, $id, $old_data] 
			)->{rows}->[0]->{x};
#			warn "done $o->{schema}.predelete_$o->{tablename}\n";

		}
	}
# form and run SQL
#  warn "CRM delete ", Data::Dumper::Dumper($data);

    my $sql = 'delete from '.quote_ident($schema).'.'.quote_ident($tablename).'  where id = $1';


    my $ret = ORM::Easy::SPI::spi_run_query($sql, ['bigint'],[$id]);
   
## RUN postdeletes

	foreach my $o ( @{ $superclasses->{rows} }) { 
		my $func = ORM::Easy::SPI::spi_run_query(q! SELECT * FROM pg_proc p JOIN pg_namespace s ON p.pronamespace = s.oid WHERE p.proname = $2 AND s.nspname = $1!,
			[ 'name', 'name'], [ $o->{schema}, "postdelete_$o->{tablename}"] )->{rows};
#		warn "try post $o->{schema} $o->{tablename}\n";
		if(@$func) { 
#			warn "call $o->{schema}.postdelete_$o->{tablename}\n";
			ORM::Easy::SPI::spi_run_query('select '.quote_ident($o->{schema}).'.'.quote_ident("postdelete_$o->{tablename}").'($1, $2, $3) AS x',
				[ 'bigint', 'bigint',  'jsonb', ],
				[ $user_id, $id, $old_data] 
			);
#			warn "done $o->{schema}.postdelete_$o->{tablename}\n";
		}
	}



    return ORM::Easy::SPI::to_json({ok=>1});

$perl$;


