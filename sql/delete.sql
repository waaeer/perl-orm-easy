CREATE OR REPLACE FUNCTION orm_interface.delete (schema text, tablename text, id text, user_id idtype, context jsonb)  
		RETURNS jsonb LANGUAGE PLPERL SECURITY DEFINER TRANSFORM FOR TYPE jsonb AS $perl$
   	return ORM::Easy::SPI::_delete(@_);
$perl$;


