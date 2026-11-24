-- =====================================================================
-- pgmig 소스 플러그인 : Oracle (oracle_fdw)  v0.2
--   카탈로그는 foreign table(서브쿼리) 로 읽어서 pgmig.oc_* 로컬 사본을 만든 뒤 정규화
--   ora_dict = all | dba  (dba 는 SELECT ANY DICTIONARY 권한 필요)
--   oracle_fdw 는 foreign table 컬럼을 "순서"로 매칭함 -> stage 테이블은 column_id 순서 그대로 만듦
-- =====================================================================

CREATE FUNCTION pgmig.ora_q(n text) RETURNS text
LANGUAGE sql IMMUTABLE AS $$ SELECT '"' || n || '"' $$;

-- Oracle -> PostgreSQL 타입. NULL = 미지원
CREATE FUNCTION pgmig.ora_type(t text, clen int, prec int, scale int) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
SELECT CASE
  WHEN t IN ('VARCHAR2', 'NVARCHAR2', 'VARCHAR') THEN format('varchar(%s)', greatest(clen, 1))
  WHEN t IN ('CHAR', 'NCHAR')                    THEN format('char(%s)', greatest(clen, 1))
  WHEN t IN ('CLOB', 'NCLOB', 'LONG')            THEN 'text'
  WHEN t IN ('BLOB', 'RAW', 'LONG RAW', 'BFILE') THEN 'bytea'
  WHEN t = 'NUMBER' THEN
    CASE WHEN prec IS NULL THEN 'numeric'
         WHEN coalesce(scale, 0) = 0 THEN
           CASE WHEN prec < 5  THEN 'smallint'
                WHEN prec < 10 THEN 'integer'
                WHEN prec < 19 THEN 'bigint'
                ELSE format('numeric(%s)', prec) END
         WHEN scale BETWEEN 1 AND prec THEN format('numeric(%s,%s)', prec, scale)
         ELSE 'numeric' END
  WHEN t = 'FLOAT'         THEN 'numeric'            -- 정밀도 손실 없게 numeric
  WHEN t = 'BINARY_FLOAT'  THEN 'real'
  WHEN t = 'BINARY_DOUBLE' THEN 'double precision'
  WHEN t = 'DATE'          THEN 'timestamp(0)'       -- 오라클 DATE 는 시분초 포함
  WHEN t ~ '^TIMESTAMP\(\d\) WITH (LOCAL )?TIME ZONE$'
       THEN format('timestamptz(%s)', least(substring(t FROM '\((\d)\)')::int, 6))
  WHEN t ~ '^TIMESTAMP\(\d\)$'
       THEN format('timestamp(%s)', least(substring(t FROM '\((\d)\)')::int, 6))
  WHEN t ~ '^INTERVAL '    THEN 'interval'
  WHEN t ~ '(^|\.)XMLTYPE$' THEN 'xml'
  ELSE NULL END
$$;

-- 따옴표 밖의 부분에만 정규식 치환 적용 (문자열 리터럴은 건드리지 않음)
CREATE FUNCTION pgmig.ora_outside(s text, pat text, rep text, flags text) RETURNS text
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
  parts text[];
  i int;
