
CREATE TABLE orm._traceable (
    ctime           TIMESTAMPTZ NOT NULL DEFAULT now(),
    mtime           TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by      idtype,
    changed_by      idtype
);

CREATE TABLE orm.metadata (
	id idtype PRIMARY KEY DEFAULT nextval('orm.id_seq'),
	name text
);
CREATE UNIQUE INDEX metadata_name ON orm.metadata(name);
