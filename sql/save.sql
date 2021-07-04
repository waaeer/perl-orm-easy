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


