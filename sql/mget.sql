CREATE OR REPLACE FUNCTION orm_interface.mget(schema text, tablename text, user_id bigint, page int, pagesize int, query jsonb) 
	RETURNS jsonb SECURITY DEFINER LANGUAGE plperl TRANSFORM FOR TYPE jsonb AS 
$perl$
  my ($schema, $tablename, $user_id, $page, $pagesize, $query) = @_;
  my $table = quote_ident($schema).'.'.quote_ident($tablename);


  # контроль доступа. В перспективе - более гранулярный
  my $can_see = ORM::Easy::SPI::spi_run_query_bool('select orm.can_view_objects($1,$2)', ['int' , 'text' ], [$user_id, $table ]);
  if(!$can_see) { 
		die("ORM: ".ORM::Easy::SPI::to_json({error=> "AccessDenied", user=>$user_id, class=>"$schema.$tablename",  action=>'view'}));
  }
  $page ||= 1;

  my $offset = ($page-1)*$pagesize;
	
  my $q = {wheres=>[], bind=>[], select=>['m.*'], joins=>[], order=>[], types=>[]};


# простые поля
#  ...



# smart pre-triggers for all superclasses
  my $superclasses = ORM::Easy::SPI::spi_run_query(q! SELECT * FROM orm.get_inheritance_tree($1, $2) !, ['text', 'text'], [$schema, $tablename]);
  
  foreach my $o ( @{ $superclasses->{rows} }) { 
	my $func = ORM::Easy::SPI::spi_run_query(q! SELECT * FROM pg_proc p JOIN pg_namespace s ON p.pronamespace = s.oid WHERE p.proname = $2 AND s.nspname = $1!,
			[ 'name', 'name'], [ $o->{schema}, "query_$o->{tablename}"] )->{rows};
		warn "try query $o->{schema} $o->{tablename}\n";
	if(@$func) { 
		warn "call $o->{schema}.query_$o->{tablename} $q $query\n";
		$q = ORM::Easy::SPI::spi_run_query_expr( 
					quote_ident($o->{schema}).'.'.quote_ident("query_$o->{tablename}").'($1, $2, $3)',
					[ 'int8', 'jsonb', 'jsonb'],
					[ $user_id, $q, $query ] 
		);
		warn "done $o->{schema}.query_$o->{tablename} c=\n";

	}
  }
  
#warn "q,sel=", Data::Dumper::Dumper($q);
  if(my $id = $query->{id}) { 
	push @{$q->{wheres}}, sprintf('m.id=$%d', $#{$q->{bind}}+2 );
	push @{$q->{types}}, 'int8';
	push @{$q->{bind}},  $id;
  }

  my $where = @{$q->{wheres}} ? 'WHERE '.join(' AND ', @{$q->{wheres}}) : '';
  my $order = @{$q->{order}}  ? 'ORDER BY '.join(', ', @{$q->{order}}) : '';
  my $sel   = join(', ', @{$q->{select}});
  my $join  = @{$q->{joins}} ? ' JOIN '. join('  ', @{$q->{joins}}) : '';
  
  my $sql  = sprintf("SELECT $sel FROM $table m $join $where $order LIMIT \$%d OFFSET \$%d", $#{$q->{bind}}+2, $#{$q->{bind}}+3);
  my $nsql = "SELECT COUNT(*) AS value FROM $table m $join $where";

warn "sql=$sql\n";
  my %ret;
  $ret{list} = ORM::Easy::SPI::spi_run_query($sql, [@{$q->{types}}, 'int','int'], [@{$q->{bind}}, $pagesize, $offset] )->{rows};
  unless ($query->{without_count}) { 
	$ret{total} = ORM::Easy::SPI::spi_run_query_value($nsql, $q->{types}, $q->{bind});
  }
  return \%ret;
$perl$;




