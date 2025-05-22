CREATE OR REPLACE FUNCTION orm.query__traceable (user_id idtype, q jsonb, query jsonb) RETURNS jsonb STABLE LANGUAGE PLPERL 
   TRANSFORM FOR TYPE jsonb, FOR TYPE bool
AS $$
	my ($user_id, $q, $query) = @_;

	if($query->{debug} && 
	   ORM::Easy::SPI::spi_run_query_bool('select auth_interface.check_privilege($1,$2)', ['idtype' , 'text' ], [$user_id, 'debug' ])
	) {  $q->{debug} = 1;
	}
	return $q;
$$;

