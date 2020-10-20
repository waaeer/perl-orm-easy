CREATE OR REPLACE FUNCTION orm_interface.store_file (schema text, tablename text, user_id idtype, data jsonb)  
 		RETURNS jsonb LANGUAGE PLPERL SECURITY DEFINER TRANSFORM FOR TYPE jsonb  AS $perl$

	my ($schema, $tablename, $user_id, $f) = @_;

	my $ff = ORM::Easy::SPI::spi_run_query_row(q!SELECT *, true as is_old FROM !.quote_ident($schema).'.'.quote_ident($tablename).q!
		WHERE checksum = $1!, ['bytea'], ["\\x$f->{checksum}"] 
	);
	if ($ff && $ff->{id}) { 
		return $ff;
	}
	my $ff = ORM::Easy::SPI::spi_run_query_row(q!SELECT * FROM orm_interface.save($1, $2, NULL, $3, $4, NULL)!, 
                ['text','text','idtype', 'jsonb'], [$schema, $tablename, $user_id, $f ])->{a};
	return $ff;

$perl$;

CREATE OR REPLACE FUNCTION orm_interface.store_user_file (schema text, tablename text, user_id idtype, data jsonb)  
 		RETURNS jsonb LANGUAGE PLPERL SECURITY DEFINER TRANSFORM FOR TYPE jsonb  AS $perl$

	my ($schema, $tablename, $user_id, $f) = @_;

	my $ff = ORM::Easy::SPI::spi_run_query_row(q!SELECT *, true as is_old FROM !.quote_ident($schema).'.'.quote_ident($tablename).q!
		WHERE checksum = $1 AND created_by = $2!, ['bytea', 'idtype'], ["\\x$f->{checksum}", $user_id] 
	);
	if ($ff && $ff->{id}) { 
		return $ff;
	}
	my $ff = ORM::Easy::SPI::spi_run_query_row(q!SELECT * FROM orm_interface.save($1, $2, NULL, $3, $4, NULL)!, 
                ['text','text','idtype', 'jsonb'], [$schema, $tablename, $user_id, $f ])->{a};
	return $ff;

$perl$;

