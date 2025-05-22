
CREATE OR REPLACE FUNCTION jsonb_set_correct( o jsonb, path text[], value jsonb, to_create bool) RETURNS jsonb 
		STABLE LANGUAGE plperl TRANSFORM FOR TYPE jsonb, FOR TYPE bool AS $$
	my ($o, $path, $v, $to_create) = @_;
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

DROP TYPE IF EXISTS orm.inheritance_list_item CASCADE;
CREATE TYPE orm.inheritance_list_item AS (id OID, schema name, tablename name, parent OID, path OID[], depth int, pos int);

CREATE OR REPLACE FUNCTION orm.get_inheritance_tree(schema_ text, tablename_ text) RETURNS SETOF orm.inheritance_list_item LANGUAGE SQL STABLE PARALLEL SAFE SECURITY DEFINER AS $$
	WITH RECURSIVE  tree AS (
		SELECT c.oid AS relid, s.nspname, c.relname, ARRAY[c.oid] AS path, 0 AS depth, 0 AS pos FROM pg_class c 
        JOIN pg_namespace s ON c.relnamespace = s.oid  WHERE relname=tablename_ and nspname=schema_
	UNION ALL 
		 SELECT c.oid AS relid, s.nspname, c.relname, array_cat(ARRAY[c.oid],tree.path), depth + 1 AS depth, inhseqno AS pos 
		 FROM pg_class c 
		 JOIN pg_namespace s ON c.relnamespace = s.oid 
         JOIN pg_inherits i  ON inhparent = c.oid 
         JOIN tree           ON i.inhrelid = tree.relid
	) 
	SELECT relid AS id, nspname AS schema, relname AS tablename,path[array_length(path,1)-2] AS parent, path, depth, pos FROM tree ORDER BY depth, pos;
$$;

CREATE OR REPLACE FUNCTION orm.get_subclasses(schema_ text, tablename_ text) RETURNS SETOF orm.inheritance_list_item LANGUAGE SQL STABLE PARALLEL SAFE SECURITY DEFINER AS $$
	WITH RECURSIVE  tree AS (
		SELECT c.oid AS relid, s.nspname, c.relname, NULL::oid AS parent, ARRAY[c.oid] AS path, 0 AS depth, 0 AS pos FROM pg_class c 
        JOIN pg_namespace s ON c.relnamespace = s.oid  WHERE relname=tablename_ and nspname=schema_
	UNION ALL 
		 SELECT c.oid AS relid, s.nspname, c.relname, tree.relid, array_cat(tree.path, ARRAY[c.oid]) AS path, depth + 1 AS depth, inhseqno AS pos
		 FROM pg_class c 
		 JOIN pg_namespace s ON c.relnamespace = s.oid 
         JOIN pg_inherits i  ON inhrelid = c.oid 
         JOIN tree           ON i.inhparent = tree.relid
	) 
	SELECT * FROM tree ORDER BY depth, pos;
$$;

CREATE OR REPLACE FUNCTION orm.get_terminal_subclasses(schema_ text, tablename_ text) RETURNS SETOF orm.inheritance_list_item LANGUAGE SQL STABLE PARALLEL SAFE SECURITY DEFINER AS $$
	WITH tree AS (SELECT * FROM orm.get_subclasses(schema_, tablename_))
	SELECT * FROM tree t
		WHERE NOT EXISTS (SELECT * FROM tree t1 WHERE t1.parent = t.id);
$$;



