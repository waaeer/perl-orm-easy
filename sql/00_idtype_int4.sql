CREATE DOMAIN idtype int4; 
CREATE EXTENSION intarray;

--CREATE FUNCTION _int_overlap(a idtype[], b idtype[]) RETURNS BOOL LANGUAGE SQL STRICT IMMUTABLE PARALLEL SAFE AS $$ SELECT _int_overlap(a::_int4, b::_int4) $$;
CREATE FUNCTION _int_overlap(a idtype[], b idtype[]) RETURNS BOOL LANGUAGE SQL STRICT IMMUTABLE 
    SECURITY DEFINER -- чтобы функция не инлайнилась, иначе заинлайнится основанный на ней оператор и постгрес не сообразит, что индекс нужно использовать.
    PARALLEL SAFE AS $$ SELECT a::_int4 &&  b::_int4 $$;

CREATE OPERATOR && (
    LEFTARG = idtype[],
    RIGHTARG = idtype[],
    PROCEDURE = _int_overlap,
    COMMUTATOR = '&&',
    RESTRICT = _int_overlap_sel,
    JOIN = _int_overlap_joinsel
);
DO LANGUAGE plpgsql $$
BEGIN
IF regexp_replace(version(), '^.*?(\d+).*$', '\1') < 14::text THEN
CREATE OPERATOR CLASS gist__idtypebig_ops FOR TYPE idtype[] USING gist AS
    OPERATOR    3   && ,
    OPERATOR    6   =  (anyarray, anyarray),
    OPERATOR    7   @> (_int4,_int4) ,
    OPERATOR    8   <@ (_int4,_int4),
    OPERATOR    13  @  (_int4,_int4),
    OPERATOR    14  ~  (_int4,_int4),
    OPERATOR    20  @@ (_int4, query_int),
    FUNCTION    1   g_intbig_consistent (internal, _int4, smallint, oid, internal),
    FUNCTION    2   g_intbig_union (internal, internal),
    FUNCTION    3   g_intbig_compress (internal),
    FUNCTION    4   g_intbig_decompress (internal),
    FUNCTION    5   g_intbig_penalty (internal, internal, internal),
    FUNCTION    6   g_intbig_picksplit (internal, internal),
    FUNCTION    7   g_intbig_same (intbig_gkey, intbig_gkey, internal),
    STORAGE     intbig_gkey;
ELSE 
CREATE OPERATOR CLASS gist__idtypebig_ops FOR TYPE idtype[] USING gist AS
    OPERATOR    3   && ,
    OPERATOR    6   =  (anyarray, anyarray),
    OPERATOR    7   @> (_int4,_int4) ,
    OPERATOR    8   <@ (_int4,_int4),
    OPERATOR    20  @@ (_int4, query_int),
    FUNCTION    1   g_intbig_consistent (internal, _int4, smallint, oid, internal),
    FUNCTION    2   g_intbig_union (internal, internal),
    FUNCTION    3   g_intbig_compress (internal),
    FUNCTION    4   g_intbig_decompress (internal),
    FUNCTION    5   g_intbig_penalty (internal, internal, internal),
    FUNCTION    6   g_intbig_picksplit (internal, internal),
    FUNCTION    7   g_intbig_same (intbig_gkey, intbig_gkey, internal),
    STORAGE     intbig_gkey;
CREATE OPERATOR CLASS gin__idtype_ops FOR TYPE idtype[] USING gin AS
	OPERATOR	3	&&,
	OPERATOR	6	= (anyarray, anyarray),
	OPERATOR	8	<@,
	OPERATOR	20	@@ (_int4, query_int),
	FUNCTION	1	btint4cmp (int4, int4),
	FUNCTION	2	ginarrayextract (anyarray, internal, internal),
	FUNCTION	3	ginint4_queryextract (_int4, internal, int2, internal, internal, internal, internal),
	FUNCTION	4	ginint4_consistent (internal, int2, _int4, int4, internal, internal, internal, internal),
	STORAGE		int4;

END IF;

END;
$$;
