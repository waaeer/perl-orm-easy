CREATE OR REPLACE FUNCTION orm.can_insert_object(user_id idtype, classname text, id text) RETURNS boolean STABLE PARALLEL SAFE
    LANGUAGE plpgsql
    AS $$
    BEGIN
        IF auth_interface.check_privilege(user_id, 'create_object', ARRAY[ classname ]::text[]) THEN
            RETURN true;
        END IF;
        RETURN false;
    END;
$$;
