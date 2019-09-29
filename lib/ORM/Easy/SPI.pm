package ORM::Easy::SPI;
use strict;
use Encode;
use JSON::XS;
use Data::Dumper;
use Time::HiRes;
use Hash::Merge;
use Clone;
use List::Util;
use locale;
require "utf8_heavy.pl";
my $log_mode = 0;

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

	my $h   = ::spi_prepare($sql, @$types);
	my $ret = ::spi_exec_prepared($h, {},  @$values);
	## todo: check and log errors
	if($ret) { 
		unbless_arrays_in_rows( $ret->{rows} );
	}
	::spi_freeplan($h);
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
  my ($list, $convert) = @_;
  my $level = 0;
  my %nodeById;
  my @top;
  my %nodeById = 
		map { my $node =  $convert ? $convert->($_) : $_ ; $node->{id} = $_->{id}; $_->{id} => $node } 
		@$list;
  foreach my $node (
	sort { $a->{pos} <=> $b->{pos} } 
	values %nodeById
  ) { 
		if($node->{parent}) { 	
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
  my ($list, $convert) = @_;
  my $tree = list2tree($list,$convert);
  my @plain;
  my $sub;
  $sub = sub {
	my $nodes = shift;
	my $level = shift;
	foreach my $node (@$nodes) { 
		$node->{level} = $level;
		my $subnodes = delete $node->{children};
		push @plain, $node;
		if($subnodes) { 
			$sub->($subnodes, $level+1);
		}		
	}
  };
  $sub->($tree, 0);
  return \@plain;
}



1;
