CREATE OR REPLACE FUNCTION orm.can_update_object(user_id bigint, classname text, id text, data jsonb) RETURNS boolean
    LANGUAGE plpgsql
    AS $$
    BEGIN
        IF auth_interface.check_privilege(user_id,'edit_object', ARRAY[ classname ]::text[]) THEN
            RETURN true;
        END IF;
        RETURN false;
    END;
$$;
CREATE OR REPLACE FUNCTION orm.can_delete_object(user_id bigint, classname text, id text) RETURNS boolean
    LANGUAGE plpgsql
    AS $$
    BEGIN
        IF auth_interface.check_privilege(user_id,'delete_object', ARRAY[ classname ]::text[]) THEN
            RETURN true;
        END IF;
        RETURN false;
    END;
$$;

CREATE OR REPLACE FUNCTION orm.can_view_objects(user_id bigint, classname text) RETURNS boolean
	LANGUAGE plpgsql
    AS $$
    BEGIN
        IF auth_interface.check_privilege(user_id,'view_objects', ARRAY[ classname ]::text[]) THEN
            RETURN true;
        END IF;
        RETURN false;
    END;
$$;

CREATE OR REPLACE FUNCTION orm.can_view_object(user_id bigint, classname text, id text) RETURNS boolean
	LANGUAGE plpgsql
    AS $$
    BEGIN
        IF auth_interface.check_privilege(user_id,'view_objects', ARRAY[ classname ]::text[]) THEN
            RETURN true;
        END IF;
        RETURN false;
    END;
$$;
