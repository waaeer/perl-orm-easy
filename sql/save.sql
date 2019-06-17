CREATE OR REPLACE FUNCTION orm_interface.save (schema text, tablename text, id text, user_id bigint, data jsonb, context jsonb)  
 		RETURNS json_pair LANGUAGE PLPERL SECURITY DEFINER TRANSFORM FOR TYPE jsonb  AS $perl$
    my ($schema, $tablename, $id, $user_id, $jsondata, $context) = @_;
# todo: засунуть user_id в сессионный контекст, чтобы подхватить его из триггеров - и то же в orm_interface.remove для триггера delete_history 
	warn "Called save($schema, $tablename, $id, $user_id, $jsondata, $context)\n";

    my $op = (defined $id && ($id=~/^\-?\d+$/)) ? 'update' : 'insert';

	my %ids;
	$id = ORM::Easy::SPI::make_new_id($id, $context, \%ids);

    my $data = $jsondata; 
    my $field_types = ORM::Easy::SPI::spi_run_query(q!
		SELECT attname, 
			(SELECT ARRAY[(select nspname from pg_namespace n where n.oid = typnamespace)::text,  typname::text,  typtype::text] AS t 
			 FROM pg_type WHERE oid=atttypid
			) 
		FROM pg_attribute 
		WHERE attrelid = (SELECT c.oid FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE relname = $2 AND n.nspname = $1) AND attnum>0
	!, ['text', 'text'], [$schema, $tablename]);

    my %field_types_by_attr = map { $_->{attname} => $_->{t} } @{ $field_types->{rows} };

    $data->{changed_by} = $user_id if $field_types_by_attr{changed_by};
	delete $data->{id};

# smart pre-triggers for all superclasses
	my $superclasses = ORM::Easy::SPI::spi_run_query(q! SELECT * FROM orm.get_inheritance_tree($1, $2) !, ['text', 'text'], [$schema, $tablename]);
	my $old_data;

	foreach my $o ( @{ $superclasses->{rows} }) { 
		my $func = ORM::Easy::SPI::spi_run_query(q! SELECT * FROM pg_proc p JOIN pg_namespace s ON p.pronamespace = s.oid WHERE p.proname = $2 AND s.nspname = $1!,
			[ 'name', 'name'], [ $o->{schema}, "presave_$o->{tablename}"] )->{rows};
		warn "try pre $o->{schema} $o->{tablename}\n";
		if(@$func) { 
			$old_data ||= ### ORM::Easy::SPI::to_json(
				$op eq 'update' 
				? ORM::Easy::SPI::spi_run_query_row('SELECT * FROM '.quote_ident($schema).'.'.quote_ident($tablename).' WHERE id = $1', ['bigint' ], [$id])
				: {}
			#)
			;

#			warn "call $o->{schema}.presave_$o->{tablename}\n";
			my $changes = ORM::Easy::SPI::spi_run_query_expr(quote_ident($o->{schema}).'.'.quote_ident("presave_$o->{tablename}").'($1, $2, $3, $4, $5, $6, $7)',
				[ 'bigint', 'bigint', 'text', 'jsonb','jsonb' , 'text', 'text', ],
				[ $user_id, $id, $op, $old_data, $jsondata, $schema, $tablename ] 
			);
#			warn "done $o->{schema}.presave_$o->{tablename}\n";
warn "changes are ".Data::Dumper::Dumper($changes);
			if($changes) { 
				my $add_data = $changes; # ORM::Easy::SPI::from_json($changes);
				$data = Hash::Merge->new('RIGHT_PRECEDENT')->merge($data, $add_data);
			}
		}
	}