BEGIN
  IF s IS NULL THEN RETURN NULL; END IF;
  parts := string_to_array(s, '''');
  FOR i IN 1 .. coalesce(array_length(parts, 1), 0) LOOP
    IF i % 2 = 1 THEN parts[i] := regexp_replace(parts[i], pat, rep, flags); END IF;
  END LOOP;
  RETURN array_to_string(parts, '''');
END $$;

-- 정규식 특수문자 이스케이프
CREATE FUNCTION pgmig.re_esc(s text) RETURNS text
LANGUAGE sql IMMUTABLE AS $$ SELECT regexp_replace(s, '([\\.$^*+?()\[\]{}|#])', '\\\1', 'g') $$;

-- 오라클 식(CHECK, 인덱스 식, default, 뷰) -> PostgreSQL 식 : 안전한 치환만
CREATE FUNCTION pgmig.ora_expr(s text, p_owner text DEFAULT NULL) RETURNS text
LANGUAGE plpgsql STABLE AS $$
DECLARE
  r text;
  sch text;
BEGIN
  IF s IS NULL THEN RETURN NULL; END IF;
  -- 소스 스키마 참조 -> target 스키마 ("HR". / HR. 둘 다)
  FOR sch IN SELECT btrim(x) FROM unnest(string_to_array(pgmig.cfg('schemas', ''), ',')) x WHERE btrim(x) <> '' LOOP
    s := pgmig.ora_outside(s, '"' || pgmig.re_esc(sch) || '"\s*\.', quote_ident(pgmig.tgt_schema(sch)) || '.', 'g');
    s := pgmig.ora_outside(s, '(^|[^\w$#"])' || pgmig.re_esc(sch) || '\s*\.', '\1' || quote_ident(pgmig.tgt_schema(sch)) || '.', 'gi');
  END LOOP;
  -- "대문자" 식별자 -> 소문자 (리터럴 안은 제외)
  FOR r IN SELECT DISTINCT m[1] FROM regexp_matches(s, '"([^"]+)"', 'g') AS m LOOP
    s := pgmig.ora_outside(s, '"' || pgmig.re_esc(r) || '"', '"' || pgmig.tgt_name(r) || '"', 'g');
  END LOOP;
  s := pgmig.ora_outside(s, '\msysdate\M', 'LOCALTIMESTAMP(0)', 'gi');
  s := pgmig.ora_outside(s, '\msystimestamp\M', 'CURRENT_TIMESTAMP', 'gi');
  s := pgmig.ora_outside(s, '\mnvl\s*\(', 'coalesce(', 'gi');
  s := pgmig.ora_outside(s, '\mempty_clob\s*\(\s*\)', '''''', 'gi');
  s := pgmig.ora_outside(s, '\mempty_blob\s*\(\s*\)', '''''::bytea', 'gi');
  -- seq.NEXTVAL -> nextval('seq') (스키마 없으면 소유자 스키마를 붙임: default 는 search_path 와 무관하게 동작해야 함)
  s := pgmig.ora_outside(s, '(("?[\w$#]+"?)\s*\.\s*)?("?[\w$#]+"?)\s*\.\s*"?nextval\M"?', 'nextval(''\1\3'')', 'gi');
  s := pgmig.ora_outside(s, '(("?[\w$#]+"?)\s*\.\s*)?("?[\w$#]+"?)\s*\.\s*"?currval\M"?', 'currval(''\1\3'')', 'gi');
  IF p_owner IS NOT NULL THEN
    s := regexp_replace(s, '\m(nextval|currval)\(''("?[\w$#]+"?)''\)',
                        '\1(''' || replace(quote_ident(pgmig.tgt_schema(p_owner)), '\', '\\') || '.\2'')', 'gi');
  END IF;
  RETURN btrim(s);
END $$;

-- default 값: NULL/빈값은 없음으로, 나머지는 변환해서 생성 시도 (실패하면 리포트에 가이드)
CREATE FUNCTION pgmig.ora_default(d text, p_owner text) RETURNS text
LANGUAGE sql STABLE AS $$
SELECT CASE
  WHEN d IS NULL OR btrim(d) = '' OR upper(btrim(d)) = 'NULL' THEN NULL
  WHEN btrim(d) = ''''''                           THEN NULL   -- 오라클의 '' 는 NULL
  ELSE pgmig.ora_expr(btrim(d), p_owner) END
$$;

-- 뷰 원문 -> PostgreSQL
CREATE FUNCTION pgmig.ora_view_text(s text) RETURNS text
LANGUAGE plpgsql STABLE AS $$
BEGIN
  s := pgmig.ora_expr(s);
  s := pgmig.ora_outside(s, '\s+from\s+(sys\s*\.\s*)?dual\M', '', 'gi');
  s := pgmig.ora_outside(s, '\mminus\M', 'EXCEPT', 'gi');
  s := pgmig.ora_outside(s, '\s+with\s+read\s+only(\s+constraint\s+"?[\w$#]+"?)?\s*$', '', 'i');
  s := pgmig.ora_outside(s, '(\s+with\s+check\s+option)\s+constraint\s+"?[\w$#]+"?\s*$', '\1', 'i');
  RETURN btrim(s);
END $$;

-- ---------------------------------------------------------------------
-- 파티션 HIGH_VALUE 변환
-- ---------------------------------------------------------------------
-- 최상위 콤마로 나누기 (괄호/따옴표 안 콤마는 무시)
CREATE FUNCTION pgmig.ora_split(s text) RETURNS text[]
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
  res   text[] := '{}';
  cur   text := '';
  depth int := 0;
  inq   boolean := false;
  ch    text;
  i     int;
BEGIN
  IF s IS NULL THEN RETURN NULL; END IF;
  FOR i IN 1 .. length(s) LOOP
    ch := substr(s, i, 1);
    IF ch = '''' THEN inq := NOT inq;
    ELSIF NOT inq AND ch = '(' THEN depth := depth + 1;
    ELSIF NOT inq AND ch = ')' THEN depth := depth - 1;
    END IF;
    IF ch = ',' AND NOT inq AND depth = 0 THEN
      res := res || btrim(cur); cur := '';
    ELSE
      cur := cur || ch;
    END IF;
  END LOOP;
  RETURN res || btrim(cur);
END $$;

-- 값 하나 -> PostgreSQL 리터럴 (NULL = 변환 불가)
CREATE FUNCTION pgmig.ora_lit(e text) RETURNS text
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
  v text;
BEGIN
  e := btrim(e);
  IF upper(e) IN ('MAXVALUE', 'NULL', 'DEFAULT') THEN RETURN upper(e); END IF;
  IF e ~ '^[-+]?\d+(\.\d+)?([eE][-+]?\d+)?$' THEN RETURN e; END IF;
  IF e ~ '^''([^'']|'''')*''$' THEN RETURN e; END IF;
  -- TO_DATE(' 2020-01-01 00:00:00', 'SYYYY-MM-DD HH24:MI:SS', 'NLS_CALENDAR=GREGORIAN')
  -- TIMESTAMP' 2020-01-01 00:00:00' / TO_TIMESTAMP(...) / TO_TIMESTAMP_TZ(...)
  v := coalesce(substring(e FROM '^(?:TO_DATE|TO_TIMESTAMP|TO_TIMESTAMP_TZ)\s*\(\s*''([^'']*)'''),
                substring(e FROM '^TIMESTAMP\s*''([^'']*)''$'));
  IF v IS NOT NULL AND btrim(v) !~ '^-' THEN RETURN quote_literal(btrim(v)); END IF;
  RETURN NULL;
END $$;

-- RANGE / LIST 경계 -> FOR VALUES 절 (NULL = 변환 불가)
CREATE FUNCTION pgmig.ora_bound(p_type text, p_hv text, p_prev text, p_ncols int) RETURNS text
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
  hi text[];
  lo text[];
BEGIN
  IF p_type = 'LIST' THEN
    IF upper(btrim(p_hv)) = 'DEFAULT' THEN RETURN 'DEFAULT'; END IF;
    IF btrim(p_hv) LIKE '(%' THEN RETURN NULL; END IF;           -- 다중 컬럼 LIST: PostgreSQL 미지원
    SELECT array_agg(pgmig.ora_lit(x)) INTO hi FROM unnest(pgmig.ora_split(p_hv)) x;
    IF array_position(hi, NULL) IS NOT NULL OR 'MAXVALUE' = ANY (hi) THEN RETURN NULL; END IF;
    RETURN 'FOR VALUES IN (' || array_to_string(hi, ', ') || ')';
  ELSIF p_type = 'RANGE' THEN
    SELECT array_agg(pgmig.ora_lit(x)) INTO hi FROM unnest(pgmig.ora_split(p_hv)) x;
    IF p_prev IS NULL THEN
      lo := array_fill('MINVALUE'::text, ARRAY[p_ncols]);
    ELSE
      SELECT array_agg(pgmig.ora_lit(x)) INTO lo FROM unnest(pgmig.ora_split(p_prev)) x;
    END IF;
    IF array_position(hi, NULL) IS NOT NULL OR array_position(lo, NULL) IS NOT NULL
       OR cardinality(hi) <> p_ncols OR cardinality(lo) <> p_ncols
       OR 'NULL' = ANY (hi) OR 'NULL' = ANY (lo) THEN RETURN NULL; END IF;
    RETURN 'FOR VALUES FROM (' || array_to_string(lo, ', ') || ') TO (' || array_to_string(hi, ', ') || ')';
  END IF;
  RETURN NULL;
END $$;

-- ---------------------------------------------------------------------
-- 카탈로그용 foreign table 생성 (@D@ -> all/dba, @S@ -> 'HR','SCOTT')
-- ---------------------------------------------------------------------
CREATE FUNCTION pgmig.ora_schema_list() RETURNS text LANGUAGE plpgsql STABLE AS $$
DECLARE
  v text;
BEGIN
  SELECT string_agg(quote_literal(btrim(s)), ',') INTO v
    FROM unnest(string_to_array(pgmig.cfg('schemas', ''), ',')) s WHERE btrim(s) <> '';
  IF v IS NULL THEN RAISE EXCEPTION 'SRC_SCHEMAS 가 비어 있음'; END IF;
  IF EXISTS (SELECT FROM unnest(string_to_array(pgmig.cfg('schemas', ''), ',')) s
              WHERE btrim(s) <> '' AND btrim(s) !~ '^[A-Za-z0-9_$#]+$') THEN
    RAISE EXCEPTION 'SRC_SCHEMAS 에 허용되지 않는 문자가 있음: %', pgmig.cfg('schemas');
  END IF;
  RETURN v;
END $$;

CREATE PROCEDURE pgmig.ora_ft(p_name text, p_cols text, p_query text, p_max_long int DEFAULT 32767) LANGUAGE plpgsql AS $$
DECLARE
  d text := lower(pgmig.cfg('ora_dict', 'all'));
BEGIN
  IF d NOT IN ('all', 'dba') THEN RAISE EXCEPTION 'ORA_DICT 는 all 또는 dba'; END IF;
  EXECUTE format('DROP FOREIGN TABLE IF EXISTS pgmig.%I', p_name);
  EXECUTE format('CREATE FOREIGN TABLE pgmig.%I (%s) SERVER pgmig_src OPTIONS (table %L, max_long %L, readonly ''true'')',
                 p_name, p_cols,
                 '(' || replace(replace(p_query, '@D@', d), '@S@', pgmig.ora_schema_list()) || ')',
                 p_max_long::text);
END $$;

-- 일관 읽기용 SCN (ORA_USE_SCN=on 일 때만). 한 번 구하면 config 에 고정
CREATE FUNCTION pgmig.ora_scn() RETURNS text LANGUAGE plpgsql AS $$
DECLARE
  v text;
BEGIN
  IF pgmig.cfg('ora_use_scn', 'off') <> 'on' THEN RETURN NULL; END IF;
  v := pgmig.cfg('ora_scn');
  IF v IS NULL THEN
    CALL pgmig.ora_ft('ora_scn_q', 'scn numeric', 'SELECT timestamp_to_scn(systimestamp) FROM dual');
    SELECT scn::text INTO v FROM pgmig.ora_scn_q;
    INSERT INTO pgmig.config VALUES ('ora_scn', v)
    ON CONFLICT (key) DO UPDATE SET value = excluded.value;
  END IF;
  IF v !~ '^\d+$' THEN RAISE EXCEPTION 'SCN 값이 이상함: %', v; END IF;
  RETURN v;
END $$;

-- 소스 테이블 FROM 절 ("OWNER"."TABLE" [AS OF SCN n])
CREATE FUNCTION pgmig.ora_from(p_table int) RETURNS text LANGUAGE sql AS $$
SELECT pgmig.ora_q(src_schema) || '.' || pgmig.ora_q(src_table)
       || coalesce(' AS OF SCN ' || pgmig.ora_scn(), '')
  FROM pgmig.tables WHERE id = p_table
$$;

-- 소스 DB 에서 집계 쿼리를 직접 실행 (oracle_fdw 는 집계를 push down 하지 않음)
CREATE FUNCTION pgmig.ora_scalar3(p_query text, OUT a numeric, OUT b numeric, OUT c numeric)
LANGUAGE plpgsql AS $$
DECLARE
  n text := 'q_' || pg_backend_pid();
BEGIN
  EXECUTE format('DROP FOREIGN TABLE IF EXISTS pgmig_stage.%I', n);
  EXECUTE format('CREATE FOREIGN TABLE pgmig_stage.%I (a numeric, b numeric, c numeric) SERVER pgmig_src OPTIONS (table %L, readonly ''true'')',
                 n, '(' || p_query || ')');
  EXECUTE format('SELECT a, b, c FROM pgmig_stage.%I', n) INTO a, b, c;
  EXECUTE format('DROP FOREIGN TABLE pgmig_stage.%I', n);
END $$;

CREATE FUNCTION pgmig.ora_src_col(p_table int, p_tgt_col text) RETURNS text
LANGUAGE sql STABLE AS
$$ SELECT pgmig.ora_q(src_col) FROM pgmig.columns WHERE table_id = p_table AND tgt_col = p_tgt_col $$;

-- 분할 컬럼 식 (오라클 쪽). time 은 epoch 초 (초 미만은 버림 -> 경계 계산용이라 상관없음)
CREATE FUNCTION pgmig.ora_split_expr(p_table int, p_col text, p_kind text) RETURNS text
LANGUAGE sql STABLE AS $$
SELECT CASE
  WHEN p_kind IS DISTINCT FROM 'time' THEN pgmig.ora_src_col(p_table, p_col)
  WHEN c.tgt_type ~ '^timestamptz'
    THEN format('((CAST(SYS_EXTRACT_UTC(%s) AS DATE) - DATE ''1970-01-01'') * 86400)', pgmig.ora_src_col(p_table, p_col))
  ELSE format('((CAST(%s AS DATE) - DATE ''1970-01-01'') * 86400)', pgmig.ora_src_col(p_table, p_col)) END
  FROM pgmig.columns c WHERE c.table_id = p_table AND c.tgt_col = p_col
$$;

-- 경계값 리터럴 (오라클 쪽). pgmig.cond 의 PG 쪽 조건과 같은 시각을 가리켜야 함
--   DATE(-> timestamp(0)) 컬럼은 TO_DATE (TIMESTAMP 리터럴과 비교하면 DATE 컬럼이 변환돼서 인덱스를 못 탐)
--   DATE 값은 초 단위라 col >= x  ==  col >= ceil(x)
CREATE FUNCTION pgmig.ora_bound_lit(p_table int, p_col text, p_kind text, p_v numeric) RETURNS text
LANGUAGE sql STABLE AS $$
SELECT CASE
  WHEN p_kind IS DISTINCT FROM 'time' THEN p_v::text
  WHEN c.tgt_type ~ '^timestamptz'
    THEN format('TIMESTAMP ''%s +00:00''', to_char(pgmig.epoch_ts(p_v), 'YYYY-MM-DD HH24:MI:SS.US'))
  WHEN c.tgt_type ~ '^timestamp\(0\)'
    THEN format('TO_DATE(''%s'', ''YYYY-MM-DD HH24:MI:SS'')', to_char(pgmig.epoch_ts(ceil(p_v)), 'YYYY-MM-DD HH24:MI:SS'))
  ELSE format('TIMESTAMP ''%s''', to_char(pgmig.epoch_ts(p_v), 'YYYY-MM-DD HH24:MI:SS.US')) END
  FROM pgmig.columns c WHERE c.table_id = p_table AND c.tgt_col = p_col
$$;

-- pgmig.cond 의 오라클 버전 (소스에서 직접 count 할 때)
CREATE FUNCTION pgmig.ora_cond(p_table int, p_col text, p_lo numeric, p_hi numeric, p_kind text) RETURNS text
LANGUAGE sql STABLE AS $$
SELECT coalesce(nullif(concat_ws(' AND ',
  CASE WHEN c IS NOT NULL AND p_lo IS NOT NULL THEN format('%s >= %s', c, pgmig.ora_bound_lit(p_table, p_col, p_kind, p_lo)) END,
  CASE WHEN c IS NOT NULL AND p_hi IS NOT NULL THEN
       CASE WHEN p_kind IS NOT NULL AND p_lo IS NULL
            THEN format('(%s < %s OR %s IS NULL)', c, pgmig.ora_bound_lit(p_table, p_col, p_kind, p_hi), c)
            ELSE format('%s < %s', c, pgmig.ora_bound_lit(p_table, p_col, p_kind, p_hi)) END END), ''), '1 = 1')
  FROM (SELECT pgmig.ora_src_col(p_table, p_col) AS c) x
$$;

CREATE FUNCTION pgmig.src_oracle_stats(p_table int, p_pk text, p_from numeric DEFAULT NULL, p_kind text DEFAULT NULL,
                                       OUT lo numeric, OUT hi numeric, OUT cnt bigint)
LANGUAGE plpgsql AS $$
DECLARE
  e text := pgmig.ora_split_expr(p_table, p_pk, p_kind);
BEGIN
  SELECT a, b, s.c::bigint INTO lo, hi, cnt
    FROM pgmig.ora_scalar3(format('SELECT MIN(%s), MAX(%s), COUNT(*) FROM %s WHERE %s', e, e, pgmig.ora_from(p_table),
                                  CASE WHEN p_from IS NULL THEN '1 = 1'
                                       ELSE pgmig.ora_cond(p_table, p_pk, p_from, NULL, p_kind) END)) s;
END $$;

CREATE FUNCTION pgmig.src_oracle_count(p_table int, p_pk text, p_lo numeric, p_hi numeric, p_kind text DEFAULT NULL)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE
  r bigint;
BEGIN
  SELECT a::bigint INTO r
    FROM pgmig.ora_scalar3(format('SELECT COUNT(*), 0, 0 FROM %s WHERE %s', pgmig.ora_from(p_table),
                                  CASE WHEN p_pk IS NULL THEN '1 = 1'
                                       ELSE pgmig.ora_cond(p_table, p_pk, p_lo, p_hi, p_kind) END));
  RETURN r;
END $$;

-- 분위수 경계: 오라클에서 NTILE 로 계산해 경계값만 가져옴 (분할 컬럼 1회 정렬 스캔)
--   ORA_USE_SCN 이면 같은 SCN 기준. n 개 버킷 시작값 중 첫 번째를 뺀 값들. NULL 은 제외(첫 청크에 들어감)
CREATE FUNCTION pgmig.src_oracle_bounds(p_table int, p_pk text, p_n int, p_kind text DEFAULT NULL) RETURNS numeric[]
LANGUAGE plpgsql AS $$
DECLARE
  c   text := pgmig.ora_src_col(p_table, p_pk);
  e   text := pgmig.ora_split_expr(p_table, p_pk, p_kind);
  nm  text := 'qb_' || pg_backend_pid();
  q   text;
  r   numeric[];
BEGIN
  q := format('SELECT MIN(v) AS b FROM (SELECT %1$s AS v, NTILE(%2$s) OVER (ORDER BY %3$s) AS t FROM %4$s WHERE %3$s IS NOT NULL) GROUP BY t',
              e, p_n, c, pgmig.ora_from(p_table));
  EXECUTE format('DROP FOREIGN TABLE IF EXISTS pgmig_stage.%I', nm);
  EXECUTE format('CREATE FOREIGN TABLE pgmig_stage.%I (b numeric) SERVER pgmig_src OPTIONS (table %L, readonly ''true'')',
                 nm, '(' || q || ')');
  EXECUTE format('SELECT array_agg(DISTINCT b ORDER BY b) FROM pgmig_stage.%I', nm) INTO r;
  EXECUTE format('DROP FOREIGN TABLE pgmig_stage.%I', nm);
  RETURN r[2:];
END $$;

-- stage foreign table DDL (컬럼은 column_id 순서 = oracle_fdw 매칭 순서)
CREATE FUNCTION pgmig.src_oracle_stage_sql(p_table int) RETURNS text LANGUAGE plpgsql AS $$
DECLARE
  t       pgmig.tables;
  v_strip boolean := pgmig.cfg('ora_strip_zeros', 'off') = 'on';
  v_scn   text    := pgmig.ora_scn();
  v_cols  text;
  v_opts  text;
BEGIN
  SELECT * INTO t FROM pgmig.tables WHERE id = p_table;
  SELECT string_agg(format('%I %s%s', tgt_col, tgt_type,
           CASE WHEN v_strip AND tgt_type ~ '^(varchar|char|text)' THEN ' OPTIONS (strip_zeros ''true'')' ELSE '' END),
           ', ' ORDER BY pos)
    INTO v_cols FROM pgmig.columns WHERE table_id = p_table;

  IF v_scn IS NULL THEN
    v_opts := format('schema %L, table %L', t.src_schema, t.src_table);
  ELSE
    v_opts := format('table %L', format('(SELECT %s FROM %s)',
                (SELECT string_agg(pgmig.ora_q(src_col), ', ' ORDER BY pos) FROM pgmig.columns WHERE table_id = p_table),
                pgmig.ora_from(p_table)));
  END IF;
  v_opts := v_opts || format(', readonly ''true'', prefetch %L, max_long %L',
                             pgmig.cfg('ora_prefetch', '1000'), pgmig.cfg('ora_max_long', '32767'));
  IF pgmig.cfg('ora_lob_prefetch') IS NOT NULL THEN
    v_opts := v_opts || format(', lob_prefetch %L', pgmig.cfg('ora_lob_prefetch'));
  END IF;
  RETURN format('CREATE FOREIGN TABLE pgmig_stage.%I (%s) SERVER pgmig_src OPTIONS (%s)',
                't' || p_table, v_cols, v_opts);
END $$;

-- ---------------------------------------------------------------------
-- 카탈로그 수집: 오라클 딕셔너리 -> pgmig.ora_* (foreign) -> pgmig.oc_* (로컬 사본)
-- ---------------------------------------------------------------------
CREATE PROCEDURE pgmig.ora_fetch_catalog() LANGUAGE plpgsql AS $body$
DECLARE
  r record;
BEGIN
  CALL pgmig.ora_ft('ora_tables',
    'owner text, table_name text, num_rows numeric, partitioned text, temporary text',
    $o$SELECT t.owner, t.table_name, t.num_rows, t.partitioned, t.temporary
         FROM @D@_tables t
        WHERE t.owner IN (@S@)
          AND t.secondary = 'N' AND t.nested = 'NO' AND t.dropped = 'NO'
          AND (t.iot_type IS NULL OR t.iot_type = 'IOT')
          AND (t.owner, t.table_name) NOT IN (SELECT owner, mview_name FROM @D@_mviews)
          AND (t.owner, t.table_name) NOT IN (SELECT log_owner, log_table FROM @D@_mview_logs)$o$);

  CALL pgmig.ora_ft('ora_columns',
    'owner text, table_name text, column_name text, column_id numeric, data_type text, char_length numeric, '
    'data_precision numeric, data_scale numeric, nullable text, virtual_column text, data_default text',
    $o$SELECT c.owner, c.table_name, c.column_name, c.column_id,
              CASE WHEN c.data_type_owner IS NULL THEN c.data_type
                   ELSE c.data_type_owner || '.' || c.data_type END,
              c.char_length, c.data_precision, c.data_scale, c.nullable, c.virtual_column, c.data_default
         FROM @D@_tab_cols c
        WHERE c.owner IN (@S@) AND c.hidden_column = 'NO' AND c.column_id IS NOT NULL$o$);

  CALL pgmig.ora_ft('ora_keys',
    'owner text, table_name text, constraint_name text, constraint_type text, status text, validated text, '
    '"deferrable" text, deferred text, column_name text, position numeric',
    $o$SELECT con.owner, con.table_name, con.constraint_name, con.constraint_type, con.status, con.validated,
              con.deferrable, con.deferred, col.column_name, col.position
         FROM @D@_constraints con
         JOIN @D@_cons_columns col
           ON con.owner = col.owner AND con.table_name = col.table_name AND con.constraint_name = col.constraint_name
        WHERE con.owner IN (@S@) AND con.constraint_type IN ('P', 'U')$o$);

  CALL pgmig.ora_ft('ora_fkeys',
    'owner text, table_name text, constraint_name text, status text, validated text, "deferrable" text, deferred text, '
    'delete_rule text, column_name text, position numeric, r_owner text, r_table text, r_column text',
    $o$SELECT con.owner, con.table_name, con.constraint_name, con.status, con.validated, con.deferrable, con.deferred,
              con.delete_rule, col.column_name, col.position, r_col.owner, r_col.table_name, r_col.column_name
         FROM @D@_constraints con
         JOIN @D@_cons_columns col
           ON con.owner = col.owner AND con.table_name = col.table_name AND con.constraint_name = col.constraint_name
         JOIN @D@_cons_columns r_col
           ON con.r_owner = r_col.owner AND con.r_constraint_name = r_col.constraint_name AND col.position = r_col.position
        WHERE con.owner IN (@S@) AND con.constraint_type = 'R'$o$);

  CALL pgmig.ora_ft('ora_checks',
    'owner text, table_name text, constraint_name text, status text, validated text, "deferrable" text, deferred text, '
    'search_condition text',
    $o$SELECT con.owner, con.table_name, con.constraint_name, con.status, con.validated, con.deferrable, con.deferred,
              con.search_condition
         FROM @D@_constraints con
        WHERE con.owner IN (@S@) AND con.constraint_type = 'C'$o$);

  CALL pgmig.ora_ft('ora_indexes',
    'table_owner text, table_name text, index_name text, index_type text, uniqueness text, position numeric, '
    'descend text, column_name text, column_expression text',
    $o$SELECT ic.table_owner, ic.table_name, ic.index_name, i.index_type, i.uniqueness, ic.column_position,
              ic.descend, ic.column_name, ie.column_expression
         FROM @D@_indexes i, @D@_ind_columns ic, @D@_ind_expressions ie
        WHERE i.table_owner IN (@S@)
          AND i.owner            = ic.index_owner
          AND i.index_name       = ic.index_name
          AND i.table_owner      = ic.table_owner
          AND i.table_name       = ic.table_name
          AND ic.index_owner     = ie.index_owner(+)
          AND ic.index_name      = ie.index_name(+)
          AND ic.table_owner     = ie.table_owner(+)
          AND ic.table_name      = ie.table_name(+)
          AND ic.column_position = ie.column_position(+)
          AND i.index_type NOT IN ('LOB', 'DOMAIN', 'IOT - TOP', 'CLUSTER')
          AND NOT EXISTS (SELECT 1 FROM @D@_constraints c
                           WHERE c.owner = i.table_owner AND c.table_name = i.table_name
                             AND COALESCE(c.index_owner, i.owner) = i.owner
                             AND c.index_name = i.index_name)$o$);

  CALL pgmig.ora_ft('ora_sequences',
    'sequence_owner text, sequence_name text, min_value numeric, max_value numeric, increment_by numeric, '
    'cycle_flag text, cache_size numeric, last_number numeric',
    $o$SELECT sequence_owner, sequence_name, min_value, max_value, increment_by, cycle_flag, cache_size, last_number
         FROM @D@_sequences WHERE sequence_owner IN (@S@)$o$);

  CALL pgmig.ora_ft('ora_objects',
    'owner text, object_type text, object_name text',
    $o$SELECT owner, object_type, object_name
         FROM @D@_objects
        WHERE owner IN (@S@) AND generated = 'N'
          AND object_type IN ('PROCEDURE', 'FUNCTION', 'PACKAGE', 'TRIGGER', 'SYNONYM', 'TYPE',
                              'MATERIALIZED VIEW', 'JOB', 'DATABASE LINK')$o$);

  CALL pgmig.ora_ft('ora_tab_comments',
    'owner text, table_name text, comments text',
    $o$SELECT owner, table_name, comments FROM @D@_tab_comments
        WHERE owner IN (@S@) AND table_type = 'TABLE' AND comments IS NOT NULL$o$);

  CALL pgmig.ora_ft('ora_col_comments',
    'owner text, table_name text, column_name text, comments text',
    $o$SELECT owner, table_name, column_name, comments FROM @D@_col_comments
        WHERE owner IN (@S@) AND comments IS NOT NULL$o$);

  CALL pgmig.ora_ft('ora_views',
    'owner text, view_name text, text text',
    $o$SELECT owner, view_name, text FROM @D@_views WHERE owner IN (@S@)$o$,
    greatest(pgmig.cfg('ora_max_long', '32767')::int, 1048576));

  CALL pgmig.ora_ft('ora_part_tables',
    'owner text, table_name text, partitioning_type text, subpartitioning_type text, interval text',
    $o$SELECT owner, table_name, partitioning_type, subpartitioning_type, interval
         FROM @D@_part_tables WHERE owner IN (@S@)$o$);

  CALL pgmig.ora_ft('ora_part_keys',
    'owner text, name text, lvl text, column_name text, column_position numeric',
    $o$SELECT owner, name, 'P', column_name, column_position FROM @D@_part_key_columns
        WHERE owner IN (@S@) AND TRIM(object_type) = 'TABLE'
       UNION ALL
       SELECT owner, name, 'S', column_name, column_position FROM @D@_subpart_key_columns
        WHERE owner IN (@S@) AND TRIM(object_type) = 'TABLE'$o$);

  CALL pgmig.ora_ft('ora_partitions',
    'table_owner text, table_name text, partition_name text, partition_position numeric, high_value text',
    $o$SELECT table_owner, table_name, partition_name, partition_position, high_value
         FROM @D@_tab_partitions WHERE table_owner IN (@S@)$o$);

  CALL pgmig.ora_ft('ora_subpartitions',
    'table_owner text, table_name text, partition_name text, subpartition_name text, subpartition_position numeric, high_value text',
    $o$SELECT table_owner, table_name, partition_name, subpartition_name, subpartition_position, high_value
         FROM @D@_tab_subpartitions WHERE table_owner IN (@S@)$o$);

  -- 로컬 사본 (이후 조인은 전부 로컬에서)
  FOR r IN SELECT unnest(ARRAY['tables', 'columns', 'keys', 'fkeys', 'checks', 'indexes', 'sequences', 'objects',
                               'tab_comments', 'col_comments', 'views', 'part_tables', 'part_keys',
                               'partitions', 'subpartitions']) AS n LOOP
    EXECUTE format('DROP TABLE IF EXISTS pgmig.%I', 'oc_' || r.n);
    EXECUTE format('CREATE TABLE pgmig.%I AS SELECT * FROM pgmig.%I', 'oc_' || r.n, 'ora_' || r.n);
  END LOOP;

  -- identity 컬럼 (12c+. 11g 에는 뷰가 없으니 실패해도 계속)
  DROP TABLE IF EXISTS pgmig.oc_identity;
  BEGIN
    CALL pgmig.ora_ft('ora_identity',
      'owner text, table_name text, column_name text, generation_type text, sequence_name text',
      $o$SELECT owner, table_name, column_name, generation_type, sequence_name
           FROM @D@_tab_identity_cols WHERE owner IN (@S@)$o$);
    CREATE TABLE pgmig.oc_identity AS SELECT * FROM pgmig.ora_identity;
  EXCEPTION WHEN OTHERS THEN
    CREATE TABLE pgmig.oc_identity (owner text, table_name text, column_name text, generation_type text, sequence_name text);
    INSERT INTO pgmig.issues (level, object, msg) VALUES ('INFO', NULL, 'identity 컬럼 정보 조회 불가 (11g 이하?): ' || SQLERRM);
  END;
END $body$;

-- 정규화: oc_* -> pgmig.tables/columns/...
CREATE PROCEDURE pgmig.ora_normalize() LANGUAGE plpgsql AS $body$
DECLARE
  pt      record;
  p       record;
  sp      record;
  v_keys  text[];
  v_sub   text[];
  v_prev  text;
  v_sprev text;
  v_bound text;
  v_cnt   int;
  v_fail  text;
  v_pname text;
  v_part_on boolean := pgmig.cfg('ora_partitions', 'on') = 'on';
BEGIN
  IF NOT EXISTS (SELECT FROM pgmig.oc_tables) THEN
    RAISE EXCEPTION '소스에서 테이블을 하나도 못 읽음 (SRC_SCHEMAS 대문자 확인, 접속 유저의 SELECT 권한 확인)';
  END IF;

  -- tables (GTT 는 제외)
  INSERT INTO pgmig.tables (src_schema, src_table, tgt_schema, tgt_table, est_rows)
  SELECT owner, table_name, pgmig.tgt_schema(owner), pgmig.tgt_name(table_name), num_rows::bigint
    FROM pgmig.oc_tables WHERE temporary = 'N' ORDER BY owner, table_name;

  INSERT INTO pgmig.issues (level, object, msg)
  SELECT 'MANUAL', owner || '.' || table_name,
         'GTT(Global Temporary Table): 이관 안 함. 가이드: PostgreSQL 임시테이블은 세션마다 CREATE 해야 함 '
         || '-> 애플리케이션에서 CREATE TEMP TABLE 하거나 일반 테이블+세션키 컬럼으로 설계 변경'
    FROM pgmig.oc_tables WHERE temporary = 'Y';

  -- columns
  INSERT INTO pgmig.columns (table_id, pos, src_col, tgt_col, src_type, tgt_type, not_null, src_default, tgt_default)
  SELECT t.id, c.column_id::int, c.column_name, pgmig.tgt_name(c.column_name),
         c.data_type || CASE WHEN c.data_type IN ('VARCHAR2', 'NVARCHAR2', 'CHAR', 'NCHAR') THEN '(' || c.char_length || ')'
                             WHEN c.data_type = 'NUMBER' AND c.data_precision IS NOT NULL
                                  THEN '(' || c.data_precision || ',' || coalesce(c.data_scale, 0) || ')'
                             ELSE '' END,
         pgmig.ora_type(c.data_type, c.char_length::int, c.data_precision::int, c.data_scale::int),
         c.nullable = 'N',
         nullif(btrim(c.data_default), ''),
         CASE WHEN c.virtual_column = 'NO' THEN pgmig.ora_default(c.data_default, c.owner) END
    FROM pgmig.oc_columns c
    JOIN pgmig.tables t ON t.src_schema = c.owner AND t.src_table = c.table_name;

  -- identity
  UPDATE pgmig.columns c
     SET identity = CASE WHEN i.generation_type = 'ALWAYS' THEN 'ALWAYS' ELSE 'BY DEFAULT' END,
         identity_start = s.last_number,
         tgt_default = NULL
    FROM pgmig.oc_identity i
    JOIN pgmig.tables t ON t.src_schema = i.owner AND t.src_table = i.table_name
    LEFT JOIN pgmig.oc_sequences s ON s.sequence_owner = i.owner AND s.sequence_name = i.sequence_name
   WHERE c.table_id = t.id AND c.src_col = i.column_name;

  -- PostgreSQL identity 는 정수 타입만 가능 (오라클 identity 는 보통 정밀도 없는 NUMBER)
  INSERT INTO pgmig.issues (level, object, msg)
  SELECT 'INFO', t.src_schema || '.' || t.src_table || '.' || c.src_col,
         'identity 컬럼 ' || c.src_type || ' -> bigint (PostgreSQL identity 는 정수 타입만 가능)'
    FROM pgmig.columns c JOIN pgmig.tables t ON t.id = c.table_id
   WHERE c.identity IS NOT NULL AND c.tgt_type !~ '^(smallint|integer|bigint)$';
  UPDATE pgmig.columns SET tgt_type = 'bigint'
   WHERE identity IS NOT NULL AND tgt_type !~ '^(smallint|integer|bigint)$';

  INSERT INTO pgmig.issues (level, object, msg)
  SELECT 'MANUAL', c.owner || '.' || c.table_name || '.' || c.column_name,
         '가상 컬럼 -> 값만 일반 컬럼으로 이관됨. 가이드: 생성 컬럼으로 바꾸려면 '
         || 'ALTER TABLE ' || pgmig.rel(t.id) || ' DROP COLUMN ' || quote_ident(pgmig.tgt_name(c.column_name))
         || '; ALTER TABLE ' || pgmig.rel(t.id) || ' ADD COLUMN ' || quote_ident(pgmig.tgt_name(c.column_name))
         || ' <타입> GENERATED ALWAYS AS (' || coalesce(pgmig.ora_expr(btrim(c.data_default)), '?') || ') STORED;'
    FROM pgmig.oc_columns c JOIN pgmig.tables t ON t.src_schema = c.owner AND t.src_table = c.table_name
   WHERE c.virtual_column = 'YES';

  INSERT INTO pgmig.issues (level, object, msg)
  SELECT 'WARN', c.owner || '.' || c.table_name || '.' || c.column_name,
         c.data_type || ': PostgreSQL 은 마이크로초(6자리)까지 -> 초 이하 7자리부터 반올림됨 (full 검증도 같은 값으로 봄)'
    FROM pgmig.oc_columns c JOIN pgmig.tables t ON t.src_schema = c.owner AND t.src_table = c.table_name
   WHERE c.data_type ~ '^TIMESTAMP\([7-9]\)';

  INSERT INTO pgmig.issues (level, object, msg)
  SELECT 'INFO', c.owner || '.' || c.table_name || '.' || c.column_name,
         CASE WHEN c.data_type = 'FLOAT' THEN 'FLOAT -> numeric (손실 방지). 필요하면 이관 후 double precision 으로 변경'
              WHEN c.data_type ~ 'TIME ZONE' THEN c.data_type || ' -> timestamptz (시각은 동일, 원래 타임존 표기는 보존 안 됨)'
              WHEN c.data_type = 'BFILE' THEN 'BFILE -> bytea (파일 내용을 읽어서 저장)'
              ELSE c.data_type || ': ORA_MAX_LONG 보다 긴 값이 있으면 ORA-01406 으로 청크 실패 -> 값 올려서 data 재실행' END
    FROM pgmig.oc_columns c JOIN pgmig.tables t ON t.src_schema = c.owner AND t.src_table = c.table_name
   WHERE c.data_type IN ('FLOAT', 'BFILE', 'LONG', 'LONG RAW')
      OR c.data_type ~ 'TIME ZONE' OR c.data_type ~ '(^|\.)XMLTYPE$';

  -- 비활성(DISABLED) 제약: 만들지 않음
  INSERT INTO pgmig.issues (level, object, msg)
  SELECT 'MANUAL', x.owner || '.' || x.table_name || '.' || x.constraint_name,
         '비활성(DISABLED) ' || x.kind || ' 제약 -> 생성 안 함. 필요하면 데이터 확인 후 수동 생성'
    FROM (SELECT DISTINCT owner, table_name, constraint_name, CASE constraint_type WHEN 'P' THEN 'PK' ELSE 'UNIQUE' END kind
            FROM pgmig.oc_keys WHERE status <> 'ENABLED'
          UNION ALL SELECT DISTINCT owner, table_name, constraint_name, 'FK' FROM pgmig.oc_fkeys WHERE status <> 'ENABLED'
          UNION ALL SELECT owner, table_name, constraint_name, 'CHECK' FROM pgmig.oc_checks
                     WHERE status <> 'ENABLED' AND btrim(search_condition) !~ '^"[^"]+" IS NOT NULL$') x
    JOIN pgmig.tables t ON t.src_schema = x.owner AND t.src_table = x.table_name;

  -- PK / UK
  INSERT INTO pgmig.constraints (table_id, name, ctype, cols, validated, can_defer, init_defer)
  SELECT t.id, pgmig.tgt_name(k.constraint_name), lower(k.constraint_type),
         array_agg(pgmig.tgt_name(k.column_name) ORDER BY k.position),
         bool_and(k.validated = 'VALIDATED'), bool_and(k.deferrable = 'DEFERRABLE'), bool_and(k.deferred = 'DEFERRED')
    FROM pgmig.oc_keys k JOIN pgmig.tables t ON t.src_schema = k.owner AND t.src_table = k.table_name
   WHERE k.status = 'ENABLED'
   GROUP BY t.id, k.constraint_name, k.constraint_type;

  -- FK
  INSERT INTO pgmig.constraints (table_id, name, ctype, cols, ref_schema, ref_table, ref_cols, on_delete,
                                 validated, can_defer, init_defer)
  SELECT t.id, pgmig.tgt_name(f.constraint_name), 'f',
         array_agg(pgmig.tgt_name(f.column_name) ORDER BY f.position),
         f.r_owner, f.r_table,
         array_agg(pgmig.tgt_name(f.r_column) ORDER BY f.position),
         max(f.delete_rule),
         bool_and(f.validated = 'VALIDATED'), bool_and(f.deferrable = 'DEFERRABLE'), bool_and(f.deferred = 'DEFERRED')
    FROM pgmig.oc_fkeys f JOIN pgmig.tables t ON t.src_schema = f.owner AND t.src_table = f.table_name
   WHERE f.status = 'ENABLED'
   GROUP BY t.id, f.constraint_name, f.r_owner, f.r_table;

  -- CHECK ("COL" IS NOT NULL 형태는 NOT NULL 로 이미 반영되므로 제외)
  INSERT INTO pgmig.constraints (table_id, name, ctype, expr, validated, can_defer, init_defer)
  SELECT t.id, pgmig.tgt_name(c.constraint_name), 'c', pgmig.ora_expr(c.search_condition),
         c.validated = 'VALIDATED', c.deferrable = 'DEFERRABLE', c.deferred = 'DEFERRED'
    FROM pgmig.oc_checks c JOIN pgmig.tables t ON t.src_schema = c.owner AND t.src_table = c.table_name
   WHERE c.status = 'ENABLED' AND c.search_condition IS NOT NULL
     AND btrim(c.search_condition) !~ '^"[^"]+" IS NOT NULL$';

  -- 인덱스: DESC 컬럼은 오라클에서 "COL" 식으로 저장됨 -> 컬럼으로. 그 외 식은 변환해서 시도
  INSERT INTO pgmig.indexes (table_id, name, is_unique, cols, exprs, descs)
  SELECT t.id, pgmig.tgt_name(i.index_name), bool_or(i.uniqueness = 'UNIQUE'),
         array_agg(CASE WHEN i.column_expression IS NULL THEN pgmig.tgt_name(i.column_name)
                        WHEN btrim(i.column_expression) ~ '^"[^"]+"$'
                             THEN pgmig.tgt_name(substring(btrim(i.column_expression) FROM '^"([^"]+)"$')) END
                   ORDER BY i.position),
         array_agg(CASE WHEN i.column_expression IS NOT NULL AND btrim(i.column_expression) !~ '^"[^"]+"$'
                        THEN pgmig.ora_expr(btrim(i.column_expression)) END ORDER BY i.position),
         array_agg(i.descend = 'DESC' ORDER BY i.position)
    FROM pgmig.oc_indexes i JOIN pgmig.tables t ON t.src_schema = i.table_owner AND t.src_table = i.table_name
   GROUP BY t.id, i.index_name;

  INSERT INTO pgmig.issues (level, object, msg)
  SELECT DISTINCT 'INFO', i.table_owner || '.' || i.table_name || '.' || i.index_name,
         i.index_type || ' 인덱스 -> btree 로 생성'
    FROM pgmig.oc_indexes i JOIN pgmig.tables t ON t.src_schema = i.table_owner AND t.src_table = i.table_name
   WHERE i.index_type NOT IN ('NORMAL', 'FUNCTION-BASED NORMAL');

  -- 시퀀스 (last_number = 캐시분까지 반영된 다음 값이라 그대로 START 로 써도 중복 없음)
  INSERT INTO pgmig.sequences (src_schema, name, tgt_schema, inc, minv, maxv, startv, cache, cycle)
  SELECT sequence_owner, pgmig.tgt_name(sequence_name), pgmig.tgt_schema(sequence_owner),
         increment_by, min_value, max_value, last_number, cache_size, cycle_flag = 'Y'
    FROM pgmig.oc_sequences
   WHERE sequence_name NOT LIKE 'ISEQ$$%';

  -- 코멘트
  INSERT INTO pgmig.comments (table_id, col, txt)
  SELECT t.id, NULL, c.comments
    FROM pgmig.oc_tab_comments c JOIN pgmig.tables t ON t.src_schema = c.owner AND t.src_table = c.table_name;
  INSERT INTO pgmig.comments (table_id, col, txt)
  SELECT t.id, pgmig.tgt_name(c.column_name), c.comments
    FROM pgmig.oc_col_comments c JOIN pgmig.tables t ON t.src_schema = c.owner AND t.src_table = c.table_name;

  -- 뷰 (컬럼 목록을 명시해서 오라클 별칭/대소문자 차이를 없앰)
  INSERT INTO pgmig.views (src_schema, src_view, tgt_schema, tgt_view, cols, src_text, sql)
  SELECT v.owner, v.view_name, pgmig.tgt_schema(v.owner), pgmig.tgt_name(v.view_name), vc.cols, v.text,
         format('CREATE VIEW %I.%I (%s) AS %s', pgmig.tgt_schema(v.owner), pgmig.tgt_name(v.view_name),
                pgmig.qcols(vc.cols), pgmig.ora_view_text(v.text))
    FROM pgmig.oc_views v
    LEFT JOIN LATERAL (SELECT array_agg(pgmig.tgt_name(c.column_name) ORDER BY c.column_id) cols
                         FROM pgmig.oc_columns c WHERE c.owner = v.owner AND c.table_name = v.view_name) vc ON true
   ORDER BY v.owner, v.view_name;

  INSERT INTO pgmig.issues (level, object, msg)
  SELECT 'INFO', v.owner || '.' || v.view_name, 'WITH READ ONLY 뷰 -> 일반 뷰로 생성 (읽기전용 강제는 권한으로)'
    FROM pgmig.oc_views v WHERE v.text ~* 'with\s+read\s+only';
  INSERT INTO pgmig.issues (level, object, msg)
  SELECT 'WARN', v.owner || '.' || v.view_name,
         '|| 문자열 연결 사용: 오라클은 ''a'' || NULL = ''a'', PostgreSQL 은 NULL. 생성되더라도 결과가 다를 수 있음 '
         || '-> NULL 가능 컬럼은 concat() 또는 coalesce(col, '''') 로 감싸기'
    FROM pgmig.oc_views v
   WHERE (SELECT string_agg(x, ' ') FROM unnest(string_to_array(v.text, '''')) WITH ORDINALITY u(x, o) WHERE o % 2 = 1) ~ '\|\|';

  -- 이 툴이 변환하지 않는 객체 (PL/SQL, 트리거 등)
  INSERT INTO pgmig.issues (level, object, msg)
  SELECT 'MANUAL', owner || ' ' || object_type,
         count(*) || '개 이관 안 함 (수동 변환 대상): '
         || array_to_string((array_agg(object_name ORDER BY object_name))[1:30], ', ')
         || CASE WHEN count(*) > 30 THEN ' ... (전체 목록은 manual/plsql_objects.txt)' ELSE '' END
    FROM pgmig.oc_objects GROUP BY owner, object_type ORDER BY owner, object_type;

  -- 파티션
  FOR pt IN
    SELECT x.*, t.id AS table_id
      FROM pgmig.oc_part_tables x JOIN pgmig.tables t ON t.src_schema = x.owner AND t.src_table = x.table_name
     ORDER BY t.id
  LOOP
    IF NOT v_part_on THEN
      INSERT INTO pgmig.issues (level, object, msg)
      VALUES ('MANUAL', pt.owner || '.' || pt.table_name, '파티션 테이블 -> ORA_PARTITIONS=off 라서 일반 테이블로 생성');
      CONTINUE;
    END IF;

    v_fail := NULL;
    SELECT array_agg(pgmig.tgt_name(column_name) ORDER BY column_position) INTO v_keys
      FROM pgmig.oc_part_keys WHERE owner = pt.owner AND name = pt.table_name AND lvl = 'P';
    SELECT array_agg(pgmig.tgt_name(column_name) ORDER BY column_position) INTO v_sub
      FROM pgmig.oc_part_keys WHERE owner = pt.owner AND name = pt.table_name AND lvl = 'S';

    IF pt.partitioning_type NOT IN ('RANGE', 'LIST', 'HASH') THEN
      v_fail := pt.partitioning_type || ' 파티셔닝은 PostgreSQL 에 대응 없음';
    ELSIF coalesce(pt.subpartitioning_type, 'NONE') NOT IN ('NONE', 'RANGE', 'LIST', 'HASH') THEN
      v_fail := pt.subpartitioning_type || ' 서브파티셔닝은 PostgreSQL 에 대응 없음';
    ELSIF v_keys IS NULL THEN
      v_fail := '파티션 키 정보를 못 읽음';
    ELSIF pt.partitioning_type = 'LIST' AND cardinality(v_keys) > 1 THEN
      v_fail := '다중 컬럼 LIST 파티션은 PostgreSQL 미지원';
    ELSIF coalesce(pt.subpartitioning_type, 'NONE') = 'LIST' AND cardinality(v_sub) > 1 THEN
      v_fail := '다중 컬럼 LIST 서브파티션은 PostgreSQL 미지원';
    END IF;

    -- 파티션 경계 변환 (하나라도 실패하면 이 테이블은 일반 테이블로)
    IF v_fail IS NULL THEN
      SELECT count(*) INTO v_cnt FROM pgmig.oc_partitions WHERE table_owner = pt.owner AND table_name = pt.table_name;
      v_prev := NULL;
      <<parts>>
      FOR p IN SELECT * FROM pgmig.oc_partitions WHERE table_owner = pt.owner AND table_name = pt.table_name
                ORDER BY partition_position LOOP
        IF pt.partitioning_type = 'HASH' THEN
          v_bound := format('FOR VALUES WITH (MODULUS %s, REMAINDER %s)', v_cnt, p.partition_position::int - 1);
        ELSE
          v_bound := pgmig.ora_bound(pt.partitioning_type, p.high_value, v_prev, cardinality(v_keys));
        END IF;
        IF v_bound IS NULL THEN
          v_fail := '파티션 ' || p.partition_name || ' 경계값 변환 불가: ' || coalesce(p.high_value, '(null)');
          EXIT parts;
        END IF;
        v_pname := pgmig.trunc63(pgmig.tgt_name(pt.table_name) || '_' || pgmig.tgt_name(p.partition_name));
        INSERT INTO pgmig.partitions (table_id, lvl, pos, sub_pos, src_name, name, bound)
        VALUES (pt.table_id, 1, p.partition_position, 0, p.partition_name, v_pname, v_bound);
        v_prev := p.high_value;

        IF coalesce(pt.subpartitioning_type, 'NONE') <> 'NONE' THEN
          SELECT count(*) INTO v_cnt FROM pgmig.oc_subpartitions
           WHERE table_owner = pt.owner AND table_name = pt.table_name AND partition_name = p.partition_name;
          v_sprev := NULL;
          FOR sp IN SELECT * FROM pgmig.oc_subpartitions
                     WHERE table_owner = pt.owner AND table_name = pt.table_name AND partition_name = p.partition_name
                     ORDER BY subpartition_position LOOP
            IF pt.subpartitioning_type = 'HASH' THEN
              v_bound := format('FOR VALUES WITH (MODULUS %s, REMAINDER %s)', v_cnt, sp.subpartition_position::int - 1);
            ELSE
              v_bound := pgmig.ora_bound(pt.subpartitioning_type, sp.high_value, v_sprev, cardinality(v_sub));
            END IF;
            IF v_bound IS NULL THEN
              v_fail := '서브파티션 ' || sp.subpartition_name || ' 경계값 변환 불가: ' || coalesce(sp.high_value, '(null)');
              EXIT parts;
            END IF;
            INSERT INTO pgmig.partitions (table_id, lvl, pos, sub_pos, src_name, name, parent, bound)
            VALUES (pt.table_id, 2, p.partition_position, sp.subpartition_position, sp.subpartition_name,
                    pgmig.trunc63(pgmig.tgt_name(pt.table_name) || '_' || pgmig.tgt_name(sp.subpartition_name)),
                    v_pname, v_bound);
            v_sprev := sp.high_value;
          END LOOP;
          SELECT count(*) INTO v_cnt FROM pgmig.oc_partitions WHERE table_owner = pt.owner AND table_name = pt.table_name;
        END IF;
      END LOOP;
    END IF;

    IF v_fail IS NOT NULL THEN
      DELETE FROM pgmig.partitions WHERE table_id = pt.table_id;
      INSERT INTO pgmig.issues (level, object, msg)
      VALUES ('MANUAL', pt.owner || '.' || pt.table_name,
              '파티션 테이블 -> 일반 테이블로 생성됨 (' || v_fail || '). 가이드: 데이터 이관/검증 후 '
              || '새 파티션 테이블을 만들고 INSERT INTO 새테이블 SELECT * FROM 기존테이블 로 옮긴 뒤 이름 교체');
    ELSE
      UPDATE pgmig.tables
         SET part_type = pt.partitioning_type, part_cols = v_keys,
             sub_type = CASE WHEN coalesce(pt.subpartitioning_type, 'NONE') <> 'NONE' THEN pt.subpartitioning_type END,
             sub_cols = CASE WHEN coalesce(pt.subpartitioning_type, 'NONE') <> 'NONE' THEN v_sub END
       WHERE id = pt.table_id;
      INSERT INTO pgmig.issues (level, object, msg)
      SELECT 'INFO', pt.owner || '.' || pt.table_name,
             pt.partitioning_type || coalesce('-' || nullif(pt.subpartitioning_type, 'NONE'), '') || ' 파티션 테이블 -> '
             || 'PostgreSQL 선언적 파티션으로 생성 (파티션 ' || count(*) FILTER (WHERE lvl = 1) || '개'
             || coalesce(', 서브파티션 ' || nullif(count(*) FILTER (WHERE lvl = 2), 0) || '개', '') || ')'
        FROM pgmig.partitions WHERE table_id = pt.table_id;
      IF pt.interval IS NOT NULL THEN
        INSERT INTO pgmig.issues (level, object, msg)
        VALUES ('MANUAL', pt.owner || '.' || pt.table_name,
                'INTERVAL 파티션 (' || pt.interval || '): 지금 있는 파티션까지만 생성됨. 이후 범위 데이터 INSERT 는 실패. '
                || '가이드: pg_partman 으로 자동 생성하거나, 앞으로 쓸 파티션을 미리 CREATE TABLE ... PARTITION OF ... 로 생성');
      END IF;
    END IF;
  END LOOP;
END $body$;

CREATE PROCEDURE pgmig.src_oracle_catalog() LANGUAGE plpgsql AS $$
BEGIN
  CALL pgmig.ora_fetch_catalog();
  CALL pgmig.ora_normalize();
END $$;
