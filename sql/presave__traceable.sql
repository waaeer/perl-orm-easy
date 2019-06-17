

CREATE OR REPLACE FUNCTION orm.presave__traceable(user_id bigint, id_ bigint,op_ text, old_data JSONB, data JSONB, schema text, tablename text) RETURNS JSONB LANGUAGE PLPGSQL AS $$
	DECLARE 
		changes JSONB;
	BEGIN
		changes = '{}'::jsonb;
		IF (data->>'changed_by') IS NULL THEN 
			changes = jsonb_set(changes,ARRAY['changed_by'],to_jsonb(user_id), true);
		END IF;

		changes = jsonb_set(changes,ARRAY['mtime'], to_jsonb('now'::text), true);

		IF op_ = 'insert' THEN 
			IF (data->>'created_by') IS NULL THEN 
				changes = jsonb_set(changes,ARRAY['created_by'],to_jsonb(user_id), true);
			END IF;
			changes = jsonb_set(changes,ARRAY['ctime'], to_jsonb('now'::text), true);
		END IF;
		RETURN changes;
	END;
$$;


