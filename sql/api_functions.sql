CREATE OR REPLACE FUNCTION orm_interface.mget(schema text, tablename text, user_id idtype, page int, pagesize int, query jsonb) 
	RETURNS jsonb SECURITY DEFINER LANGUAGE plperl TRANSFORM FOR TYPE jsonb AS 
$perl$
	return ORM::Easy::SPI::_mget(@_);
 $perl$;

CREATE OR REPLACE FUNCTION orm_interface.save (schema text, tablename text, id text, user_id idtype, data jsonb, context jsonb)  
 	RETURNS json_pair LANGUAGE PLPERL SECURITY DEFINER TRANSFORM FOR TYPE jsonb  AS $perl$
   	return ORM::Easy::SPI::_save(@_);
$perl$;


CREATE OR REPLACE FUNCTION orm_interface.jsonarray2daterange (val jsonb)  
 	RETURNS daterange LANGUAGE PLPERL IMMUTABLE PARALLEL SAFE TRANSFORM FOR TYPE jsonb  AS $perl$
   	return ORM::Easy::SPI::array2daterange(@_);
$perl$;

CREATE OR REPLACE FUNCTION orm_interface.jsonarray2idtypearray (val jsonb)
	RETURNS idtype[] STRICT IMMUTABLE PARALLEL SAFE LANGUAGE sql AS $$
	SELECT array_agg(x::idtype) FROM jsonb_array_elements_text(val) x;
$$;

CREATE OR REPLACE FUNCTION orm_interface.delete (schema text, tablename text, id text, user_id idtype, context jsonb)  
	RETURNS jsonb LANGUAGE PLPERL SECURITY DEFINER TRANSFORM FOR TYPE jsonb AS $perl$
   	return ORM::Easy::SPI::_delete(@_);
$perl$;

CREATE OR REPLACE FUNCTION orm_interface.set_order (schema text, tablename text, ids jsonb, field text, user_id idtype, context jsonb)  
	RETURNS jsonb LANGUAGE PLPERL  TRANSFORM FOR TYPE jsonb  SECURITY DEFINER AS $perl$

    my ($schema, $tablename, $ids, $fld, $user_id, $context) = @_;
#	warn "Called set_order($schema, $tablename, $ids, $fld, $user_id, $context)\n";
	my $pos = 1;
	$context = $context || {};
	$fld ||= 'pos';

	foreach my $id (@$ids) { 
		$id = ORM::Easy::SPI::make_new_id($id, $context, {});
		my $ret = ORM::Easy::SPI::spi_run_query_row('select * FROM orm_interface.save($1, $2, $3, $4, $5, $6)',
				[ 'text', 'text', 'text', 'idtype', 'jsonb','jsonb' ],
				[$schema, $tablename, $id, $user_id, {$fld => $pos++}, $context ] 
		);
		$context = Hash::Merge->new('RIGHT_PRECEDENT')->merge($context, $ret->{b});
	}
	return $context;
$perl$;



