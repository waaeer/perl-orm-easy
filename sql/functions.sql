CREATE EXTENSION plperl;
CREATE EXTENSION jsonb_plperl;

CREATE OR REPLACE FUNCTION jsonb_set_correct( o jsonb, path text[], value jsonb, to_create bool) RETURNS jsonb 
		STABLE LANGUAGE plperl TRANSFORM FOR TYPE jsonb AS $$
	my ($o, $path, $v, $to_create) = @_;
#	my $json = JSON::XS->new->allow_nonref;	
#	$o &&= $json->decode(Encode::encode_utf8($o));
#	$v &&= $json->decode(Encode::encode_utf8($v));
	$path = $path->{array};
	my $curr_o = \$o;
	foreach my $x (@$path) { 
		## если на этом уровне в объекте ничего нет, создаем исходя из типа ключа
		my $key_is_number =  Scalar::Util::looks_like_number($x);
		if(!${$curr_o}) { 
			if(!$to_create) { 
				return $o; # Encode::decode_utf8($json->encode($o)); 
			}
			${$curr_o} = $key_is_number ? [] : {};
		}
		if (ref(${$curr_o}) eq 'ARRAY' && $key_is_number) {
			$curr_o = \((${$curr_o})->[$x]);
		} elsif (ref(${$curr_o}) eq 'HASH') { 
			$curr_o = \((${$curr_o})->{$x});
		} else { 
			warn "key '$x' type mismatch";
			return $o; # Encode::decode_utf8($json->encode($o));
		}
	}
	${$curr_o} = $v;

	return $o;
#	return Encode::decode_utf8($json->encode($o));
$$;




CREATE TYPE json_pair AS (a jsonb, b jsonb);

CREATE OR REPLACE FUNCTION orm.save_with_time() RETURNS TRIGGER LANGUAGE PLPGSQL SECURITY DEFINER AS $$
    BEGIN
		NEW.mtime = now();
	    RETURN NEW; 
    END;
$$;
CREATE OR REPLACE FUNCTION orm.save_creator() RETURNS TRIGGER LANGUAGE PLPGSQL SECURITY DEFINER AS $$
    BEGIN
--		raise warning 'set created by in trigger from % to %', NEW.created_by ,NEW.changed_by;
		NEW.created_by = NEW.changed_by;
	    RETURN NEW; 
    END;
$$;


CREATE OR REPLACE FUNCTION orm.save_history() RETURNS TRIGGER LANGUAGE PLPGSQL SECURITY DEFINER AS $$
    BEGIN
    EXECUTE 'INSERT INTO ' || quote_ident(TG_TABLE_SCHEMA) || '.history_log (relname,id,data,"user") VALUES ($1,$2,$3, $4)' USING TG_TABLE_NAME, NEW.id, row_to_json(NEW), NEW.changed_by;
    RETURN NEW; 
    END;
$$;
CREATE OR REPLACE FUNCTION orm.delete_history() RETURNS TRIGGER LANGUAGE PLPGSQL SECURITY DEFINER AS $$
    BEGIN
	EXECUTE 'INSERT INTO ' || quote_ident(TG_TABLE_SCHEMA) || '.delete_log (relname,id,"user") VALUES ($1,$2, NULL)' USING TG_TABLE_NAME, OLD.id; 
	RETURN OLD;
    END;
$$;


CREATE OR REPLACE FUNCTION orm.get_next_id () RETURNS idtype LANGUAGE sql AS $$ select nextval('orm.id_seq')::idtype; $$;

CREATE OR REPLACE FUNCTION orm.make_triggers(schema text, tbl text) RETURNS void LANGUAGE PLPGSQL AS $$
	DECLARE 
		has_mtime BOOL; 
		has_creator BOOL;
	BEGIN
		SELECT EXISTS(
			SELECT 1 
				FROM pg_attribute 
	            WHERE attrelid = (SELECT oid FROM pg_class WHERE relname = tbl AND relnamespace = (select oid from pg_namespace where nspname = schema))
				 AND attnum>0
				 AND attname = 'mtime'
		), EXISTS (			
			SELECT 1 
				FROM pg_attribute 
	            WHERE attrelid = (SELECT oid FROM pg_class WHERE relname = tbl AND relnamespace = (select oid from pg_namespace where nspname = schema))
				 AND attnum>0
				 AND attname = 'created_by'
		) INTO has_mtime, has_creator;

		EXECUTE     'create trigger '|| quote_ident('tg_' || tbl || '_i' ) || ' after  insert on ' || quote_ident(schema) || '.' || quote_ident(tbl) || ' FOR EACH ROW  EXECUTE PROCEDURE  orm.save_history ();'; 
		IF has_mtime THEN
			EXECUTE 'create trigger '|| quote_ident('tg_' || tbl || '_bu') || ' before update on ' || quote_ident(schema) || '.' || quote_ident(tbl) || ' FOR EACH ROW  EXECUTE PROCEDURE  orm.save_with_time ();'; 
		END IF;
		IF has_creator THEN
			EXECUTE 'create trigger '|| quote_ident('tg_' || tbl || '_bi') || ' before insert on ' || quote_ident(schema) || '.' || quote_ident(tbl) || ' FOR EACH ROW  EXECUTE PROCEDURE  orm.save_creator ();'; 
		END IF;
		EXECUTE     'create trigger '|| quote_ident('tg_' || tbl || '_u' ) || ' after  update on ' || quote_ident(schema) || '.' || quote_ident(tbl) || ' FOR EACH ROW  EXECUTE PROCEDURE  orm.save_history ();'; 
		EXECUTE     'create trigger '|| quote_ident('tg_' || tbl || '_d' ) || ' before delete on ' || quote_ident(schema) || '.' || quote_ident(tbl) || ' FOR EACH ROW  EXECUTE PROCEDURE  orm.delete_history ();'; 

	END;
$$;


CREATE TYPE orm.inheritance_list_item AS (id OID, schema name, tablename name, depth int, pos int);

CREATE OR REPLACE FUNCTION orm.get_inheritance_tree(schema_ text, tablename_ text) RETURNS SETOF orm.inheritance_list_item LANGUAGE SQL SECURITY DEFINER AS $$
	WITH RECURSIVE  tree AS 
		(SELECT c.oid AS id, s.nspname, c.relname, 0 AS depth, 0 AS pos FROM pg_class c 
        JOIN pg_namespace s ON c.relnamespace = s.oid  WHERE relname=tablename_ and nspname=schema_
	), 
	subtree AS 
		(SELECT * from tree
		 UNION ALL SELECT c.oid, s.nspname, c.relname, depth + 1 AS depth, inhseqno AS pos 
		 FROM pg_class c 
		 JOIN pg_namespace s ON c.relnamespace = s.oid 
         JOIN pg_inherits i  ON inhparent = c.oid 
         JOIN tree           ON i.inhrelid = tree.id 
	) 
	SELECT * FROM subtree ORDER BY depth, pos;
$$;


