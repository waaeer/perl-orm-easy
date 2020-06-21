CREATE OR REPLACE FUNCTION orm_interface.mget(schema text, tablename text, user_id idtype, page int, pagesize int, query jsonb) 
	RETURNS jsonb SECURITY DEFINER LANGUAGE plperl TRANSFORM FOR TYPE jsonb AS 
$perl$
  my ($schema, $tablename, $user_id, $page, $pagesize, $query) = @_;

  my $debug = 0;
  my $table = quote_ident($schema).'.'.quote_ident($tablename);

warn "debug mget ($schema, $tablename, $user_id, $page, $pagesize, $query)\n" if $debug;


  # контроль доступа. В перспективе - более гранулярный
  my $can_see = ORM::Easy::SPI::spi_run_query_bool('select orm.can_view_objects($1,$2)', ['idtype' , 'text' ], [$user_id, $table ]);
  if(!$can_see) { 
		die("ORM: ".ORM::Easy::SPI::to_json({error=> "AccessDenied", user=>$user_id, class=>"$schema.$tablename",  action=>'view', reason=>0}));
  }
  $page ||= 1;

  my $offset = $pagesize ? ($page-1)*$pagesize : undef;
	
  my $q = {wheres=>[], bind=>[], select=>[], outer_select=>['m.*'], joins=>[], left_joins=>[], order=>[], types=>[], with=>[]};

# простые поля
#  ...
  my @order_fields;
  if(my $ord = $query->{_order}) {
	foreach my $ordf (ref($ord) ? @$ord : $ord) { 
		my $dir = '';
		if($ordf =~ /^\-(.*)$/) { 
			$dir = ' DESC'; $ordf = $1;
		}
		push @order_fields, [$ordf,$dir];
	}
  }

  my $get_field_types = sub {
	my ($take_all, $fields) = @_;
	my $field_types = ORM::Easy::SPI::spi_run_query(q!
		SELECT attname, 
			(SELECT ARRAY[
					(select nspname from pg_namespace n where n.oid = tp.typnamespace)::text,  
					typname::text,  typtype::text, typcategory::text, 
					(select nspname from pg_namespace n where n.oid = sc.relnamespace)::text,  
					sc.relname
				] AS t 
			 FROM pg_type tp WHERE oid=a.atttypid
			) 
		FROM pg_attribute a
		LEFT JOIN pg_constraint s ON s.conrelid = a.attrelid AND a.attnum = s.conkey[1] AND s.contype = 'f'
		LEFT JOIN pg_class     sc ON s.confrelid = sc.oid
		WHERE a.attrelid = (SELECT c.oid FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE relname = $2 AND n.nspname = $1) 
		  AND a.attnum>0
		  AND ($4 OR a.attname::text = ANY($3) )
	!, [ 'text', 'text', 'text[]', 'bool'], 
	   [ $schema, $tablename, $fields, $take_all]
	);
	return $field_types->{rows};
  };

  my $field_types = $get_field_types->( 
		($query->{_exclude_fields} ? "true" : "false"),
		[(keys %$query), (map { $_->[0] } @order_fields), ($query->{_fields} ? @{$query->{_fields}} : ()) ]
  );


  my %field_types_by_attr = map { $_->{attname} => $_->{t} } @$field_types;

  my %exclude_fields = $query->{_exclude_fields} ? map { $_=>1} @{$query->{_exclude_fields}} : ();
  if(my $flds = $query->{_fields}) { 
	$q->{select} = [map  { 'm.'.quote_ident($_) }  @$flds];	
  } elsif(%exclude_fields) { 
	$q->{select} = [
		map  { 'm.'.quote_ident($_->{attname}) }  
		grep { !$exclude_fields{$_->{attname}} } 
		@$field_types 
	];
  } else { 
	$q->{select} = ['m.*'];
  }


