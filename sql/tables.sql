
CREATE TABLE orm._traceable (
    ctime           TIMESTAMPTZ NOT NULL DEFAULT now(),
    mtime           TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by      BIGINT,
    changed_by      BIGINT
);

CREATE TABLE orm.metadata (
	id BIGINT PRIMARY KEY DEFAULT nextval('orm.id_seq'),
	name text
);
CREATE UNIQUE INDEX metadata_name ON orm.metadata(name);
