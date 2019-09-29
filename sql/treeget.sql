CREATE OR REPLACE FUNCTION orm_interface.treeget(schema text, tablename text, user_id idtype, query jsonb)
	RETURNS jsonb SECURITY DEFINER LANGUAGE plperl TRANSFORM FOR TYPE jsonb AS
$perl$
  my ($schema, $tablename, $user_id, $query) = @_;
#warn "TReeget\n";
  my $plain = delete $query->{__plain};
  my $list = ORM::Easy::SPI::spi_run_query_expr('orm_interface.mget($1,$2,$3,$4,$5,$6)',
	['text','text', 'idtype', 'int', 'int', 'jsonb'],
	[ $schema, $tablename, $user_id, 1, undef, 
			{ %{$query || {}},
			  without_count=>1
			}
	]);
 
#	warn 'Sections=', Data::Dumper::Dumper($query, $list);

  return { tree=>$plain ? ORM::Easy::SPI::list2plaintree($list->{list}) : ORM::Easy::SPI::list2tree($list->{list}) };
$perl$;




