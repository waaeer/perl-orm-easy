package ORM::Easy::SPI;
use strict;
use Encode;
use JSON::XS;
use Data::Dumper;
use Time::HiRes;
use Hash::Merge;
use Clone;
use List::Util;
use Carp;
use locale;


require "utf8_heavy.pl";
my $log_mode = 0;
our %tmp_cache;

sub uniq_array {
	my %x;
	return ( grep { my $ok = !$x{$_}; $x{$_} = 1; $ok } @_ ) ;	
}

sub from_json {
	return JSON::XS::decode_json(Encode::encode_utf8($_[0]));
}
sub to_json {
	return Encode::decode_utf8( JSON::XS::encode_json($_[0]));
}
sub unbless_arrays_in_rows {
	my $rows = shift;
	foreach my $r (@$rows) {
		foreach my $k ( keys %$r) {
			if (UNIVERSAL::isa($r->{$k} , 'PostgreSQL::InServer::ARRAY')) {
				$r->{$k} = $r->{$k}->{array};
			}
			
		}
	}
}
sub parse_bool {
	my $v = shift;
	return defined($v) ? ($v eq 't' || $v eq 'true' ? 1 : 0 ) : undef;
}

sub parse_daterange {
	my $range = shift;
	$range =~ s/^\(|\)$//gs;
	return [ map { $_ || undef } split(/,/, $range) ];
}

sub parse_timerange {
	my $range = shift;
	$range =~ /^(\[|\()(?:"([^"]+)")?,(?:"([^"]+)")?(\]|\))/;
	return [$1,$2,$3,$4];
}

sub array2daterange {
	my $val = shift;
	if($val) { 
		my @bounds = map { $_ ? ( /^(\d\d\d\d)-(\d\d)-(\d\d)$/ ? $_ : die("Bad format of date in date range: $_") ) : undef   } @$val[0,1];
		return sprintf('[%s,%s]', @bounds);
	} else {
		return undef;
	}
}	

sub make_new_id {
	my ($id, $context, $ids) = @_;
	if (defined $id && ( $id =~ /^\-?\d+$/)) {
		return sprintf("%ld", $id);
	} elsif (!defined $id || $id eq '') {
		return ::spi_exec_query("select nextval('orm.id_seq') AS i")->{rows}->[0]->{i};
	} else {
		if(ref($id) eq 'HASH' && $id->{__key__}) { $id = $id->{__key__} };
		my $new_id = $context->{_ids}->{$id} ||= $ids->{$id} = ::spi_exec_query("select nextval('orm.id_seq') AS i")->{rows}->[0]->{i};
#		warn "map $id => $new_id\n";
		return $new_id;
	}
}

sub spi_run_query {  # toDo: cache
	my ($sql, $types, $values) = @_;
	if($log_mode) { warn "spi_run_query($sql,$types,$values)\n", Data::Dumper::Dumper($types,$values); }
	my ($ret, $h);
	eval {
		$h   = ::spi_prepare($sql, @$types);
		$ret = ::spi_exec_prepared($h, {},  @$values);
	};
	if($@) {
		::spi_freeplan($h) if $h;
		confess "$@ in spi_run_query($sql, $types, $values)\n", Data::Dumper::Dumper($types,$values);
	}
	## todo: check and log errors
	if($ret) {
		unbless_arrays_in_rows( $ret->{rows} );
	}
	::spi_freeplan($h) if $h;
	return $ret;
}

