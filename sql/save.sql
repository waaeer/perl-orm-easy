CREATE OR REPLACE FUNCTION orm_interface.save (schema text, tablename text, id text, user_id idtype, data jsonb, context jsonb)  
 		RETURNS json_pair LANGUAGE PLPERL SECURITY DEFINER TRANSFORM FOR TYPE jsonb  AS $perl$
    my ($schema, $tablename, $id, $user_id, $jsondata, $context) = @_;
	my $debug = 0;
# todo: засунуть user_id в сессионный контекст, чтобы подхватить его из триггеров - и то же в orm_interface.remove для триггера delete_history 
#	warn "Called save($schema, $tablename, $id, $user_id, $jsondata, $context)\n";

    my $op = (defined $id && ($id=~/^\-?\d+$/)) ? 'update' : 'insert';

	my $id_in_data = delete $jsondata->{id}; # так можно явно задать id для нового объекта
	my %ids;
	$id = ORM::Easy::SPI::make_new_id(($op eq 'insert' ? ($id_in_data || $id) : $id), $context, \%ids);
    my $data = $jsondata; 

## права на каждую таблицу определяются отдельной функцией (user_id,id,data)
## проверка прав делается перед presave, т.к. в presave уже могут быть сделаны изменения в БД, влияющие на права доступа

warn "try $schema.can_${op}_$tablename\n" if $debug;   # если функция есть, вызываем её; если нет - игнорируем (правильно ли это?)
#   toDo: scan superclasses  

    if( ORM::Easy::SPI::spi_run_query_bool(q!SELECT EXISTS(SELECT * FROM pg_proc p JOIN pg_namespace s ON p.pronamespace = s.oid WHERE p.proname = $2 AND s.nspname = $1)!,
			[ 'name', 'name'], [ $schema, "can_${op}_$tablename"])) {
		ORM::Easy::SPI::spi_run_query_bool('select '.quote_ident($schema).'.'.quote_ident("can_${op}_$tablename").'($1,$2,$3)', ['idtype', 'text', 'jsonb'], [$user_id, $id, $data])
		or die("ORM: ".ORM::Easy::SPI::to_json({error=> "AccessDenied", user=>$user_id, class=>"$schema.$tablename", id=>$id, action=>$op, reason=>1}));
	} else { 
		ORM::Easy::SPI::spi_run_query_bool('select orm.can_update_object($1,$2,$3,$4)', ['idtype', 'text','text','jsonb'], [$user_id, quote_ident($schema).'.'.quote_ident($tablename), $id, $data])
		or die("ORM: ".ORM::Easy::SPI::to_json({error=> "AccessDenied", user=>$user_id, class=>"$schema.$tablename", id=>$id, action=>$op, reason=>2}));
	}

    my $field_types = ORM::Easy::SPI::spi_run_query(q!
		SELECT attname, 
			(SELECT ARRAY[(select nspname from pg_namespace n where n.oid = t.typnamespace)::text,  
				t.typname::text,  t.typtype::text, t.typcategory::text,
				et.typname::text, et.typcategory::text
			 ] AS t 
			 FROM pg_type t 
			 LEFT JOIN pg_type et ON t.typelem = et.oid
			 WHERE t.oid=a.atttypid
			) 
		FROM pg_attribute a 
		WHERE attrelid = (SELECT c.oid FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE relname = $2 AND n.nspname = $1) AND attnum>0
	!, ['text', 'text'], [$schema, $tablename]);

    my %field_types_by_attr = map { $_->{attname} => $_->{t} } @{ $field_types->{rows} };

    $data->{changed_by} = $user_id if $field_types_by_attr{changed_by};

