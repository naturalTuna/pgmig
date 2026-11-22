-- =====================================================================
-- pgmig 소스 플러그인 : PostgreSQL (postgres_fdw)
--   주 용도는 selftest (오라클 없이 코어 흐름 검증). PG -> PG 단순 이관에도 쓸 수는 있음
--   수집 범위: 테이블, 컬럼, PK (인덱스/FK/시퀀스는 수집 안 함)
-- =====================================================================

CREATE FUNCTION pgmig.pgs_type(dt text, len int, prec int, scale int) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
SELECT CASE
  WHEN dt = 'character varying' THEN 'varchar' || coalesce('(' || len || ')', '')
  WHEN dt = 'character'         THEN 'char(' || coalesce(len, 1) || ')'
  WHEN dt = 'numeric'           THEN CASE WHEN prec IS NULL THEN 'numeric' ELSE format('numeric(%s,%s)', prec, scale) END
  WHEN dt IN ('ARRAY', 'USER-DEFINED') THEN NULL
  ELSE dt END
$$;

CREATE PROCEDURE pgmig.src_postgres_catalog() LANGUAGE plpgsql AS $$
DECLARE
  v_schemas text[] := (SELECT array_agg(btrim(s))
                         FROM unnest(string_to_array(pgmig.cfg('schemas', ''), ',')) s WHERE btrim(s) <> '');
BEGIN
  IF v_schemas IS NULL THEN RAISE EXCEPTION 'SRC_SCHEMAS 가 비어 있음'; END IF;

  DROP FOREIGN TABLE IF EXISTS pgmig.pgs_tables, pgmig.pgs_columns, pgmig.pgs_tc, pgmig.pgs_kcu;
  CREATE FOREIGN TABLE pgmig.pgs_tables (table_schema text, table_name text, table_type text)
    SERVER pgmig_src OPTIONS (schema_name 'information_schema', table_name 'tables');
  CREATE FOREIGN TABLE pgmig.pgs_columns (table_schema text, table_name text, column_name text, ordinal_position int,
      is_nullable text, data_type text, character_maximum_length int, numeric_precision int, numeric_scale int)
    SERVER pgmig_src OPTIONS (schema_name 'information_schema', table_name 'columns');
  CREATE FOREIGN TABLE pgmig.pgs_tc (constraint_schema text, constraint_name text, table_schema text, table_name text,
      constraint_type text)
    SERVER pgmig_src OPTIONS (schema_name 'information_schema', table_name 'table_constraints');
  CREATE FOREIGN TABLE pgmig.pgs_kcu (constraint_schema text, constraint_name text, table_schema text, table_name text,
      column_name text, ordinal_position int)
    SERVER pgmig_src OPTIONS (schema_name 'information_schema', table_name 'key_column_usage');

  DROP TABLE IF EXISTS pgmig.pc_tables, pgmig.pc_columns, pgmig.pc_tc, pgmig.pc_kcu;
  CREATE TABLE pgmig.pc_tables  AS SELECT * FROM pgmig.pgs_tables  WHERE table_schema = ANY (v_schemas) AND table_type = 'BASE TABLE';
  CREATE TABLE pgmig.pc_columns AS SELECT * FROM pgmig.pgs_columns WHERE table_schema = ANY (v_schemas);
  CREATE TABLE pgmig.pc_tc      AS SELECT * FROM pgmig.pgs_tc      WHERE table_schema = ANY (v_schemas) AND constraint_type = 'PRIMARY KEY';
  CREATE TABLE pgmig.pc_kcu     AS SELECT * FROM pgmig.pgs_kcu     WHERE table_schema = ANY (v_schemas);

  IF NOT EXISTS (SELECT FROM pgmig.pc_tables) THEN
    RAISE EXCEPTION '소스에서 테이블을 하나도 못 읽음 (SRC_SCHEMAS 확인)';
  END IF;

  INSERT INTO pgmig.tables (src_schema, src_table, tgt_schema, tgt_table)
  SELECT table_schema, table_name, pgmig.tgt_schema(table_schema), pgmig.tgt_name(table_name)
    FROM pgmig.pc_tables ORDER BY 1, 2;

  INSERT INTO pgmig.columns (table_id, pos, src_col, tgt_col, src_type, tgt_type, not_null)
  SELECT t.id, c.ordinal_position, c.column_name, pgmig.tgt_name(c.column_name), c.data_type,
         pgmig.pgs_type(c.data_type, c.character_maximum_length, c.numeric_precision, c.numeric_scale),
         c.is_nullable = 'NO'
    FROM pgmig.pc_columns c JOIN pgmig.tables t ON t.src_schema = c.table_schema AND t.src_table = c.table_name;

  INSERT INTO pgmig.constraints (table_id, name, ctype, cols)
  SELECT t.id, tc.constraint_name, 'p', array_agg(pgmig.tgt_name(k.column_name) ORDER BY k.ordinal_position)
    FROM pgmig.pc_tc tc
    JOIN pgmig.pc_kcu k ON k.constraint_schema = tc.constraint_schema AND k.constraint_name = tc.constraint_name
                       AND k.table_schema = tc.table_schema AND k.table_name = tc.table_name
    JOIN pgmig.tables t ON t.src_schema = tc.table_schema AND t.src_table = tc.table_name
   GROUP BY t.id, tc.constraint_name;

  INSERT INTO pgmig.issues (level, object, msg)
  VALUES ('MANUAL', array_to_string(v_schemas, ','), 'postgres 플러그인은 인덱스/FK/시퀀스/뷰/함수를 옮기지 않음');