# form and run SQL
#  warn "CRM save ", Data::Dumper::Dumper($data);

	if($op ne 'update') { 
		$data->{id} = $id;
#		warn "id=$id\n";
	}
    my @fields = sort keys %$data;
	my (%exprs, @types, @args);
	my $n = 0;

	foreach my $f (@fields) { 
		my $t = $field_types_by_attr{$f} || die("No such field $f");
		my $val = $data->{$f};
		my ($tschema, $type, $typtype) = @$t;
		$n++;
		$exprs{$f} = "\$$n";
		if($type eq 'bytea') { 
			if($val =~ /([^01234567890abcdefABCDEF])/) { # value comes as HEX
				die sprintf("Bad symbol \\x%x in $f value ($val)", $1);
			}
			push @types, $type;
			push @args,  defined($val) ? "\\x$val" : undef;

		} elsif ($type eq 'int4' || $type eq 'int8') {  
			push @types, $type;
			push @args, !defined($val) || $val eq '' ? undef : ($data->{$f}=ORM::Easy::SPI::make_new_id($val, $context, \%ids));

		} elsif($type eq 'bool') { 
            $exprs{$f} = defined $val ? ( $val ? 'true' : 'false' )  : 'NULL';
			$n--;  # does not push args
		} elsif($type eq 'numeric') { 
			push @types, $type;
				# todo: check numeric look
			push @args,  defined $val && $val ne '' ? $val : undef;

		} elsif ($type =~ /^jsonb?/) { 
			push @types, $type;
			push @args,  defined($val) ? $val # ORM::Easy::SPI::to_json($val) 
			                           : undef;

		} elsif (($type eq '_int4' || $type eq '_int8') && ref($val) eq 'HASH') {
			my ($expr_add, $expr_del, $vtype_add, $vtype_del);
			if(my $v = $val->{add}) {
				push @types, $type;
				push @args,  [ map { !defined($_) || $_ eq '' ? undef : ORM::Easy::SPI::make_new_id($_, $context, \%ids) } (ref($v) eq 'ARRAY' ? @$v : ($v))];
				$expr_add  =  "+\$${n}::_int4";
			} 
			elsif(my $v = $val->{delete}) {  
				my $vtype = ref($v) eq 'ARRAY' ? $type : substr($type,1); # remove leading underscore from type name
				push @types, $type;
				push @args,  [ map { !defined($_) || $_ eq '' ? undef : ORM::Easy::SPI::make_new_id($_, $context, \%ids) } (ref($v) eq 'ARRAY' ? @$v : ($v))];
				$expr_del  =  "-\$${n}::$type"; 
			} 
			$exprs{$f} = 'coalesce('.quote_ident($f).",'{}'::int[]) " .$expr_add . $expr_del;
		} elsif ($type =~ /^timestamp/) {
			if ($val eq 'now') {
				$exprs{$f} = 'now()';
				$n--;
			} else { 
				push @types, "$tschema.$type";  
				push @args,  $val;
			}
		} elsif ($type eq 'daterange' && ref($val) eq 'ARRAY') { 
			my @bounds = map { $_ ? ( /^(\d\d\d\d)-(\d\d)-(\d\d)$/ ? $_ : die("Bad format of date in date range: $_") ) : undef   } @$val[0,1];
			push @types, $type;
			push @args, sprintf('[%s,%s]', @bounds);
		} elsif ($type eq 'tstzrange' && ref($val) eq 'ARRAY') { 
			my @bounds = map { $_ ? ( /^(\d\d\d\d)-(\d\d)-(\d\d).*$/ ? $_ : die("Bad format of date in date range: $_") ) : undef   } @$val[0,1];
			push @types, $type;
			push @args, sprintf('[%s,%s]', @bounds);
		} elsif ($typtype eq 'e' && $val eq '') {
			$exprs{$f} = 'NULL';
			$n--; # does not push args			
		} else { 
			push @types, "$tschema.$type";  
			push @args,  $val;
		}
	}

    ## права на каждую таблицу определяются отдельной функцией (user_id,id,data)

    ## toDo надо обработать ситуацию отсутствия этой функции
	warn "try $schema.can_${op}_$tablename\n";

    if( ORM::Easy::SPI::spi_run_query_bool(q!SELECT EXISTS(SELECT * FROM pg_proc p JOIN pg_namespace s ON p.pronamespace = s.oid WHERE p.proname = $2 AND s.nspname = $1)!,
			[ 'name', 'name'], [ $schema, "can_${op}_$tablename"])) {
		ORM::Easy::SPI::spi_run_query_bool('select '.quote_ident($schema).'.'.quote_ident("can_${op}_$tablename").'($1,$2,$3)', ['bigint', 'text', 'jsonb'], [$user_id, $id, $data])
		or die("ORM: ".ORM::Easy::SPI::to_json({error=> "AccessDenied", user=>$user_id, class=>"$schema.$tablename", id=>$id, action=>$op}));
	}


    my $sql;
    if($op eq 'update') {
        $sql = 'update '.quote_ident($schema).'.'.quote_ident($tablename).' set '.join(', ', map { 
            quote_ident($_)."=$exprs{$_}"
		} @fields).' where id = '.quote_literal($id).'::bigint returning *';
    } else {  #insert
        $sql = 'insert into '.quote_ident($schema).'.'.quote_ident($tablename).' ('.join(', ', map { quote_ident($_) } @fields).') values ('.
			join(',', map { $exprs{$_} } @fields). ') returning *';
    } 

    my $obj = ORM::Easy::SPI::spi_run_query_row($sql, \@types, \@args);
    foreach my $k (keys %$obj) { if (ref($obj->{$k}) eq 'PostgreSQL::InServer::ARRAY') {  $obj->{$k} = $obj->{$k}->{array}; } }

## RUN postsaves
	$id = $obj->{id};

	foreach my $o ( @{ $superclasses->{rows} }) { 
		my $func = ORM::Easy::SPI::spi_run_query(q! SELECT * FROM pg_proc p JOIN pg_namespace s ON p.pronamespace = s.oid WHERE p.proname = $2 AND s.nspname = $1!,
			[ 'name', 'name'], [ $o->{schema}, "postsave_$o->{tablename}"] )->{rows};
#		warn "try post $o->{schema} $o->{tablename}\n";
		if(@$func) { 
#			warn "call $o->{schema}.postsave_$o->{tablename}\n";
			ORM::Easy::SPI::spi_run_query('select '.quote_ident($o->{schema}).'.'.quote_ident("postsave_$o->{tablename}").'($1, $2, $3, $4, $5, $6, $7)',
				[ 'bigint', 'bigint', 'text', 'jsonb','jsonb', 'text', 'text' ],
				[ $user_id, $id, $op, $old_data, $jsondata, $schema, $tablename ] 
			);
#			warn "done $o->{schema}.postsave_$o->{tablename}\n";
		}
	}



    return {a=> $obj, b=>{_ids=>\%ids}};

$perl$;