# smart pre-triggers for all superclasses
	my $superclasses = ORM::Easy::SPI::spi_run_query(q! SELECT * FROM orm.get_inheritance_tree($1, $2) !, ['text', 'text'], [$schema, $tablename]);
	my $old_data;

	foreach my $o ( @{ $superclasses->{rows} }) { 
		my $func = ORM::Easy::SPI::spi_run_query(q! SELECT * FROM pg_proc p JOIN pg_namespace s ON p.pronamespace = s.oid WHERE p.proname = $2 AND s.nspname = $1!,
			[ 'name', 'name'], [ $o->{schema}, "presave_$o->{tablename}"] )->{rows};
#		warn "try pre $o->{schema} $o->{tablename}\n";
		if(@$func) { 
			$old_data ||= 
				$op eq 'update' 
				? ORM::Easy::SPI::spi_run_query_row('SELECT * FROM '.quote_ident($schema).'.'.quote_ident($tablename).' WHERE id = $1', ['idtype' ], [$id])
				: {}
			;

			warn "call $o->{schema}.presave_$o->{tablename}\n" if $debug;
			my $changes = ORM::Easy::SPI::spi_run_query_expr(quote_ident($o->{schema}).'.'.quote_ident("presave_$o->{tablename}").'($1, $2, $3, $4, $5, $6, $7)',
				[ 'idtype', 'idtype', 'text', 'jsonb','jsonb' , 'text', 'text', ],
				[ $user_id, $id, $op, $old_data, $jsondata, $schema, $tablename ] 
			);
#			warn "done $o->{schema}.presave_$o->{tablename}\n";
			if($changes) { 
				my $add_data = $changes; 
				$data = Hash::Merge->new('RIGHT_PRECEDENT')->merge($data, $add_data);
warn "Data=".Data::Dumper::Dumper($changes, $data);
			}
		}
	}
