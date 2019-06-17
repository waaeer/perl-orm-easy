CREATE SCHEMA auth;
CREATE SCHEMA auth_interface;
CREATE TABLE auth.history_log(
    relname text not null,
    id      int8 not null,  
    time    timestamptz not null default now(),
    data    json,
    "user"  int8   
);
CREATE TABLE auth.delete_log(
    relname text not null,
    id      int8 not null,
    time    timestamptz not null default now(),
    "user"  int8
);


CREATE TABLE auth.role (
	id	INT8 PRIMARY KEY DEFAULT nextval('orm.id_seq'),
	name text unique,
	comment text,
	classes text[]
); 

CREATE TABLE auth.privilege ( 
	id	INT8 PRIMARY KEY DEFAULT nextval('orm.id_seq'),
	name text unique,
	comment text,
	classes text[]
); 

CREATE TABLE auth.user_roles ( 
	id	INT8 PRIMARY KEY DEFAULT nextval('orm.id_seq'),
	"user" INT8 NOT NULL , 
	role   INT8 NOT NULL REFERENCES auth.role(id),
	ctime      TIMESTAMPTZ NOT NULL DEFAULT now(),
	mtime	   TIMESTAMPTZ NOT NULL DEFAULT now(),
	created_by  INT8,
	changed_by  INT8,

	objects INT8[]
);


CREATE TABLE auth.role_privileges ( 
	id	INT8 PRIMARY KEY DEFAULT nextval('orm.id_seq'),
	role      INT8 NOT NULL REFERENCES auth.role(id),
	privilege INT8 NOT NULL REFERENCES auth.privilege(id),
	objects   INT8[],
	parametric BOOL[]
);
CREATE UNIQUE INDEX role_privileges_uq ON auth.role_privileges (role,privilege,coalesce(objects,ARRAY[]::int8[]),coalesce(parametric, ARRAY[]::bool[]));