# smart pre-triggers for all superclasses
  my $superclasses = ORM::Easy::SPI::spi_run_query(q! SELECT * FROM orm.get_inheritance_tree($1, $2) !, ['text', 'text'], [$schema, $tablename]);
  
  foreach my $o ( @{ $superclasses->{rows} }) { 
	my $func = ORM::Easy::SPI::spi_run_query(q! SELECT * FROM pg_proc p JOIN pg_namespace s ON p.pronamespace = s.oid WHERE p.proname = $2 AND s.nspname = $1!,
			[ 'name', 'name'], [ $o->{schema}, "query_$o->{tablename}"] )->{rows};
#		warn "try query $o->{schema} $o->{tablename}\n";
	if(@$func) { 
#		warn "call $o->{schema}.query_$o->{tablename} $q $query\n";
		$q = ORM::Easy::SPI::spi_run_query_expr( 
					quote_ident($o->{schema}).'.'.quote_ident("query_$o->{tablename}").'($1, $2, $3)',
					[ 'idtype', 'jsonb', 'jsonb'],
					[ $user_id, $q, $query ] 
		);
#		warn "done $o->{schema}.query_$o->{tablename} c=\n";

		if(my $ef = $q->{exclude_fields}) {   ## надо убрать из списка select некие поля.
			my %to_exclude = map { ("m.$_"=>1, $_=>1) } map { quote_ident($_) }  @$ef;

			if( scalar grep { $_ eq 'm.*' } @{ $q->{select} } ) {
				$field_types = $get_field_types->('true', []);
			}
			$q->{select} = [
				grep { ! $to_exclude{ $_ } }
				map { 
					( $_ eq 'm.*' ) # заменим это на конкретный список всех полей, чтобы можно было исключить отдельные из них
					? ( map { 'm.'.quote_ident($_->{attname}) } @$field_types )
					: $_
				}
				@{ $q->{select} }
			];
		}

	}
  }

  foreach my $f (keys %$query) { 
	if(my $type = $field_types_by_attr{$f}) {
		my $v = $query->{$f};
		if(ref($v) eq 'ARRAY') { 
			if($type->[3] eq 'D') {  # for date data types
					if($v->[0]) { 
						push @{$q->{wheres}}, sprintf('m.%s >= $%d', quote_ident($f), $#{$q->{bind}}+2 );
						push @{$q->{types}},  $type->[0].'.'.$type->[1];
						push @{$q->{bind}},  $v->[0];
					}
					if($v->[1]) { 
						push @{$q->{wheres}}, sprintf('m.%s <  $%d', quote_ident($f), $#{$q->{bind}}+2 );
						push @{$q->{types}},  $type->[0].'.'.$type->[1];
						push @{$q->{bind}},  $v->[1];
					}
			} elsif($type->[3] eq 'A') { # for array data types
				push @{$q->{wheres}}, sprintf('m.%s && $%d', quote_ident($f), $#{$q->{bind}}+2 );
				push @{$q->{types}},  $type->[0].'.'.$type->[1];
				push @{$q->{bind}},  $v;
			} else {
				push @{$q->{wheres}}, sprintf('m.%s=ANY($%d)', quote_ident($f), $#{$q->{bind}}+2 );
				push @{$q->{types}},  $type->[0].'.'.$type->[1].'[]';
				push @{$q->{bind}},  $v;
			}

		} elsif (ref($v) eq 'HASH') { 
			if(my $vv = $v->{begins}) { 
				push @{$q->{wheres}}, sprintf(q!m.%s ~* ('^' || $%d)!, quote_ident($f), $#{$q->{bind}}+2 );
				push @{$q->{types}}, 'text';
				push @{$q->{bind}},  $vv;
			}
			elsif(my $vv = $v->{contains}) { 
				push @{$q->{wheres}}, sprintf(q!m.%s ~*  $%d!, quote_ident($f), $#{$q->{bind}}+2 );
				push @{$q->{types}}, 'text';
				push @{$q->{bind}},  $vv;
			}
			elsif(my $vv = $v->{any}) {
				push @{$q->{wheres}}, sprintf('m.%s=ANY($%d)', quote_ident($f), $#{$q->{bind}}+2 );
				push @{$q->{types}}, $type->[0].'.'.$type->[1].'[]';
				push @{$q->{bind}},  $vv;
			}
			else { 
				die("Cannot understand query: ".ORM::Easy::SPI::to_json($v));
			}	
		} else { 
			# if type is integer, value is not-a-number and the field is referencing another table, resolve it as a referenced object name
			if($type->[3] eq 'N' && $v && ($ v!~ /^-?\d+/) && $type->[4]) { 
				push @{$q->{wheres}}, sprintf('m.%s=(SELECT id FROM %s.%s WHERE name=$%d)', 
					quote_ident($f), quote_ident($type->[4]),  quote_ident($type->[5]), $#{$q->{bind}}+2 
				);
				push @{$q->{types}}, 'text';
				push @{$q->{bind}},  $v;
			} elsif($type->[3] eq 'A') { 
				if(defined $v) { 
					push @{$q->{wheres}}, sprintf('m.%s && $%d', quote_ident($f), $#{$q->{bind}}+2 );
					push @{$q->{types}},  $type->[0].'.'.$type->[1];
					push @{$q->{bind}},  [$v];
				} else { 
					push @{$q->{wheres}}, sprintf('m.%s IS NULL', quote_ident($f));
				}
			} else {
				push @{$q->{wheres}}, sprintf('m.%s=$%d', quote_ident($f), $#{$q->{bind}}+2 );
				push @{$q->{types}}, $type->[0].'.'.$type->[1];
				push @{$q->{bind}},  $v;
			}
		}
	}
  }
  # order
#warn "order fields are ", Data::Dumper::Dumper(\@order_fields);
  foreach my $ord (@order_fields) { 
	if($field_types_by_attr{$ord->[0]}) { # это конкретный атрибут
		push @{$q->{order} ||= []},  quote_ident($ord->[0]).$ord->[1];
	} else { 
#		warn Data::Dumper::Dumper(\%field_types_by_attr);
		die("Unknown order expression '$ord->[0]'");
	}
  }

  if(my $s=$query->{with_permissions}) { 
	my $bb = $#{$q->{bind}} + 2;
	push @{$q->{outer_select}}, sprintf(q!
		 orm.can_update_object($%d, $%d, m.id::text, NULL) as can_edit,
		 orm.can_delete_object($%d, $%d, m.id::text) as can_delete
	!, $bb, $bb+1, $bb, $bb+1 );
	push @{$q->{types}}, 'idtype', 'text';
    push @{$q->{bind}},  $user_id, ($query->{__subclasses} ? '__class' : "$schema.$tablename");
  }

  if($query->{__subclasses}) { 

	# посмотрим, какие поля есть у подклассов данного класса
	my $subclasses = ORM::Easy::SPI::spi_run_query(q! SELECT 
			schema || '.' || tablename AS classname,
			quote_ident(schema) || '.' || quote_ident(tablename) AS tablename,
			(SELECT json_agg(row_to_json(x))::jsonb FROM (
				SELECT attname, n.nspname, typname 
					FROM pg_attribute a 
					JOIN pg_type t ON a.atttypid = t.oid 
					JOIN pg_namespace n ON n.oid = t.typnamespace
					WHERE attrelid = c.id AND attnum > 0
			) x) AS  fields
		FROM orm.get_terminal_subclasses($1, $2) c 
	!, ['text', 'text'], [$schema, $tablename])->{rows};
	my (%fields, %namespaces, %transforms);
	foreach my $c (@$subclasses) {   ## соберем объединение всех полей, и заодно проверим совпадение типов одинаковых полей
		foreach my $fld (@{$c->{fields}}) { 
			my $attname = $fld->{attname};
			my $existing_type = $fields{$attname};
			my $type = $fld->{typname};
			my $nsp  = $fld->{nspname};
			if($existing_type && ($type ne $existing_type || $nsp ne $namespaces{$attname})) {
				$transforms{$attname} = $existing_type;
			}
			if(!$existing_type) { $fields{$attname} = $type; $namespaces{$attname} = $nsp; }
			($c->{by_field} ||= {})->{$attname} = 1;
		}
	}
	my @fields = sort keys %fields;
	foreach my $c (@$subclasses) {   ## составим строчки выбираемых полей для всех подклассов
		$c->{all_fields} = join(', ',  map { 
			$c->{by_field}->{$_} # если данное поле есть в таблице данного подкласса
			? $_ . ( $transforms{$_} ? '::'.$transforms{$_} : '')
			: 'NULL::'.quote_ident($namespaces{$_}).'.'.quote_ident($fields{$_});
		} @fields);
	}
#warn "subclasses=".Data::Dumper::Dumper($subclasses);
	if(!@$subclasses) { 
		die("Class $table has no subclasses");
	}
	$table = '('. join(' UNION ALL ', map { "SELECT $_->{all_fields},".quote_literal($_->{classname})." AS __class FROM $_->{tablename}" } @$subclasses ). ') ';
  }


  my $where     = @{$q->{wheres}} ? 'WHERE '.join(' AND ', @{$q->{wheres}}) : '';
  my $order     = @{$q->{order}}  ? 'ORDER BY '.join(', ', @{$q->{order}}) : '';
  my $sel       = join(', ', @{$q->{select}});
  my $outer_sel = join(', ', @{$q->{outer_select}});
  my $join      = @{$q->{joins}}      ?  join('  ', map { "JOIN      $_ " } @{$q->{joins}}) : '';
  my $ljoin     = @{$q->{left_joins}} ?  join('  ', map { "LEFT JOIN $_ " } @{$q->{left_joins}}) : '';  
  my $with      = @{$q->{with}}       ?  join(', ', @{$q->{with}}) : '';
  my ($limit,@pagebind,@pagetypes) = ('');
  if($pagesize) { 
	  $limit = sprintf("LIMIT \$%d OFFSET \$%d", $#{$q->{bind}}+2, $#{$q->{bind}}+3);
 	  push @pagebind, $pagesize, $offset;
	  push @pagetypes, 'int', 'int';
  }

  my ($sql,$nsql,@treebind);
  my $uwith = $with ? "WITH $with " : "";
  if(my $p = $query->{__root}) { 
	my $top_where = ($where ? "$where AND " : "WHERE "). sprintf("(m.parent = \$%d)", $#{$q->{bind}} + $#pagebind + 3);
	push @pagebind, $p;
	push @pagetypes,'idtype';
	my $child_where  = ($where ? "$where AND " : "WHERE "). 'm.parent = __tree.id';
	my $rwith = $with  ? " $with," : '';
	$sql = "WITH $rwith RECURSIVE __tree AS (
	                                SELECT $sel FROM $table m $join  $top_where
					UNION ALL
	                                SELECT $sel FROM $table m $join, __tree $child_where 
			)
			SELECT $outer_sel FROM (SELECT $sel FROM __tree m ".($limit ? "$order $limit" : ""). ") m $ljoin $order 
			";
  } else { 
	$sql = "$uwith SELECT $outer_sel FROM (SELECT $sel FROM $table m $join$where ".($limit ? "$order $limit" : ""). ") m $ljoin $order";
  }  
  $nsql = "$uwith SELECT COUNT(*) AS value FROM $table m $join $where";

warn "sql=$sql\n", Data::Dumper::Dumper($q,$query, $sql, $q->{types}, \@pagetypes, $q->{bind}, \@pagebind) if $debug;
  my %ret;
  $ret{list} = ORM::Easy::SPI::spi_run_query($sql, [@{$q->{types}}, @pagetypes ], [@{$q->{bind}}, @pagebind ] )->{rows};

#warn "ret list is ", Data::Dumper::Dumper($ret{list});
  unless ($query->{without_count}) { 
	$ret{n} = ORM::Easy::SPI::spi_run_query_value($nsql, $q->{types}, $q->{bind});
  }

########## Smart postprocess-triggers for all superclasses (including this class)

  foreach my $o ( @{ $superclasses->{rows} }) { 
	my $func = ORM::Easy::SPI::spi_run_query(q! SELECT * FROM pg_proc p JOIN pg_namespace s ON p.pronamespace = s.oid WHERE p.proname = $2 AND s.nspname = $1!,
			[ 'name', 'name'], [ $o->{schema}, "postquery_$o->{tablename}"] )->{rows};
#		warn "try postquery $o->{schema} $o->{tablename}\n";
	if(@$func) { 
#		warn "call $o->{schema}.postquery_$o->{tablename} $q $query\n";
		my $new_list = ORM::Easy::SPI::spi_run_query_expr( 
					quote_ident($o->{schema}).'.'.quote_ident("postquery_$o->{tablename}").'($1, $2, $3)',
					[ 'idtype', 'jsonb', 'jsonb'],
					[ $user_id, $ret{list}, $query ] 
		);
		if($new_list) {
			$ret{list} = $new_list;
		}
#		warn "done $o->{schema}.postquery_$o->{tablename} c=\n";

	}
  }



  return \%ret;
$perl$;