# form and run SQL
  warn "ORM save ", Data::Dumper::Dumper($data) if $debug;

	if($op ne 'update') { 
		$data->{id} = $id;
#		warn "id=$id\n";
	}
    my @fields = sort keys %$data;
	my (%exprs, @types, @args, @fields_ok);
	my $n = 0;

	foreach my $f (@fields) { 
		my $val = $data->{$f};
		my $t   = $field_types_by_attr{$f};
#warn "Process $f $val\n";
		if(!$t) {
			if(!defined($val)) { 
				# в несуществующее поле разрешаем писать только NULL. Это нужно, чтобы в presave обрабатывать дополнительные "виртуальные" поля и птом их занулять
				delete $data->{$f};
				next;
			}
			die("No such field $f; fields are ".join(',', sort keys %field_types_by_attr));
		}
		push @fields_ok, $f;
		my ($tschema, $type, $typtype, $typcat, $eltype, $eltypecat) = @$t;
		$n++;
		$exprs{$f} = "\$$n";
		if($type eq 'bytea') { 
			if($val =~ /([^01234567890abcdefABCDEF])/) { # value comes as HEX
				die sprintf("Bad symbol \\x%x in $f value ($val)", $1);
			}
			push @types, $type;
			push @args,  defined($val) ? "\\x$val" : undef;

		} elsif ($typcat eq 'N') {  
			push @types, $type;
			push @args, !defined($val) || $val eq '' ? undef : ($data->{$f}=ORM::Easy::SPI::make_new_id($val, $context, \%ids));

		} elsif($type eq 'bool') { 
            $exprs{$f} = defined $val ? ( $val ? 'true' : 'false' )  : 'NULL';
			$n--;  # does not push args
		} elsif ($type =~ /^jsonb?/) { 
			push @types, $type;
			push @args,  defined($val) ? $val # ORM::Easy::SPI::to_json($val) 
			                           : undef;
		} elsif (($typcat eq 'A' && $eltypecat eq 'N') && ref($val) eq 'HASH') {  # для числовых массивов
			my ($expr_add, $expr_del, $vtype_add, $vtype_del);
			if(my $v = $val->{add}) {
				push @types, "$tschema.$type";
				push @args,  [ map { !defined($_) || $_ eq '' ? undef : ORM::Easy::SPI::make_new_id($_, $context, \%ids) } (ref($v) eq 'ARRAY' ? @$v : ($v))];
				$expr_add  =  "+\$${n}::$type";
			} 
			elsif(my $v = $val->{delete}) {  
				my $vtype = ref($v) eq 'ARRAY' ? $type : substr($type,1); # remove leading underscore from type name
				push @types, $type;
				push @args,  [ map { !defined($_) || $_ eq '' ? undef : ORM::Easy::SPI::make_new_id($_, $context, \%ids) } (ref($v) eq 'ARRAY' ? @$v : ($v))];
				$expr_del  =  "-\$${n}::$type"; 
			} 
			$exprs{$f} = 'coalesce('.quote_ident($f).",'{}'::int[]) " .$expr_add . $expr_del;
		} elsif (($typcat eq 'A' && $eltypecat eq 'N') && ref($val) eq 'ARRAY') {  # для числовых массивов
			push @types, $type;
			push @args, [ map { !defined($_) || $_ eq '' ? undef : ORM::Easy::SPI::make_new_id($_, $context, \%ids) } @$val];			
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
		} elsif (($type =~ /^(tstz|date)range$/) && ref($val) eq 'HASH') { 
			my ($lower,$upper, $lok, $uok);
			if (exists $val->{upper}) { $upper = $val->{upper}; $uok = 1; } 
			if (exists $val->{lower}) { $lower = $val->{lower}; $lok = 1; } 
			if ($upper && ($upper !~ /^(\d\d\d\d)-(\d\d)-(\d\d).*$/)) { die("Bad format of upper bound for range $f"); }
			if ($lower && ($lower !~ /^(\d\d\d\d)-(\d\d)-(\d\d).*$/)) { die("Bad format of lower bound for range $f"); }
			my $qf = quote_ident($f);
			if($lok || $uok) { 
				if ($op eq 'update') { 
					my $interval = ($lok ? "'$lower'": "coalesce(lower($qf)::text,'')") . "|| ',' ||" . ($uok ? "'$upper'" : "coalesce(upper($qf)::text,'')");
					$exprs{$f} = qq!(case when lower_inc($qf) then '[' else '(' end || $interval || case when upper_inc($qf) then ']' else ')' end )::daterange  !;
				} else {
					my $interval = ($lok ? "'$lower'": "") . "|| ',' ||" . ($uok ? "$upper" : "");
					$exprs{$f} = qq!'[' || $interval || ']::daterange'!;
				}
			}
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

    
    my $sql;
    if($op eq 'update') {
        $sql = 'update '.quote_ident($schema).'.'.quote_ident($tablename).' set '.join(', ', map { 
            quote_ident($_)."=$exprs{$_}"
		} @fields_ok).' where id = '.quote_literal($id).'::idtype returning *';
    } else {  #insert
        $sql = 'insert into '.quote_ident($schema).'.'.quote_ident($tablename).' ('.join(', ', map { quote_ident($_) } @fields_ok).') values ('.
			join(',', map { $exprs{$_} } @fields_ok). ') returning *';
    } 

	warn "SQL=$sql\n" if $debug;
    my $obj = ORM::Easy::SPI::spi_run_query_row($sql, \@types, \@args);
	warn "save done main SQL\n" if $debug;
    foreach my $k (keys %$obj) { if (ref($obj->{$k}) eq 'PostgreSQL::InServer::ARRAY') {  $obj->{$k} = $obj->{$k}->{array}; } }

## RUN postsaves
	$id = $obj->{id};

	foreach my $o ( @{ $superclasses->{rows} }) { 
		my $func = ORM::Easy::SPI::spi_run_query(q! SELECT * FROM pg_proc p JOIN pg_namespace s ON p.pronamespace = s.oid WHERE p.proname = $2 AND s.nspname = $1!,
			[ 'name', 'name'], [ $o->{schema}, "postsave_$o->{tablename}"] )->{rows};
		warn "try post $o->{schema} $o->{tablename}\n" if $debug;
		if(@$func) { 
			warn "call $o->{schema}.postsave_$o->{tablename}\n" if $debug;
			ORM::Easy::SPI::spi_run_query('select '.quote_ident($o->{schema}).'.'.quote_ident("postsave_$o->{tablename}").'($1, $2, $3, $4, $5, $6, $7)',
				[ 'idtype', 'idtype', 'text', 'jsonb','jsonb', 'text', 'text' ],
				[ $user_id, $id, $op, $old_data, $jsondata, $schema, $tablename ] 
			);
			warn "done $o->{schema}.postsave_$o->{tablename}\n" if $debug;
		}
	}

	warn "Exiting save\n" if $debug;


    return {a=> $obj, b=>{_ids=>\%ids}};

$perl$;