END $$;

CREATE FUNCTION pgmig.src_postgres_stage_sql(p_table int) RETURNS text LANGUAGE sql STABLE AS $$
SELECT format('CREATE FOREIGN TABLE pgmig_stage.%I (%s) SERVER pgmig_src OPTIONS (schema_name %L, table_name %L, fetch_size ''10000'')',
              't' || t.id,
              (SELECT string_agg(format('%I %s OPTIONS (column_name %L)', tgt_col, tgt_type, src_col), ', ' ORDER BY pos)
                 FROM pgmig.columns WHERE table_id = t.id),
              t.src_schema, t.src_table)
  FROM pgmig.tables t WHERE t.id = p_table
$$;

CREATE FUNCTION pgmig.src_postgres_stats(p_table int, p_pk text, OUT lo numeric, OUT hi numeric, OUT cnt bigint)
LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE format('SELECT min(%1$I), max(%1$I), count(*) FROM pgmig_stage.%2$I', p_pk, 't' || p_table)
    INTO lo, hi, cnt;
END $$;

CREATE FUNCTION pgmig.src_postgres_count(p_table int, p_pk text, p_lo numeric, p_hi numeric) RETURNS bigint
LANGUAGE plpgsql AS $$
DECLARE
  r bigint;
BEGIN
  EXECUTE format('SELECT count(*) FROM pgmig_stage.%I WHERE %s', 't' || p_table, pgmig.cond(p_pk, p_lo, p_hi)) INTO r;
  RETURN r;
END $$;

-- 분위수 경계 (NTILE): n 개 버킷의 시작값 중 첫 번째를 뺀 n-1 개 (오름차순, 중복 제거)
--   postgres_fdw 는 윈도 함수를 push down 하지 않아 PK 컬럼만 읽어와서 계산 (selftest 규모 전제)
CREATE FUNCTION pgmig.src_postgres_bounds(p_table int, p_pk text, p_n int) RETURNS numeric[]
LANGUAGE plpgsql AS $$
DECLARE
  r numeric[];
BEGIN
  EXECUTE format('SELECT array_agg(b ORDER BY b) FROM (SELECT DISTINCT min(%1$I)::numeric AS b
                    FROM (SELECT %1$I, ntile($1) OVER (ORDER BY %1$I) AS t FROM pgmig_stage.%2$I) s
                   GROUP BY t) x', p_pk, 't' || p_table)
    USING p_n INTO r;
  RETURN r[2:];
END $$;
