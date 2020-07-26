CREATE OR REPLACE FUNCTION orm.can_update_object(user_id idtype, classname text, id text, data jsonb) RETURNS boolean STABLE PARALLEL SAFE
    LANGUAGE sql
    AS $$
	-- если на данный класс привилегии нет, но есть на его суперкласс - тоже хорошо. Ищем хотя бы один суперкласс, на который привилегия есть.
        -- этого достаточно. При этом игнорируем сразу классы, для которых нет orm.metadata (т.к. привилегий на них нет и подавно)
		SELECT EXISTS (
			WITH main_class AS (
				SELECT x[1] nsp, x[2] tbl FROM parse_ident(classname) x
			)  
			SELECT m.id FROM main_class, orm.get_inheritance_tree(main_class.nsp,main_class.tbl) x, orm.metadata m 
	 		 WHERE m.name = x.schema || '.' || x.tablename 
			   AND auth_interface.check_privilege(user_id, 'edit_object', ARRAY[m.id::text])
		);
$$;
CREATE OR REPLACE FUNCTION orm.can_delete_object(user_id idtype, classname text, id text) RETURNS boolean  STABLE PARALLEL SAFE
    LANGUAGE sql
    AS $$
    	-- если на данный класс привилегии нет, но есть на его суперкласс - тоже хорошо. Ищем хотя бы один суперкласс, на который привилегия есть.
        -- этого достаточно. При этом игнорируем сразу классы, для которых нет orm.metadata (т.к. привилегий на них нет и подавно)
		SELECT EXISTS (
			WITH main_class AS (
				SELECT x[1] nsp, x[2] tbl FROM parse_ident(classname) x
			)  
			SELECT m.id FROM main_class, orm.get_inheritance_tree(main_class.nsp,main_class.tbl) x, orm.metadata m 
	 		 WHERE m.name = x.schema || '.' || x.tablename 
			   AND auth_interface.check_privilege(user_id, 'delete_object', ARRAY[m.id::text])
		);
$$;

CREATE OR REPLACE FUNCTION orm.can_view_objects(user_id idtype, classname text) RETURNS boolean  STABLE PARALLEL SAFE
	LANGUAGE sql
    AS $$

		-- если на данный класс привилегии нет, но есть на его суперкласс - тоже хорошо. Ищем хотя бы один суперкласс, на который привилегия есть.
        -- этого достаточно. При этом игнорируем сразу классы, для которых нет orm.metadata (т.к. привилегий на них нет и подавно)
		SELECT EXISTS (
			WITH main_class AS (
				SELECT x[1] nsp, x[2] tbl FROM parse_ident(classname) x
			)  
			SELECT m.id FROM main_class, orm.get_inheritance_tree(main_class.nsp,main_class.tbl) x, orm.metadata m 
	 		 WHERE m.name = x.schema || '.' || x.tablename 
			   AND (m.public_readable OR auth_interface.check_privilege(user_id, 'view_objects', ARRAY[m.id::text]))
		);

 
$$;

CREATE OR REPLACE FUNCTION orm.can_view_object(user_id idtype, classname text, id text) RETURNS boolean  STABLE PARALLEL SAFE
	LANGUAGE plpgsql
    AS $$
    BEGIN
        IF auth_interface.check_privilege(user_id,'view_objects', ARRAY[ classname ]::text[]) THEN
            RETURN true;
        END IF;
        RETURN false;
    END;
$$;
