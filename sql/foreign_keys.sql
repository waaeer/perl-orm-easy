CREATE TABLE orm.array_foreign_key (
	src_schema text NOT NULL,
	src_table  text NOT NULL,
	src_field  text NOT NULL,
	dst_schema text NOT NULL,
	dst_table  text NOT NULL,
	PRIMARY KEY (src_schema,  src_table, src_field, dst_schema, dst_table)
);

CREATE TABLE orm.abstract_foreign_key (
	src_schema text NOT NULL,
	src_table  text NOT NULL,
	src_field  text NOT NULL,
	dst_schema text NOT NULL,
	dst_table  text NOT NULL,
	PRIMARY KEY (src_schema,  src_table, src_field, dst_schema, dst_table)
);

CREATE OR REPLACE FUNCTION orm.array_foreign_key_i () RETURNS TRIGGER LANGUAGE plpgsql AS $$
	BEGIN
		EXECUTE 'CREATE OR REPLACE TRIGGER '   || quote_ident(NEW.src_table || '_afk' ) 
		     || ' BEFORE INSERT OR UPDATE ON ' || quote_ident(NEW.src_schema) || '.' || quote_ident(NEW.src_table)
		     || ' FOR EACH ROW EXECUTE FUNCTION orm.check_outgoing_array_refs()';
		EXECUTE 'CREATE OR REPLACE TRIGGER '   || quote_ident(NEW.dst_table || '_ifk' ) 
		     || ' BEFORE DELETE           ON ' || quote_ident(NEW.dst_schema) || '.' || quote_ident(NEW.dst_table)
		     || ' FOR EACH ROW EXECUTE FUNCTION orm.check_incoming_array_refs()';
	RETURN NEW;
	END;
$$;

CREATE OR REPLACE FUNCTION orm.array_foreign_key_d () RETURNS TRIGGER LANGUAGE plpgsql AS $$
	BEGIN
		IF NOT EXISTS (SELECT * FROM orm.array_foreign_key a WHERE a.src_schema = OLD.src_schema AND a.src_table = OLD.src_table) THEN
		    EXECUTE 'DROP TRIGGER IF EXISTS ' || quote_ident(OLD.src_table || '_afk' ) 
      		 						|| ' ON ' || quote_ident(OLD.src_schema) || '.' || quote_ident(OLD.src_table);
		END IF;
		IF NOT EXISTS (SELECT * FROM orm.array_foreign_key a WHERE a.dst_schema = OLD.dst_schema AND a.dst_table = OLD.dst_table) THEN
  		    EXECUTE 'DROP TRIGGER IF EXISTS ' || quote_ident(OLD.dst_table || '_ifk' ) 
							        || ' ON ' || quote_ident(OLD.dst_schema) || '.' || quote_ident(OLD.dst_table);
		END IF;
	RETURN OLD;
	END;
$$;


CREATE OR REPLACE FUNCTION orm.abstract_foreign_key_i () RETURNS TRIGGER LANGUAGE plpgsql AS $$
	DECLARE r RECORD;
	BEGIN
		EXECUTE 'CREATE OR REPLACE TRIGGER '   || quote_ident(NEW.src_table || '_bfk' ) 
		     || ' BEFORE INSERT OR UPDATE ON ' || quote_ident(NEW.src_schema) || '.' || quote_ident(NEW.src_table)
		     || ' FOR EACH ROW EXECUTE FUNCTION orm.check_outgoing_abstract_refs()';
		FOR r IN SELECT * FROM orm.get_subclasses(NEW.dst_schema, NEW.dst_table) LOOP
			EXECUTE 'CREATE OR REPLACE TRIGGER '   || quote_ident(r.tablename || '_kfk' ) 
		         || ' BEFORE DELETE           ON ' || quote_ident(r.schema) || '.' || quote_ident(r.tablename)
		         || ' FOR EACH ROW EXECUTE FUNCTION orm.check_incoming_abstract_refs()';
		
		END LOOP;
		     
	RETURN NEW;
	END;
$$;

CREATE OR REPLACE FUNCTION orm.abstract_foreign_key_d () RETURNS TRIGGER LANGUAGE plpgsql AS $$
	DECLARE r RECORD;
	BEGIN
		IF NOT EXISTS (SELECT * FROM orm.abstract_foreign_key a WHERE a.src_schema = OLD.src_schema AND a.src_table = OLD.src_table) THEN
		    EXECUTE 'DROP TRIGGER IF EXISTS ' || quote_ident(OLD.src_table || '_bfk' ) 
      		 						|| ' ON ' || quote_ident(OLD.src_schema) || '.' || quote_ident(OLD.src_table);
		END IF;
		FOR r IN SELECT * FROM orm.get_subclasses(OLD.dst_schema, OLD.dst_table) LOOP
			IF NOT EXISTS (SELECT * FROM orm.abstract_foreign_key a WHERE a.dst_schema = r.schema AND a.dst_table = r.tablename) THEN
  			    EXECUTE 'DROP TRIGGER IF EXISTS ' || quote_ident(r.tablename || '_kfk' ) 
								        || ' ON ' || quote_ident(r.schema) || '.' || quote_ident(r.tablename);
			END IF;
		END LOOP;
	RETURN OLD;
	END;