sub spi_run_query_json_list {
	my ($sql, $types, $values) = @_;
	if($log_mode) { warn "spi_run_query_json_list($sql)\n"; }
	return ORM::Easy::SPI::from_json(
			ORM::Easy::SPI::spi_run_query(
				q!select coalesce(json_agg(row_to_json(x)),'[]'::json) AS x FROM (!.
				$sql.
				q! ) x!, $types, $values )->{rows}->[0]->{x}
	);
}
sub spi_run_query_bool {
	my ($sql, $types, $values) = @_;
	if($log_mode) { warn "spi_run_query_bool($sql)\n"; }
 	return ORM::Easy::SPI::parse_bool(
			ORM::Easy::SPI::spi_run_query($sql .' AS x', $types, $values)->{rows}->[0]->{x}
	);
}
sub spi_run_query_row {
	my ($sql, $types, $values) = @_;
	if($log_mode) { warn "spi_run_query_row($sql)\n"; }
	return ORM::Easy::SPI::spi_run_query($sql, $types, $values )->{rows}->[0];
}
sub spi_run_query_value {
	my ($sql, $types, $values) = @_;
	if($log_mode) { warn "spi_run_query_value($sql)\n"; }
	return ORM::Easy::SPI::spi_run_query($sql, $types, $values )->{rows}->[0]->{value};
}
sub spi_run_query_expr {
	my ($sql, $types, $values) = @_;
	if($log_mode) { warn "spi_run_query_function($sql)\n"; }
	return ORM::Easy::SPI::spi_run_query('SELECT '.$sql .' AS x', $types, $values )->{rows}->[0]->{x};
}
sub set_log_mode {
	my $v = @_;
	$log_mode = $v;
}
sub filter_intarray {
	my ($q, $table_alias, $fld, $v, $type) = @_;
	if(defined $v) {
		$type ||= 'int8';
		if(!ref($v)) {
			push @{$q->{wheres}}, sprintf('%s.%s @>ARRAY[$%d]', $table_alias,  $fld, $#{$q->{bind}}+2);
			push @{$q->{types}}, $type;
	        push @{$q->{bind}},  $v;
		} elsif (ref($v) eq 'ARRAY') {
			push @{$q->{wheres}}, sprintf('%s.%s @> $%d', $table_alias,  $fld, $#{$q->{bind}}+2);
			push @{$q->{types}}, $type.'[]';
			push @{$q->{bind}}, $v;
		}
    }
}
sub filter_bool {
	my ($q, $table_alias, $fld, $v, $type) = @_;
	if(defined $v) {
		push @{$q->{wheres}}, sprintf('%s %s.%s',($v?'' : 'NOT'), $table_alias,  $fld);
	}
}

sub list2tree {
  my ($list, $convert, %opt) = @_;
  my $level = 0;
  my %nodeById;
  my @top;
  my $pos = 0;
  my %nodeById =
		map { my $node =  $convert ? $convert->($_) : $_ ; $node->{__pos} = $pos++; $node->{id} = $_->{id}; $_->{id} => $node }
		@$list;
  foreach my $node (
	sort { $a->{__pos} <=> $b->{__pos} }
	values %nodeById
  ) {
		if($node->{parent} && $node->{parent} ne $opt{root}) { 	
			if(my $parent_item = $nodeById{ $node->{parent} }) {
				push @{ $parent_item->{children} ||= []}, $node;
				$node->{level} = $parent_item->{level}+1;
			} else {
				die("Bad tree structure: no parent for $node->{id}");
			}
		} else { # top level
			push @top, $node;
			$node->{level} = 0;
		}
  }	

  return \@top;
}

sub list2plaintree {
  my ($list, $convert,%opt) = @_;
  my $tree = list2tree($list,$convert, %opt);
  my @plain;
  my $sub;
  $sub = sub {
	my $nodes = shift;
	my $level = shift;
	foreach my $node (@$nodes) {
		$node->{level} = $level;
		my $subnodes = $node->{children};
		push @plain, $node;
		if($subnodes) {
			$sub->($subnodes, $level+1);
		}		
	}
  };
  $sub->($tree, 0);
  return \@plain;
}

############################################## MGET ###################################
sub _mget {
  my ($schema, $tablename, $user_id, $page, $pagesize, $query) = @_;
  my $table = ::quote_ident($schema).'.'.::quote_ident($tablename);

  %ORM::Easy::SPI::tmp_cache = ();

  # контроль доступа. В перспективе - более гранулярный
  my $can_see = ORM::Easy::SPI::spi_run_query_bool('select orm.can_view_objects($1,$2)', ['idtype' , 'text' ], [$user_id, $table ]);
  if(!$can_see) {
		die("ORM: ".ORM::Easy::SPI::to_json({error=> "AccessDenied", user=>$user_id, class=>"$schema.$tablename",  action=>'view', reason=>0}));
  }
  $page ||= 1;

  my $offset = $pagesize ? ($page-1)*$pagesize : undef;
	
  my $q = {wheres=>[], bind=>[], select=>[], outer_select=>['m.*'], joins=>[], left_joins=>[], internal_left_joins=>[], order=>[], ext_order=>[], types=>[], with=>[], group=>[], aggr=>[]};

# простые поля
#  ...
  my @order_fields;
  if(my $ord = $query->{_order}) {
	foreach my $ordf (ref($ord) ? @$ord : $ord) {
		my $dir = '';
		if($ordf =~ /^\-(-?)(.*)$/) {
			$dir = ' DESC'; $ordf = $2; $dir .= ' NULLS LAST' if $1;
		}
		if($ordf =~ /^(\w+)\.(\w+)$/) {
			push @order_fields, [::quote_ident($1).'.'.::quote_ident($2), $dir];
		} else {
			push @order_fields, [$ordf,$dir];
		}
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
	$q->{select} = [map  { 'm.'.::quote_ident($_) }  @$flds];	
  } elsif(%exclude_fields) {
	$q->{select} = [
		map  { 'm.'.::quote_ident($_->{attname}) }
		grep { !$exclude_fields{$_->{attname}} }
		@$field_types
	];
  } else {
	$q->{select} = ['m.*'];
  }

  my $aggr = sub {
	my $n = shift;
	return 'count(*)' if $n eq 'count';
	return undef;
  };
  if(my $g = $query->{_group}) {
	$q->{group} = [ map { 'm.'.::quote_ident($_) } (ref($g) ? @$g : ($g)) ];
	if(my $ag = $query->{_aggr}) {
		$q->{aggr} = [ map { $aggr->($_) || die("Unknown aggreagate $_") } (ref($ag) ? @$ag : ($ag)) ];
	}
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
					::quote_ident($o->{schema}).'.'.::quote_ident("query_$o->{tablename}").'($1, $2, $3)',
					[ 'idtype', 'jsonb', 'jsonb'],
					[ $user_id, $q, $query ]
		);
#		warn "done $o->{schema}.query_$o->{tablename} c=\n";

		if(my $ef = $q->{exclude_fields}) {   ## надо убрать из списка select некие поля.
			my %to_exclude = map { ("m.$_"=>1, $_=>1) } map { ::quote_ident($_) }  @$ef;

			if( scalar grep { $_ eq 'm.*' } @{ $q->{select} } ) {
				$field_types = $get_field_types->('true', []);
			}
			$q->{select} = [
				grep { ! $to_exclude{ $_ } }
				map {
					( $_ eq 'm.*' ) # заменим это на конкретный список всех полей, чтобы можно было исключить отдельные из них
					? ( map { 'm.'.::quote_ident($_->{attname}) } @$field_types )
					: $_
				}
				@{ $q->{select} }
			];
		}
		if($q->{modify_query}) {
			foreach my $k (keys %{$q->{modify_query}}) {
				my $v = $q->{modify_query}->{$k};
				if($k eq '__delete') { if(ref($v)) { foreach my $vv (@$v) { delete $query->{$vv}; }} else { delete $query->{$v}; } }
				else 				 { $query->{$k} = $v; } 
			}
		}

	}
  }

  foreach my $f (keys %$query) {
	if(my $type = $field_types_by_attr{$f}) {
		my $v = $query->{$f};
		if(ref($v) eq 'ARRAY') {
			if($type->[3] eq 'D') {  # for date data types
					if($v->[0]) {
						push @{$q->{wheres}}, sprintf('m.%s >= $%d', ::quote_ident($f), $#{$q->{bind}}+2 );
						push @{$q->{types}},  $type->[0].'.'.$type->[1];
						push @{$q->{bind}},  $v->[0];
					}
					if($v->[1]) {
						push @{$q->{wheres}}, sprintf('m.%s <  $%d', ::quote_ident($f), $#{$q->{bind}}+2 );
						push @{$q->{types}},  $type->[0].'.'.$type->[1];
						push @{$q->{bind}},  $v->[1];
					}
			} elsif($type->[3] eq 'A') { # for array data types
				push @{$q->{wheres}}, sprintf('m.%s && $%d', ::quote_ident($f), $#{$q->{bind}}+2 );
				push @{$q->{types}},  $type->[0].'.'.$type->[1];
				push @{$q->{bind}},  $v;
			} else {
				push @{$q->{wheres}}, sprintf('m.%s=ANY($%d)', ::quote_ident($f), $#{$q->{bind}}+2 );
				push @{$q->{types}},  $type->[0].'.'.$type->[1].'[]';
				push @{$q->{bind}},  $v;
			}

		} elsif (ref($v) eq 'HASH') {
			if(my $vv = $v->{begins}) {
				push @{$q->{wheres}}, sprintf(q!m.%s ~* ('^' || $%d)!, ::quote_ident($f), $#{$q->{bind}}+2 );
				push @{$q->{types}}, 'text';
				push @{$q->{bind}},  $vv;
			}
			elsif(my $vv = $v->{contains}) {
				push @{$q->{wheres}}, sprintf(q!m.%s ~*  $%d!, ::quote_ident($f), $#{$q->{bind}}+2 );
				push @{$q->{types}}, 'text';
				push @{$q->{bind}},  $vv;
			}
			elsif(my $vv = $v->{any}) {
				push @{$q->{wheres}}, sprintf('m.%s=ANY($%d)', ::quote_ident($f), $#{$q->{bind}}+2 );
				push @{$q->{types}}, $type->[0].'.'.$type->[1].'[]';
				push @{$q->{bind}},  $vv;
			}
			elsif(my $vv = $v->{contains_or_null}) {
				if($type->[3] eq 'A') { # for array data types
					my $qn = ::quote_ident($f);
					push @{$q->{wheres}}, sprintf('(m.%s && $%d OR m.%s IS NULL)', $qn, $#{$q->{bind}}+2, $qn );
					push @{$q->{types}},  $type->[0].'.'.$type->[1];
					push @{$q->{bind}},  $v;
				}
			}
			elsif(my $vv = $v->{not}) {
				if($type->[3] eq 'A') { # for array data types
					my $qn = ::quote_ident($f);
					push @{$q->{wheres}}, sprintf('(NOT (m.%s && $%d) OR m.%s IS NULL)', $qn, $#{$q->{bind}}+2, $qn );
					push @{$q->{types}},  $type->[0].'.'.$type->[1];
					push @{$q->{bind}},  $v;
				}	else {
					push @{$q->{wheres}}, sprintf('NOT m.%s=ANY($%d)', ::quote_ident($f), $#{$q->{bind}}+2 );
					push @{$q->{types}}, $type->[0].'.'.$type->[1].'[]';
					push @{$q->{bind}},  $vv;
				}
			} elsif($v->{not_null}) {
				push @{$q->{wheres}}, sprintf('m.%s IS NOT NULL', ::quote_ident($f) );
			} else {
				die("Cannot understand query: ".ORM::Easy::SPI::to_json($v));
			}	
		} else {
			# if type is integer, value is not-a-number and the field is referencing another table, resolve it as a referenced object name
			if($type->[3] eq 'N' && $v && ($ v!~ /^-?\d+/) && $type->[4]) {
				push @{$q->{wheres}}, sprintf('m.%s=(SELECT id FROM %s.%s WHERE name=$%d)',
					::quote_ident($f), ::quote_ident($type->[4]),  ::quote_ident($type->[5]), $#{$q->{bind}}+2
				);
				push @{$q->{types}}, 'text';
				push @{$q->{bind}},  $v;
			} elsif($type->[3] eq 'A') {
				if(defined $v) {
					push @{$q->{wheres}}, sprintf('m.%s && $%d', ::quote_ident($f), $#{$q->{bind}}+2 );
					push @{$q->{types}},  $type->[0].'.'.$type->[1];
					push @{$q->{bind}},  [$v];
				} else {
					push @{$q->{wheres}}, sprintf('m.%s IS NULL', ::quote_ident($f));
				}
			} elsif ($type->[3] eq 'B') { 
				if(defined $v) { 
					push @{$q->{wheres}}, ($v ? '' : 'NOT '). 'm.'. ::quote_ident($f); 
				} else { 
					push @{$q->{wheres}}, sprintf('m.%s IS NULL', ::quote_ident($f));
				}
					
			} else {
				if(defined $v) { 
					push @{$q->{wheres}}, sprintf('m.%s=$%d', ::quote_ident($f), $#{$q->{bind}}+2 );
					push @{$q->{types}}, $type->[0].'.'.$type->[1];
					push @{$q->{bind}},  $v;
				} else {
					push @{$q->{wheres}}, sprintf('m.%s IS NULL', ::quote_ident($f));
				}
			}
		}
	}
  }
  # order
# warn "order fields are ", Data::Dumper::Dumper(\@order_fields);
  foreach my $ord (@order_fields) {
	if($field_types_by_attr{$ord->[0]}) { # это конкретный атрибут
		push @{$q->{order} ||= []},  ::quote_ident($ord->[0]).$ord->[1];
	} else {
#		warn Data::Dumper::Dumper(\%field_types_by_attr);
		die("Unknown order expression '$ord->[0]'");
	}
  }
  if($query->{with_can_update}) {
	my $bb = $#{$q->{bind}} + 2;
	push @{$q->{outer_select}}, sprintf(q!$%d.can_update_$%d($%d, m.id::text, '{}'::jsonb) AS can_edit!, $bb,$bb+1,$bb+2); #.
	push @{$q->{types}}, 'text','text', 'idtype';
	push @{$q->{bind}}, ::quote_ident($schema), ::quote_ident($tablename), $user_id;
  }

  if(my $s=$query->{with_permissions}) {
	my $bb = $#{$q->{bind}} + 2;
	push @{$q->{outer_select}}, sprintf(q!
		 orm.can_update_object($%d, $%d, m.id::text, NULL) as can_edit,
		 orm.can_delete_object($%d, $%d, m.id::text) as can_delete
	!, $bb, $bb+1, $bb, $bb+1 );  #.
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
			: 'NULL::'.::quote_ident($namespaces{$_}).'.'.::quote_ident($fields{$_}).' AS '.::quote_ident($_);
		} @fields);
	}
#warn "subclasses=".Data::Dumper::Dumper($subclasses);
	if(!@$subclasses) {
		die("Class $table has no subclasses");
	}
	$table = '('. join(' UNION ALL ', map { "SELECT $_->{all_fields},".::quote_literal($_->{classname})." AS __class FROM $_->{tablename}" } @$subclasses ). ') ';
  }

  my $where     = @{$q->{wheres}} ? 'WHERE '.join(' AND ', map {"($_)" } @{$q->{wheres}}) : '';
  my $order     = @{$q->{order}}     ? 'ORDER BY '.join(', ', @{$q->{order}}) : '';
  my $ext_order = @{$q->{ext_order}} ? 'ORDER BY '.join(', ', @{$q->{ext_order}}) : $order;

  my $sel       = join(', ', @{$q->{select}});
  my $outer_sel = join(', ', @{$q->{outer_select}});
  my $join      = join('  ', (
					( map { "JOIN      $_ " } @{$q->{joins}} ),
					( map { "LEFT JOIN $_ " } @{$q->{internal_left_joins}})   # left joins needed for where, so used in internal select.
  ));

  my $ljoin     = @{$q->{left_joins}} ?  join('  ', map { "LEFT JOIN $_ " } @{$q->{left_joins}}) : '';
  my $with      = @{$q->{with}}       ?  join(', ', @{$q->{with}}) : '';
  my $group;
  if( @{$q->{group}}) {
	$group = "GROUP BY ".join(', ', @{$q->{group}});
	$outer_sel = join(', ', @{$q->{group}}, @{$q->{aggr}});
  } else {
	$group = '';
  }


  my ($limit,@pagebind,@pagetypes) = ('');
  if($pagesize) {
	  $limit = sprintf("LIMIT \$%d OFFSET \$%d", $#{$q->{bind}}+2, $#{$q->{bind}}+3);
 	  push @pagebind, $pagesize, $offset;
	  push @pagetypes, 'int', 'int';
  }

  my ($sql,$nsql,@treebind);
  my $uwith = $with ? "WITH $with " : "";
  my $tree_root = $query->{__root};

  if($tree_root || $query->{__tree} ) {
	my $top_where = ($where ? "$where AND " : "WHERE ");
	if($tree_root) {
		$top_where .= sprintf("(m.parent = \$%d)", $#{$q->{bind}} + $#pagebind + 3);
		push @pagebind, $tree_root;
		push @pagetypes,'idtype';
	} else {
		$top_where .="m.parent IS NULL";
	}
	my ($top_sel,$node_sel)=('','');
	if($query->{__tree} eq 'ordered') {
		$ext_order = 'ORDER BY _pos_path';
		$top_sel = q!, ARRAY[m.pos] AS _pos_path!;
		$node_sel = q!, __tree._pos_path || ARRAY[m.pos] AS _pos_path!;
		$outer_sel.=", parent, _pos_path";
	}


	my $child_where  = ($where ? "$where AND " : "WHERE "). 'm.parent = __tree.id';
	my $rwith = $with  ? " $with," : '';
	$sql = "WITH $rwith RECURSIVE __tree AS (
	                                SELECT $sel $top_sel FROM $table m $join  $top_where
					UNION ALL
	                                SELECT $sel $node_sel FROM $table m $join, __tree $child_where
			)
			SELECT $outer_sel FROM (SELECT $sel FROM __tree m ".
			($limit && !$group? "$order $limit" : "").
			 ") m $ljoin $group $ext_order ".
			($limit && $group ? "$order $limit" : "");
  } else {
	$sql = "$uwith SELECT $outer_sel FROM (SELECT $sel FROM $table m $join$where  ".
			($limit && !$group ? "$order $limit" : "").
			") m $ljoin $group $ext_order " .
			($limit && $group ? "$order $limit" : "");
  }
  $nsql = "$uwith SELECT COUNT(*) AS value FROM $table m $join $where";

  my $debug = $query->{__debug};  # foDo: check permissions
warn "debug mget ($schema, $tablename, $user_id, $page, $pagesize, $query)\n" if $debug;
warn "sql=$sql\n", Data::Dumper::Dumper($q,$query, $sql, $q->{types}, \@pagetypes, $q->{bind}, \@pagebind) if $debug;
  my %ret;
  $ret{list} = ORM::Easy::SPI::spi_run_query($sql, [@{$q->{types}}, @pagetypes ], [@{$q->{bind}}, @pagebind ] )->{rows};

#warn "ret list is ", Data::Dumper::Dumper($ret{list});
  if (!$query->{without_count}) {
	my $l = scalar(@{$ret{list}});
	$ret{n} =
		($l < $pagesize)
		? ($page-1)*$pagesize + $l
		:  ORM::Easy::SPI::spi_run_query_value($nsql, $q->{types}, $q->{bind});
  }

#### For Pg < 13 without transforms for bool: fix bools in rows manually
  my $bool_fields = ORM::Easy::SPI::spi_run_query(q!
		SELECT attname
		FROM pg_attribute a
		JOIN pg_type t ON a.atttypid = t.oid
		WHERE a.attrelid = (SELECT c.oid FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE relname = $2 AND n.nspname = $1)
		  AND a.attnum>0
		  AND t.typcategory = 'B'
	!, [ 'text', 'text'],
	   [ $schema, $tablename]
	)->{rows};

  if($bool_fields && @$bool_fields) {
	foreach my $o (@{$ret{list}}) {
		foreach my $f (@$bool_fields) {
			my $fn = $f->{attname};
			if(defined $o->{$fn}) {
				$o->{$fn} = $o->{$fn} eq 'f' || !$o->{$fn} ? 0 : 1;
			}
		}
	}
  }

########## Smart postprocess-triggers for all superclasses (including this class)

  foreach my $o ( @{ $superclasses->{rows} }) {
	my $func = ORM::Easy::SPI::spi_run_query(q! SELECT * FROM pg_proc p JOIN pg_namespace s ON p.pronamespace = s.oid WHERE p.proname = $2 AND s.nspname = $1!,
			[ 'name', 'name'], [ $o->{schema}, "postquery_$o->{tablename}"] )->{rows};
#		warn "try postquery $o->{schema} $o->{tablename}\n";
	if(@$func) {
#		warn "call $o->{schema}.postquery_$o->{tablename} $q $query\n";
		my $new_list = ORM::Easy::SPI::spi_run_query_expr(
					::quote_ident($o->{schema}).'.'.::quote_ident("postquery_$o->{tablename}").'($1, $2, $3)',
					[ 'idtype', 'jsonb', 'jsonb'],
					[ $user_id, $ret{list}, $query ]
		);
		if($new_list) {
			$ret{list} = $new_list;
		}
#		warn "done $o->{schema}.postquery_$o->{tablename} c=\n";

	}
  }
  %ORM::Easy::SPI::tmp_cache = ();
  return \%ret;
}

############################################## SAVE ###################################

sub _save {
 my ($schema, $tablename, $id, $user_id, $jsondata, $context) = @_;
	my $debug = 0;
# todo: засунуть user_id в сессионный контекст, чтобы подхватить его из триггеров - и то же в orm_interface.remove для триггера delete_history
#	warn "Called save($schema, $tablename, $id, $user_id, $jsondata, $context)\n";

	my $id_is_defined = defined ($id) && ($id=~/^\-?\d+$/);
	my $id_in_data = delete $jsondata->{id}; # так можно явно задать id для нового объекта
	my (%ids);
	$id = ORM::Easy::SPI::make_new_id(($id_is_defined  ? $id : ($id_in_data || $id)), $context, \%ids);
    my $op = $id_is_defined || ( $context && $context->{_created_ids} && $context->{_created_ids}->{$id} ) ? 'update' : 'insert';
    my $data = $jsondata;

### мы должны сходить за атрибутами до проверки доступа, чтобы разрешить висячие ссылки


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
	my @fields = sort keys %$data;
	
# Разрешим висячие ссылки
	foreach my $f (@fields) {
		my $val = $data->{$f};
		my $t   = $field_types_by_attr{$f} || die("Unknown field $f");
		my ($tschema, $type, $typtype, $typcat, $eltype, $eltypecat) = @$t;
		if($typcat eq 'N' && ($val=~/[^\-\d]/)) { 
			$data->{$f}= $val eq 'me' ? $user_id : ORM::Easy::SPI::make_new_id($val, $context, \%ids);
		}
	}
#

## права на каждую таблицу определяются отдельной функцией (user_id,id,data)
## проверка прав делается перед presave, т.к. в presave уже могут быть сделаны изменения в БД, влияющие на права доступа



warn "try $schema.can_${op}_$tablename\n" if $debug;   # если функция есть, вызываем её; если нет - игнорируем (правильно ли это?)
#   toDo: scan superclasses

    if( ORM::Easy::SPI::spi_run_query_bool(q!SELECT EXISTS(SELECT * FROM pg_proc p JOIN pg_namespace s ON p.pronamespace = s.oid WHERE p.proname = $2 AND s.nspname = $1)!,
			[ 'name', 'name'], [ $schema, "can_${op}_$tablename"])) {
		ORM::Easy::SPI::spi_run_query_bool('select '.::quote_ident($schema).'.'.::quote_ident("can_${op}_$tablename").'($1,$2,$3)', ['idtype', 'text', 'jsonb'], [$user_id, $id, $data])
		or die("ORM: ".ORM::Easy::SPI::to_json({error=> "AccessDenied", user=>$user_id, class=>"$schema.$tablename", id=>$id, action=>$op, reason=>1}));
	} else {
		ORM::Easy::SPI::spi_run_query_bool('select orm.can_update_object($1,$2,$3,$4)', ['idtype', 'text','text','jsonb'], [$user_id, ::quote_ident($schema).'.'.::quote_ident($tablename), $id, $data])
		or die("ORM: ".ORM::Easy::SPI::to_json({error=> "AccessDenied", user=>$user_id, class=>"$schema.$tablename", id=>$id, action=>$op, reason=>2}));
	}


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
				? ORM::Easy::SPI::spi_run_query_row('SELECT * FROM '.::quote_ident($schema).'.'.::quote_ident($tablename).' WHERE id = $1', ['idtype' ], [$id])
				: {}
			;

			warn "call $o->{schema}.presave_$o->{tablename}\n" if $debug;
			my $changes = ORM::Easy::SPI::spi_run_query_expr(::quote_ident($o->{schema}).'.'.::quote_ident("presave_$o->{tablename}").'($1, $2, $3, $4, $5, $6, $7)',
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
    @fields = sort keys %$data;
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

#       Already done before
#		} elsif ($typcat eq 'N') {
#			push @types, $type;
#			push @args, !defined($val) || $val eq '' ? undef : ($data->{$f}=ORM::Easy::SPI::make_new_id($val, $context, \%ids));
#
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
			$exprs{$f} = 'coalesce('.::quote_ident($f).",'{}'::int[]) " .$expr_add . $expr_del;
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
			push @types, $type;
			push @args, jsonarray2daterange($val);
		} elsif (($type =~ /^(tstz|date)range$/) && ref($val) eq 'HASH') {
			my ($lower,$upper, $lok, $uok);
			if (exists $val->{upper}) { $upper = $val->{upper}; $uok = 1; }
			if (exists $val->{lower}) { $lower = $val->{lower}; $lok = 1; }
			if ($upper && ($upper !~ /^(\d\d\d\d)-(\d\d)-(\d\d).*$/)) { die("Bad format of upper bound for range $f"); }
			if ($lower && ($lower !~ /^(\d\d\d\d)-(\d\d)-(\d\d).*$/)) { die("Bad format of lower bound for range $f"); }
			my $qf = ::quote_ident($f);
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
        $sql = 'update '.::quote_ident($schema).'.'.::quote_ident($tablename).' set '.join(', ', map {
            ::quote_ident($_)."=$exprs{$_}"
		} @fields_ok).' where id = '.::quote_literal($id).'::idtype returning *';
    } else {  #insert
        $sql = 'insert into '.::quote_ident($schema).'.'.::quote_ident($tablename).' ('.join(', ', map { ::quote_ident($_) } @fields_ok).') values ('.
			join(',', map { $exprs{$_} } @fields_ok). ') returning *';
    }

	warn "SQL=$sql\n" if $debug;
    my $obj = ORM::Easy::SPI::spi_run_query_row($sql, \@types, \@args);
	warn "save done main SQL\n" if $debug;
    foreach my $k (keys %$obj) { if (ref($obj->{$k}) eq 'PostgreSQL::InServer::ARRAY') {  $obj->{$k} = $obj->{$k}->{array}; } }

## RUN postsaves
	$id = $obj->{id};
	if($op eq 'insert' && $context) { ($context->{_created_ids} ||= {})->{$id} = 1; } 

	foreach my $o ( @{ $superclasses->{rows} }) {
		my $func = ORM::Easy::SPI::spi_run_query(q! SELECT * FROM pg_proc p JOIN pg_namespace s ON p.pronamespace = s.oid WHERE p.proname = $2 AND s.nspname = $1!,
			[ 'name', 'name'], [ $o->{schema}, "postsave_$o->{tablename}"] )->{rows};
		warn "try post $o->{schema} $o->{tablename}\n" if $debug;
		if(@$func) {
			warn "call $o->{schema}.postsave_$o->{tablename}\n" if $debug;
			ORM::Easy::SPI::spi_run_query('select '.::quote_ident($o->{schema}).'.'.::quote_ident("postsave_$o->{tablename}").'($1, $2, $3, $4, $5, $6, $7)',
				[ 'idtype', 'idtype', 'text', 'jsonb','jsonb', 'text', 'text' ],
				[ $user_id, $id, $op, $old_data, $jsondata, $schema, $tablename ]
			);
			warn "done $o->{schema}.postsave_$o->{tablename}\n" if $debug;
		}
	}

	warn "Exiting save\n" if $debug;
    return {a=> $obj, b=>{_ids=>\%ids, _created_ids=>$context->{_created_ids}}};
}

######################################################### DELETE ##########################################
sub _delete {

    my ($schema, $tablename, $id, $user_id, $context) = @_;
# todo: засунуть user_id в сессионный контекст, чтобы подхватить его из триггеров - и то же в orm_interface.remove для триггера delete_history
#	warn "Called delete($schema, $tablename, $id, $user_id, $context)\n";

    ## права на каждую таблицу определяются отдельной функцией (user_id,id,data)

    ## toDo надо обработать ситуацию отсутствия этой функции

#	warn "try $schema.can_delete_$tablename\n";
    if( ORM::Easy::SPI::spi_run_query_bool(q!SELECT EXISTS(SELECT * FROM pg_proc p JOIN pg_namespace s ON p.pronamespace = s.oid WHERE p.proname = $2 AND s.nspname = $1)!,
			[ 'name', 'name'], [ $schema, "can_delete_$tablename"])) {
		ORM::Easy::SPI::spi_run_query_bool('select '.::quote_ident($schema).'.'.::quote_ident("can_delete_$tablename").'($1,$2)', ['idtype', 'text'], [$user_id, $id])
		or die("ORM: ".ORM::Easy::SPI::to_json({error=> "AccessDenied", user=>$user_id, class=>"$schema.$tablename", id=>$id, action=>'delete', reason=>1}));
    } else {
		ORM::Easy::SPI::spi_run_query_bool('select orm.can_delete_object($1,$2,$3)', ['idtype', 'text','text'], [$user_id, ::quote_ident($schema).'.'.::quote_ident($tablename), $id])
		or die("ORM: ".ORM::Easy::SPI::to_json({error=> "AccessDenied", user=>$user_id, class=>"$schema.$tablename", id=>$id, action=>'delete', reason=>2}));
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
				ORM::Easy::SPI::spi_run_query('SELECT * FROM '.::quote_ident($schema).'.'.::quote_ident($tablename).' WHERE id = $1', ['idtype' ], [$id])->{rows}->[0]
			);

#			warn "call $o->{schema}.predelete_$o->{tablename}\n";
			my $changes = ORM::Easy::SPI::spi_run_query('select '.::quote_ident($o->{schema}).'.'.::quote_ident("predelete_$o->{tablename}").'($1, $2, $3, $4, $5) AS x',
				[ 'idtype', 'idtype', 'jsonb' , 'text', 'text', ],
				[ $user_id, $id, $old_data, $schema, $tablename ]
			)->{rows}->[0]->{x};
#			warn "done $o->{schema}.predelete_$o->{tablename}\n";

		}
	}
# form and run SQL
#  warn "CRM delete ", Data::Dumper::Dumper($data);

    my $sql = 'delete from '.::quote_ident($schema).'.'.::quote_ident($tablename).'  where id = $1';

    my $ret = ORM::Easy::SPI::spi_run_query($sql, ['idtype'],[$id]);

## RUN postdeletes

	foreach my $o ( @{ $superclasses->{rows} }) {
		my $func = ORM::Easy::SPI::spi_run_query(q! SELECT * FROM pg_proc p JOIN pg_namespace s ON p.pronamespace = s.oid WHERE p.proname = $2 AND s.nspname = $1!,
			[ 'name', 'name'], [ $o->{schema}, "postdelete_$o->{tablename}"] )->{rows};
#		warn "try post $o->{schema} $o->{tablename}\n";
		if(@$func) {
#			warn "call $o->{schema}.postdelete_$o->{tablename}\n";
			ORM::Easy::SPI::spi_run_query('select '.::quote_ident($o->{schema}).'.'.::quote_ident("postdelete_$o->{tablename}").'($1, $2, $3, $4, $5) AS x',
				[ 'idtype', 'idtype',  'jsonb', 'text', 'text', ],
				[ $user_id, $id, $old_data, $schema, $tablename ]
			);
#			warn "done $o->{schema}.postdelete_$o->{tablename}\n";
		}
	}

    return {ok=>1};
}



1;
