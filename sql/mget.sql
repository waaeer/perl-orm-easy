CREATE OR REPLACE FUNCTION orm_interface.mget(schema text, tablename text, user_id idtype, page int, pagesize int, query jsonb) 
	RETURNS jsonb SECURITY DEFINER LANGUAGE plperl TRANSFORM FOR TYPE jsonb AS 
$perl$
  my ($schema, $tablename, $user_id, $page, $pagesize, $query) = @_;
  my $table = quote_ident($schema).'.'.quote_ident($tablename);

  # контроль доступа. В перспективе - более гранулярный
  my $can_see = ORM::Easy::SPI::spi_run_query_bool('select orm.can_view_objects($1,$2)', ['idtype' , 'text' ], [$user_id, $table ]);
  if(!$can_see) { 
		die("ORM: ".ORM::Easy::SPI::to_json({error=> "AccessDenied", user=>$user_id, class=>"$schema.$tablename",  action=>'view'}));
  }
  $page ||= 1;

  my $offset = $pagesize ? ($page-1)*$pagesize : undef;
	
  my $q = {wheres=>[], bind=>[], select=>[], outer_select=>['m.*'], joins=>[], left_joins=>[], order=>[], types=>[]};

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


#warn "DuDa=", Data::Dumper::Dumper(\@order_fields, [(keys %$query), map { $_->[0] } @order_fields]);
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
	   [ $schema, $tablename, 
			[(keys %$query), (map { $_->[0] } @order_fields), ($query->{_fields} ? @{$query->{_fields}} : ()) ],
			($query->{_exclude_fields} ? "true" : "false") 
		]);

  my %field_types_by_attr = map { $_->{attname} => $_->{t} } @{ $field_types->{rows} };

  my %exclude_fields = $query->{_exclude_fields} ? map { $_=>1} @{$query->{_exclude_fields}} : ();
  if(my $flds = $query->{_fields}) { 
	$q->{select} = [map  { 'm.'.quote_ident($_) }  @$flds];	
  } elsif(%exclude_fields) { 
	$q->{select} = [
		map  { 'm.'.quote_ident($_->{attname}) }  
		grep { !$exclude_fields{$_->{attname}} } 
		@{ $field_types->{rows} } 
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

	}
  }





  foreach my $f (keys %$query) { 
	if(my $type = $field_types_by_attr{$f}) {
		my $v = $query->{$f};
		if(ref($v) eq 'ARRAY') { 
			if($type->[3] eq 'A') { # for array data types
				push @{$q->{wheres}}, sprintf('m.%s && $%d', quote_ident($f), $#{$q->{bind}}+2 );
				push @{$q->{types}},  $type->[0].'.'.$type->[1];
			} else {
				push @{$q->{wheres}}, sprintf('m.%s=ANY($%d)', quote_ident($f), $#{$q->{bind}}+2 );
				push @{$q->{types}},  $type->[0].'.'.$type->[1].'[]';
			}
			push @{$q->{bind}},  $v;
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
		warn Data::Dumper::Dumper(\%field_types_by_attr);
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
    push @{$q->{bind}},  $user_id, "$schema.$tablename";
  }


  my $where     = @{$q->{wheres}} ? 'WHERE '.join(' AND ', @{$q->{wheres}}) : '';
  my $order     = @{$q->{order}}  ? 'ORDER BY '.join(', ', @{$q->{order}}) : '';
  my $sel       = join(', ', @{$q->{select}});
  my $outer_sel = join(', ', @{$q->{outer_select}});
  my $join      = @{$q->{joins}}      ?  join('  ', map { "JOIN      $_ " } @{$q->{joins}}) : '';
  my $ljoin     = @{$q->{left_joins}} ?  join('  ', map { "LEFT JOIN $_ " } @{$q->{left_joins}}) : '';  
  my ($limit,@pagebind,@pagetypes) = ('');
  if($pagesize) { 
	  $limit = sprintf("LIMIT \$%d OFFSET \$%d", $#{$q->{bind}}+2, $#{$q->{bind}}+3);
 	  push @pagebind, $pagesize, $offset;
	  push @pagetypes, 'int', 'int';
  }

  my $sql  = "SELECT $outer_sel FROM (SELECT $sel FROM $table m $join $ljoin $where $order $limit) m";
  my $nsql = "SELECT COUNT(*) AS value FROM $table m $join $where";

#warn "sql=$sql\n", Data::Dumper::Dumper($q,$query, $sql, \@pagetypes,\@pagebind);
  my %ret;
  $ret{list} = ORM::Easy::SPI::spi_run_query($sql, [@{$q->{types}}, @pagetypes ], [@{$q->{bind}}, @pagebind ] )->{rows};
  unless ($query->{without_count}) { 
	$ret{n} = ORM::Easy::SPI::spi_run_query_value($nsql, $q->{types}, $q->{bind});
  }
  return \%ret;
$perl$;




