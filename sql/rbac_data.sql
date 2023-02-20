insert into auth.privilege (name, comment, classes) values ('delete_object', 'Delete ORM object',  ARRAY['orm.metadata']);
insert into auth.privilege (name, comment, classes) values ('edit_object',   'Edit ORM object',    ARRAY['orm.metadata']);
insert into auth.privilege (name, comment, classes) values ('view_objects',  'View ORM objects',   ARRAY['orm.metadata']);
INSERT INTO auth.privilege (name, comment, classes) VALUES ('create_object', 'Create ORM objects', ARRAY['orm.metadata']);