$$;


CREATE TRIGGER array_foreign_key_i    AFTER  INSERT ON orm.array_foreign_key    FOR EACH ROW EXECUTE FUNCTION orm.array_foreign_key_i();
CREATE TRIGGER array_foreign_key_d    BEFORE DELETE ON orm.array_foreign_key    FOR EACH ROW EXECUTE FUNCTION orm.array_foreign_key_d();
CREATE TRIGGER abstract_foreign_key_i AFTER  INSERT ON orm.abstract_foreign_key FOR EACH ROW EXECUTE FUNCTION orm.abstract_foreign_key_i();
CREATE TRIGGER abstract_foreign_key_d BEFORE DELETE ON orm.abstract_foreign_key FOR EACH ROW EXECUTE FUNCTION orm.abstract_foreign_key_d();

CREATE OR REPLACE FUNCTION orm.check_outgoing_abstract_refs () RETURNS TRIGGER LANGUAGE plperl AS $$
    foreach my $r (@{
        ORM::Easy::SPI::spi_run_query(q! SELECT * FROM orm.abstract_foreign_key WHERE src_schema = $1 AND src_table = $2 !, ['text', 'text'], [$_TD->{table_schema}, $_TD->{table_name}])->{rows}
    }) { 
        my $v = $_TD->{new}{$r->{src_field}};
        my $has_ref = ORM::Easy::SPI::spi_run_query_bool('SELECT EXISTS (SELECT * FROM '. quote_ident($r->{dst_schema}).'.'.quote_ident($r->{dst_table}).' WHERE id = $1)',
            ['idtype'], [$v]
        );
        if(!$has_ref) {
            elog(ERROR, sprintf("%s.%s.%s = %s should reference to %s.%s.id", $r->{src_schema}, $r->{src_table}, $r->{src_field}, $v, $r->{dst_schema}, $r->{dst_table}));
        }
    }
    return;
$$;

CREATE OR REPLACE FUNCTION orm.check_incoming_abstract_refs() RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE has_ref bool;
		r RECORD;
BEGIN
    FOR r IN SELECT * FROM orm.abstract_foreign_key k , orm.get_inheritance_tree(TG_TABLE_SCHEMA,TG_TABLE_NAME) t WHERE k.dst_schema = t.schema AND k.dst_table = t.tablename LOOP
        EXECUTE 'SELECT EXISTS (SELECT * FROM ' || quote_ident(r.src_schema) || '.' || quote_ident(r.src_table) || 
                 ' WHERE  ' || quote_ident(r.src_field) || ' = $1 )'  
            INTO has_ref USING OLD.id;
        IF has_ref THEN
            RAISE EXCEPTION 'Referenced object deletion: %.%.id = %.%.% ', r.dst_schema, r.dst_table, r.src_schema, r.src_table, r.src_field;
        END IF;
    END LOOP;
    RETURN OLD;
END;
$$;

CREATE OR REPLACE FUNCTION orm.check_outgoing_array_refs () RETURNS TRIGGER LANGUAGE plperl AS $$
    foreach my $r (@{
        ORM::Easy::SPI::spi_run_query(q! SELECT * FROM orm.array_foreign_key WHERE src_schema = $1 AND src_table = $2 !, ['text', 'text'], [$_TD->{table_schema}, $_TD->{table_name}])->{rows}
    }) { 
        my $vv = $_TD->{new}{$r->{src_field}};
        if ($vv) {
        	foreach my $v (@{$vv->{array}}) {
		        my $has_ref = ORM::Easy::SPI::spi_run_query_bool('SELECT EXISTS (SELECT * FROM '. quote_ident($r->{dst_schema}).'.'.quote_ident($r->{dst_table}).' WHERE id = $1)',
        		    ['idtype'], [$v]
        		);
        		if(!$has_ref) {
		            elog(ERROR, sprintf("%s.%s.%s = %s should reference %s.%s.id", $r->{src_schema}, $r->{src_table}, $r->{src_field}, $v, $r->{dst_schema}, $r->{dst_table}));
        		}
        	}
        }
        
    }
    return;		
$$;

CREATE OR REPLACE FUNCTION orm.check_incoming_array_refs () RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE has_ref BOOL;
    r RECORD;
BEGIN
    FOR r IN SELECT * FROM orm.array_foreign_key WHERE dst_schema = TG_TABLE_SCHEMA AND dst_table = TG_TABLE_NAME LOOP
        EXECUTE 'SELECT EXISTS (SELECT * FROM ' || quote_ident(r.src_schema) || '.' || quote_ident(r.src_table) || 
                 ' WHERE  ' || quote_ident(r.src_field) || ' && ARRAY[$1] )'  
            INTO has_ref USING OLD.id;
        IF has_ref THEN
            RAISE EXCEPTION 'Referenced object deletion: %.%.id in %.%.% ', r.dst_schema, r.dst_table, r.src_schema, r.src_table, r.src_field;
        END IF;
    END LOOP;
    RETURN OLD;
END;
$$;



