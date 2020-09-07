
CREATE TABLE orm._traceable (
    ctime           TIMESTAMPTZ NOT NULL DEFAULT now(),
    mtime           TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by      idtype,
    changed_by      idtype
);

CREATE TABLE orm.metadata (
	id idtype PRIMARY KEY DEFAULT nextval('orm.id_seq'),
	public_readable bool not null default false,
	name text
);
CREATE UNIQUE INDEX metadata_name ON orm.metadata(name);

CREATE TABLE orm._file (
	id idtype PRIMARY KEY DEFAULT nextval('orm.id_seq'),
	name text,
	path text,
	content_type text,
	size int8,
	height int,
	width int,
	checksum bytea	
) INHERITS (orm._traceable);
CREATE UNIQUE INDEX file_checksum ON orm._file(checksum);
CREATE INDEX file_path ON orm._file(path);

CREATE TABLE orm.history_log (
    relname text not null,
    id      idtype not null,
    time    timestamptz not null default now(),
    data    json,
    "user"  idtype
);
CREATE TABLE orm.delete_log(
    relname text not null,
    id      idtype not null,
    time    timestamptz not null default now(),
    "user"  idtype
);

