CREATE OR REPLACE FUNCTION orm_interface.set_order (schema text, tablename text, ids jsonb, user_id idtype, context jsonb)  
	RETURNS jsonb LANGUAGE PLPERL  TRANSFORM FOR TYPE jsonb  SECURITY DEFINER AS $perl$

    my ($schema, $tablename, $ids, $user_id, $context) = @_;
#	warn "Called set_order($schema, $tablename, $ids, $user_id, $context)\n";
	my $pos = 1;
	$context = $context || {};

	foreach my $id (@$ids) { 
		my $ret = ORM::Easy::SPI::spi_run_query_row('select * FROM orm_interface.save($1, $2, $3, $4, $5, $6)',
				[ 'text', 'text', 'text', 'idtype', 'jsonb','jsonb' ],
				[$schema, $tablename, $id, $user_id, {pos=>$pos++}, $context ] 
		);
		$context = Hash::Merge->new('RIGHT_PRECEDENT')->merge($context, $ret->{b});
	}
	return $context;
$perl$;



