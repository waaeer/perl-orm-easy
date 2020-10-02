CREATE SCHEMA auth;
CREATE SCHEMA auth_interface;
CREATE TABLE auth.history_log(
    relname text not null,
    id      idtype not null,  
    time    timestamptz not null default now(),
    data    json,
    "user"  idtype   
);
CREATE TABLE auth.delete_log(
    relname text not null,
    id      idtype not null,
    time    timestamptz not null default now(),
    "user"  idtype
);


CREATE TABLE auth.role (
	id	idtype PRIMARY KEY DEFAULT nextval('orm.id_seq'),
	name text unique,
	comment text,
	classes text[]
); 

CREATE TABLE auth.privilege ( 
	id	idtype PRIMARY KEY DEFAULT nextval('orm.id_seq'),
	name text unique,
	comment text,
	classes text[]
); 

CREATE TABLE auth.user_roles ( 
	id	idtype PRIMARY KEY DEFAULT nextval('orm.id_seq'),
	"user" idtype NOT NULL , 
	role   idtype NOT NULL REFERENCES auth.role(id),
	ctime      TIMESTAMPTZ NOT NULL DEFAULT now(),
	mtime	   TIMESTAMPTZ NOT NULL DEFAULT now(),
	exires     TIMESTAMPTZ,
	created_by  idtype,
	changed_by  idtype,

	objects idtype[]
);


CREATE TABLE auth.role_privileges ( 
	id	idtype PRIMARY KEY DEFAULT nextval('orm.id_seq'),
	role      idtype NOT NULL REFERENCES auth.role(id),
	privilege idtype NOT NULL REFERENCES auth.privilege(id),
	objects   idtype[],
	parametric BOOL[]
);
CREATE UNIQUE INDEX role_privileges_uq ON auth.role_privileges (role,privilege,coalesce(objects,ARRAY[]::idtype[]),coalesce(parametric, ARRAY[]::bool[]));



