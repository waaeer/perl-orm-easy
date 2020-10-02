DROP VIEW iF EXISTS auth.user_privileges;
CREATE OR REPLACE VIEW auth.user_privileges AS 
	SELECT ur."user",
		   rp.role,
		   rp.privilege,
		   p.name,
		   ARRAY[
			CASE WHEN rp.parametric[1] THEN ur.objects[1] ELSE rp.objects[1] END,
			CASE WHEN rp.parametric[2] THEN ur.objects[2] ELSE rp.objects[2] END
		  ] AS objects
	FROM auth.role_privileges rp 
		JOIN auth.user_roles ur ON ur.role = rp.role 
		JOIN auth.privilege p ON p.id = rp.privilege 
		WHERE (ur.expires IS NULL OR ur.expires > now())
	;

/* CREATE VIEW auth.user_privileges AS
    SELECT pr.person, p.name, (
		SELECT array_agg(obj_id) FROM (
			SELECT CASE WHEN role_parametric THEN person_object ELSE role_object END obj_id 
			FROM (
				SELECT unnest(pr.objects, rp.parametric, rp.objects) AS x(person_object, role_parametric, role_object)
			) x
		) x ) objects
	  FROM auth.user_roles pr 
		JOIN auth.role_privileges rp ON pr.role = rp.role 
		JOIN auth.privilege p ON rp.privilege = p.id;
*/

CREATE OR REPLACE FUNCTION auth.priv_object_id(name text, tablename text)
	RETURNS idtype LANGUAGE PLPGSQL IMMUTABLE STRICT  AS $$
	DECLARE arr text[];
			id idtype; sql text;
	BEGIN
		IF name ~ '^\d+$' THEN 
			RETURN name::int;
		ELSIF name = '__all__' THEN
			RETURN NULL;
		ELSE 
			arr = parse_ident(tablename);
			sql = 'select id from ' || quote_ident(arr[1]) || '.' || quote_ident(arr[2]) || ' WHERE name = $1'; 
			
			BEGIN			
				EXECUTE sql INTO STRICT id USING name; 
			EXCEPTION
		        WHEN NO_DATA_FOUND THEN
				RAISE EXCEPTION 'No % in %', name, tablename; 
			END;
			RETURN id;
		END IF;
	END;
$$;

CREATE OR REPLACE FUNCTION auth_interface.check_privilege(user_id idtype, privilege_name text, object_ids text[] = NULL) 
	RETURNS bool LANGUAGE SQL IMMUTABLE SECURITY DEFINER AS $$
	SELECT EXISTS(SELECT * FROM auth.user_privileges up 
		JOIN auth.privilege p ON p.id = up.privilege 
		WHERE up."user" = user_id AND p.name = privilege_name AND 
			(
			CASE WHEN object_ids IS NULL OR array_length(object_ids,1)=0  THEN TRUE
				 WHEN array_length(object_ids,1)=1 THEN (auth.priv_object_id(object_ids[1], p.classes[1]) = up.objects[1] OR up.objects[1] IS NULL) 
				 WHEN array_length(object_ids,1)=2 THEN (auth.priv_object_id(object_ids[1], p.classes[1]) = up.objects[1] OR up.objects[1] IS NULL)
						                            AND (auth.priv_object_id(object_ids[2], p.classes[2]) = up.objects[2] OR up.objects[2] IS NULL)
				ELSE FALSE
			END
			)
	);
$$;

CREATE OR REPLACE FUNCTION auth_interface.get_privilege_objects(user_id idtype, privilege_name text)
	RETURNS table (objects idtype[])  LANGUAGE SQL IMMUTABLE AS $$
	SELECT objects
		FROM auth.user_privileges up 
		JOIN auth.privilege p ON p.id = up.privilege 
		WHERE up."user" = user_id AND p.name = privilege_name;
$$;




DROP TYPE IF EXISTS auth_interface.checked_privileges CASCADE;
DO $$ 
	BEGIN IF NOT EXISTS (select * from pg_type WHERE typname='checked_privileges') THEN 
		CREATE TYPE auth_interface.checked_privileges AS (privilege_name text, object_ids text[]);
	END IF;
	END;
$$;


CREATE OR REPLACE FUNCTION auth_interface.check_privileges (user_id idtype, privileges json) 
	RETURNS SETOF auth_interface.checked_privileges LANGUAGE sql AS $$
	SELECT *
		FROM ( SELECT 
			case when (json_typeof(line)='array') then (line->>0)::text else line#>>'{}' end as privilege_name,
			case when (json_typeof(line)='array') then (select array_agg(x)::text[] from json_array_elements_text(line->1) x)  else NULL end as object_ids
				FROM (
					SELECT json_array_elements(privileges) as line
				) lines
		) parsed WHERE auth_interface.check_privilege(user_id, privilege_name, object_ids) 
	;

$$;


