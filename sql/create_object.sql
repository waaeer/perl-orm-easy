BEGIN;

  INSERT INTO auth.privilege (name, comment, classes) VALUES ('create_object', 'Создавать объект ORM', ARRAY['orm.metadata']);

COMMIT;