CREATE OR REPLACE FUNCTION auth_interface.add_role(user_id idtype, grantee_id idtype, role_ text, objects_ idtype[], expires_ timestamptz = NULL) RETURNS VOID SECURITY DEFINER LANGUAGE PLPGSQL AS $$
	DECLARE role_id idtype; 
	        can_do BOOL;
			role_name TEXT;
			role_checker TEXT;
			inserted_id idtype;
	BEGIN
		IF role_ ~ '^[0-9]+$' THEN
			role_id = role_::idtype;
		ELSE 
			SELECT id INTO role_id FROM auth.role WHERE name = role_;
			IF NOT FOUND THEN
				RAISE EXCEPTION 'No such role %', role_;
			END IF;
		END IF;
		SELECT name INTO STRICT role_name FROM auth.role WHERE id = role_id;

		INSERT INTO auth.user_roles ("user", created_by, role,  objects, expires) VALUES (grantee_id, user_id, role_id,  objects_, expires_)
				 RETURNING id INTO inserted_id;
		IF inserted_id IS NOT NULL THEN 
			RAISE NOTICE 'inserted user_roles %; check permission', inserted_id;
			role_checker = 'can_add_role_' || role_name;
			EXECUTE 'select auth.' || quote_ident(role_checker) || '($1, $2, $3)' INTO can_do USING user_id, grantee_id, objects_;
			IF NOT can_do THEN 
				RAISE EXCEPTION 'Not allowed % to add role % on % to user %', user_id, role_name, objects_, grantee_id;
			END IF;
		END IF;
	END;	

$$;


CREATE OR REPLACE FUNCTION auth_interface.get_roles_addable(user_id idtype, grantee_id idtype)  RETURNS json SECURITY DEFINER LANGUAGE PLPGSQL AS $$
	DECLARE ret json; 
	BEGIN
		-- на какие роли у меня есть привилегия добавлять?
		-- сейчас мы не заморачиваемся с этим, и считаем, что одна привилегия "админа" дает право добавлять все роли.
		-- далее у нас могут появиться маленькие локальные "админчики"
		-- can_add_role_*

		IF auth_interface.check_privilege(user_id, 'manage_internal_users')  THEN
			SELECT json_agg(row_to_json(k)) INTO ret FROM (SELECT * FROM auth.role ORDER BY comment) k;
			RETURN json_build_object('list',ret);
		ELSE 
			raise notice 'not privileged (%) for manage internal users' , user_id;
			RETURN '{"list":[]}'::json;
		END IF;
	END;	

$$;

CREATE OR REPLACE FUNCTION auth_interface.mod_user_roles(user_id idtype, grantee_id idtype, _add idtype[], _del idtype[])  RETURNS json SECURITY DEFINER LANGUAGE PLPGSQL AS $$
	DECLARE i idtype; 
	BEGIN
		-- сейчас мы не заморачиваемся с этим, и считаем, что одна привилегия "админа" дает право добавлять все роли.

		IF auth_interface.check_privilege(user_id, 'manage_internal_users')  THEN
			FOR i IN 1 .. COALESCE(array_length(_add,1),0) LOOP
				INSERT INTO auth.user_roles ("user",role, created_by) VALUES (grantee_id, _add[i], user_id) ON CONFLICT DO NOTHING;
			END LOOP;
			FOR i IN 1 .. COALESCE(array_length(_del,1),0) LOOP
				DELETE FROM auth.user_roles WHERE "user" = grantee_id AND id = _del[i]; -- todo: who?
			END LOOP;
			RETURN json_build_object('ok',1);
		ELSE 
			raise notice 'not privileged (%) for manage internal users' , user_id;
			RETURN json_build_object('error', 'Not allowed');
		END IF;
	END;	

$$;


CREATE OR REPLACE FUNCTION auth_interface.mod_user_roles(user_id idtype, grantee_id idtype, _add jsonb, _del idtype[])  RETURNS json SECURITY DEFINER LANGUAGE PLPGSQL AS $$
	DECLARE i idtype; 
	DECLARE __add jsonb[];
	DECLARE __objects idtype[];
	BEGIN
		-- сейчас мы не заморачиваемся с этим, и считаем, что одна привилегия "админа" дает право добавлять все роли.
		SELECT array_agg(x) INTO __add FROM jsonb_array_elements(_add) x;

		IF auth_interface.check_privilege(user_id, 'manage_internal_users')  THEN
			FOR i IN 1 .. COALESCE(array_length(__add,1),0) LOOP
				SELECT array_agg(x::idtype) INTO __objects FROM jsonb_array_elements_text(__add[i]->'objects') x;
				INSERT INTO auth.user_roles ("user",role, created_by, objects, expires) VALUES (grantee_id, (__add[i]->>'role')::idtype, user_id, __objects, (__add[i]->>'expires')::timestamptz) 
					ON CONFLICT DO NOTHING;
			END LOOP;
			FOR i IN 1 .. COALESCE(array_length(_del,1),0) LOOP
				DELETE FROM auth.user_roles WHERE "user" = grantee_id AND id = _del[i]; -- todo: who?
			END LOOP;
			RETURN json_build_object('ok',1);
		ELSE 
			raise notice 'not privileged (%) for manage internal users' , user_id;
			RETURN json_build_object('error', 'Not allowed');
		END IF;
	END;	

$$;

