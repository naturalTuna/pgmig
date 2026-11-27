-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 naturalTuna — https://github.com/naturalTuna/pgmig
-- =====================================================================
-- pgmig core v0.2 : FDW 기반 anyDB -> PostgreSQL 마이그레이션 (소스 종류 무관 공통부)
--   pgmig        : 제어 스키마 (카탈로그 사본, DDL 큐, 청크 태스크, 함수)
--   pgmig_stage  : 소스 테이블을 가리키는 foreign table (t<테이블id>)
-- 소스별 플러그인(src_<type>.sql)이 구현해야 하는 것:
--   PROCEDURE pgmig.src_<type>_catalog()                  -> tables/columns/constraints/indexes/sequences/
--                                                            partitions/comments/views/issues 채움
--   FUNCTION  pgmig.src_<type>_stage_sql(table_id) text   -> CREATE FOREIGN TABLE pgmig_stage.t<id> 문
--   FUNCTION  pgmig.src_<type>_stats(table_id, col, from, kind)   -> (lo, hi, cnt)   from: col >= from 만 (NULL=전체)
--   FUNCTION  pgmig.src_<type>_count(table_id, col, lo, hi, kind) -> bigint
--   (선택) FUNCTION pgmig.src_<type>_bounds(table_id, col, n, kind) -> numeric[]   분위수 경계
--   kind: NULL(숫자 PK) / num / time(값은 epoch 초) -> pgmig.cond(col, lo, hi, kind) 와 같은 범위여야 함
-- =====================================================================
CREATE SCHEMA pgmig;
CREATE SCHEMA pgmig_stage;

CREATE TABLE pgmig.config (key text PRIMARY KEY, value text);

CREATE FUNCTION pgmig.cfg(k text, dflt text DEFAULT NULL) RETURNS text
LANGUAGE sql STABLE AS
$$ SELECT coalesce((SELECT nullif(value, '') FROM pgmig.config WHERE key = k), dflt) $$;

-- PostgreSQL 식별자 길이 한도(63 byte)로 자르기
CREATE FUNCTION pgmig.trunc63(s text) RETURNS text
LANGUAGE plpgsql IMMUTABLE STRICT AS $$
BEGIN
  WHILE octet_length(s) > 63 LOOP s := left(s, -1); END LOOP;
  RETURN s;
END $$;

-- 대문자 전용 이름(오라클 기본)은 소문자로, 그 외(대소문자 혼용)는 그대로. 63 byte 초과는 자름
CREATE FUNCTION pgmig.tgt_name(n text) RETURNS text
LANGUAGE sql IMMUTABLE AS
$$ SELECT pgmig.trunc63(CASE WHEN n = upper(n) THEN lower(n) ELSE n END) $$;

-- schema_map = 'HR:hr_new,SCOTT:scott2' 형식. 없으면 tgt_name 규칙
CREATE FUNCTION pgmig.tgt_schema(s text) RETURNS text
LANGUAGE sql STABLE AS
$$ SELECT coalesce(
     (SELECT btrim(split_part(m, ':', 2))
        FROM unnest(string_to_array(pgmig.cfg('schema_map', ''), ',')) m
       WHERE btrim(split_part(m, ':', 1)) = s LIMIT 1),
     pgmig.tgt_name(s)) $$;

CREATE FUNCTION pgmig.qcols(a text[]) RETURNS text
LANGUAGE sql IMMUTABLE AS
$$ SELECT string_agg(quote_ident(c), ', ' ORDER BY o) FROM unnest(a) WITH ORDINALITY u(c, o) $$;

-- ---------------------------------------------------------------------
-- 정규화된 소스 카탈로그
-- ---------------------------------------------------------------------
CREATE TABLE pgmig.tables (
  id          serial PRIMARY KEY,
  src_schema  text NOT NULL,
  src_table   text NOT NULL,
  tgt_schema  text NOT NULL,
  tgt_table   text NOT NULL,
  est_rows    bigint,
  migrate     boolean NOT NULL DEFAULT true,
  note        text,
  part_type   text,            -- RANGE / LIST / HASH (NULL = 일반 테이블)
  part_cols   text[],
  sub_type    text,            -- 서브파티션 방식 (NULL = 없음)
  sub_cols    text[],
  UNIQUE (src_schema, src_table)
);

CREATE TABLE pgmig.partitions (
  table_id    int NOT NULL,
  lvl         int NOT NULL,    -- 1 = 파티션, 2 = 서브파티션
  pos         int NOT NULL,    -- 파티션 순서
  sub_pos     int NOT NULL DEFAULT 0,
  src_name    text,
  name        text NOT NULL,   -- target 테이블 이름
  parent      text,            -- lvl 2 일 때 상위 파티션의 target 이름
  bound       text NOT NULL    -- FOR VALUES ... / DEFAULT
);

CREATE TABLE pgmig.columns (
  table_id    int NOT NULL,
  pos         int NOT NULL,
  src_col     text NOT NULL,
  tgt_col     text NOT NULL,
  src_type    text,
  tgt_type    text,            -- NULL = 미지원 타입 (테이블 이관 제외)
  not_null    boolean NOT NULL DEFAULT false,
  src_default text,
  tgt_default text,            -- 변환 시도할 default 식 (NULL = 없음)
  identity    text,            -- ALWAYS / BY DEFAULT
  identity_start numeric,
  PRIMARY KEY (table_id, pos)
);

CREATE TABLE pgmig.constraints (
  id          serial PRIMARY KEY,
  table_id    int NOT NULL,
  name        text NOT NULL,
  ctype       text NOT NULL CHECK (ctype IN ('p', 'u', 'f', 'c')),
  cols        text[],          -- target 컬럼명
  ref_schema  text,            -- FK: 소스 기준 참조 스키마/테이블
  ref_table   text,
  ref_cols    text[],
  on_delete   text,
  expr        text,            -- CHECK 식 (변환 후)
  validated   boolean NOT NULL DEFAULT true,   -- false 면 NOT VALID 로 생성 (CHECK/FK)
  can_defer   boolean NOT NULL DEFAULT false,
  init_defer  boolean NOT NULL DEFAULT false
);

CREATE TABLE pgmig.indexes (
  id          serial PRIMARY KEY,
  table_id    int NOT NULL,
  name        text NOT NULL,
  is_unique   boolean NOT NULL DEFAULT false,
  cols        text[],          -- 컬럼 (식 인덱스 위치는 NULL)
  exprs       text[],          -- 식 (일반 컬럼 위치는 NULL)
  descs       boolean[]
);

CREATE TABLE pgmig.sequences (
  src_schema  text NOT NULL,
  name        text NOT NULL,
  tgt_schema  text NOT NULL,
  inc         numeric NOT NULL DEFAULT 1,
  minv        numeric,
  maxv        numeric,
  startv      numeric NOT NULL,
  cache       numeric,
  cycle       boolean NOT NULL DEFAULT false
);

CREATE TABLE pgmig.comments (
  table_id    int NOT NULL,
  col         text,            -- NULL = 테이블 코멘트
  txt         text NOT NULL
);

CREATE TABLE pgmig.views (
  id          serial PRIMARY KEY,
  src_schema  text NOT NULL,
  src_view    text NOT NULL,
  tgt_schema  text NOT NULL,
  tgt_view    text NOT NULL,
  cols        text[],
  src_text    text,            -- 원문
  sql         text,            -- 자동 변환 후 CREATE VIEW 문
  status      text NOT NULL DEFAULT 'pending',   -- pending / done / failed / manual(사용자가 직접 생성)
  sqlstate    text,
  error       text
);

-- level: ERROR(이관 제외됨) / WARN(확인 필요) / MANUAL(수동 작업 대상) / INFO
CREATE TABLE pgmig.issues (
  id      serial PRIMARY KEY,
  level   text NOT NULL,
  object  text,
  msg     text
);

-- phase: pre(스키마/테이블/파티션) -> post1(PK/UK/인덱스/CHECK/시퀀스/default/identity/코멘트/ANALYZE) -> post2(FK)
CREATE TABLE pgmig.ddl (
  id       serial PRIMARY KEY,
  phase    text NOT NULL,
  object   text,
  sql      text NOT NULL,
  status   text NOT NULL DEFAULT 'pending',   -- pending/running/done/failed/manual(사용자가 수동 처리 완료 표시)
  sqlstate text,
  error    text
);

-- 청크 = 이관/검증/재이관의 단위
CREATE TABLE pgmig.tasks (
  id        serial PRIMARY KEY,
  table_id  int NOT NULL,
  pk_col    text,              -- 분할 컬럼 (숫자 PK 또는 SPLIT_COLS 로 지정한 컬럼). NULL 이면 테이블 통째로 1청크
  split_kind text,             -- NULL = 숫자 PK / num = 지정한 숫자 컬럼 / time = 지정한 날짜·시각 컬럼(lo/hi 는 epoch 초)
                               --   num/time 은 NOT NULL 보장이 없으므로 첫 청크(하한 없음)가 NULL 값 행도 가져감
  lo        numeric,           -- col >= lo  (NULL = 하한 없음)
  hi        numeric,           -- col <  hi  (NULL = 상한 없음)
  status    text NOT NULL DEFAULT 'pending', -- pending/running/done/failed
  redo      boolean NOT NULL DEFAULT false,  -- true 면 적재 전 해당 범위 삭제 (repair)
  rows      bigint,
  started   timestamptz,
  finished  timestamptz,
  error     text,
  v_status  text,              -- NULL(미검증)/pending/running/ok/mismatch/error
  v_mode    text,              -- count/full
  src_cnt   bigint,
  tgt_cnt   bigint,
  src_hash  numeric,
  tgt_hash  numeric,
  v_error   text,
  v_at      timestamptz,
  pid       int                -- 이 청크를 잡은 워커 세션 pid (살아 있는 세션의 running 은 다른 실행이 건드리지 않음)
);
CREATE INDEX ON pgmig.tasks (status);
CREATE INDEX ON pgmig.tasks (table_id);
CREATE INDEX ON pgmig.tasks (v_status);

CREATE FUNCTION pgmig.rel(p_table int) RETURNS text
LANGUAGE sql STABLE AS
$$ SELECT format('%I.%I', tgt_schema, tgt_table) FROM pgmig.tables WHERE id = p_table $$;

CREATE FUNCTION pgmig.cols(p_table int) RETURNS text
LANGUAGE sql STABLE AS
$$ SELECT string_agg(quote_ident(tgt_col), ', ' ORDER BY pos) FROM pgmig.columns WHERE table_id = p_table $$;

-- epoch 초(numeric) -> UTC 기준 timestamp (마이크로초까지 정확하게. float 변환 오차 없이)
CREATE FUNCTION pgmig.epoch_ts(e numeric) RETURNS timestamp
LANGUAGE sql IMMUTABLE STRICT AS
$$ SELECT (timestamptz '1970-01-01 00:00:00+00' + floor(e)::bigint * interval '1 second'
           + round((e - floor(e)) * 1000000)::bigint * interval '1 microsecond') AT TIME ZONE 'UTC' $$;

-- 청크 경계값 리터럴. time 은 '...+00' 형태 -> timestamp 컬럼은 오프셋 무시(UTC 벽시계), timestamptz 는 UTC 로 해석
--   (time 분할의 경계값은 extract(epoch) 로 구하므로 양쪽 다 같은 시각을 가리킴)
CREATE FUNCTION pgmig.bound_lit(p_v numeric, p_kind text) RETURNS text
LANGUAGE sql IMMUTABLE AS
$$ SELECT CASE WHEN p_kind = 'time'
               THEN quote_literal(to_char(pgmig.epoch_ts(p_v), 'YYYY-MM-DD HH24:MI:SS.US') || '+00')
               ELSE quote_literal(p_v::text) END $$;

-- 분할 컬럼 값을 numeric 으로 (time 은 epoch 초)
CREATE FUNCTION pgmig.split_expr(p_col text, p_kind text) RETURNS text
LANGUAGE sql IMMUTABLE AS
$$ SELECT CASE WHEN p_kind = 'time' THEN format('extract(epoch FROM %I)::numeric', p_col)
               ELSE format('%I::numeric', p_col) END $$;

-- 분할 컬럼 값 사이의 최소 간격 (정수형/초 단위 날짜면 1, 그 외 1 마이크로초 단위로 취급)
CREATE FUNCTION pgmig.split_step(p_type text) RETURNS numeric
LANGUAGE sql IMMUTABLE AS
$$ SELECT CASE WHEN p_type ~ '^(smallint|integer|bigint|date|timestamp\(0\)( with(out)? time zone)?|timestamptz\(0\))$'
                 OR p_type ~ '^numeric\(\d+(,\s*0)?\)$' THEN 1 ELSE 0.000001 END $$;

-- 청크 조건. 값은 따옴표 리터럴로 -> 컬럼 타입으로 해석되어 FDW 가 WHERE 를 소스로 push down 할 수 있음
--   p_kind 가 num/time(SPLIT_COLS 로 지정한 컬럼)이면 첫 청크(하한 없음)가 NULL 값도 가져감 -> 누락 없음
CREATE FUNCTION pgmig.cond(p_pk text, p_lo numeric, p_hi numeric, p_kind text DEFAULT NULL) RETURNS text
LANGUAGE sql IMMUTABLE AS
$$ SELECT coalesce(nullif(concat_ws(' AND ',
       CASE WHEN p_pk IS NOT NULL AND p_lo IS NOT NULL THEN format('%I >= %s', p_pk, pgmig.bound_lit(p_lo, p_kind)) END,
       CASE WHEN p_pk IS NOT NULL AND p_hi IS NOT NULL THEN
            CASE WHEN p_kind IS NOT NULL AND p_lo IS NULL
                 THEN format('(%I < %s OR %I IS NULL)', p_pk, pgmig.bound_lit(p_hi, p_kind), p_pk)
                 ELSE format('%I < %s', p_pk, pgmig.bound_lit(p_hi, p_kind)) END END), ''), 'true') $$;

-- ---------------------------------------------------------------------
-- analyze : 소스 카탈로그 수집 + 공통 점검
-- ---------------------------------------------------------------------
CREATE PROCEDURE pgmig.analyze() LANGUAGE plpgsql AS $$
DECLARE
  v_type text := pgmig.cfg('src_type');
  r      record;
BEGIN
  IF EXISTS (SELECT FROM pgmig.ddl WHERE status <> 'pending')
     OR EXISTS (SELECT FROM pgmig.tasks WHERE status <> 'pending') THEN
    RAISE EXCEPTION '이미 schema/data 단계가 진행됨. analyze 를 다시 하려면 cleanup --force 후 재설치';
  END IF;
  TRUNCATE pgmig.tables, pgmig.partitions, pgmig.columns, pgmig.constraints, pgmig.indexes,
           pgmig.sequences, pgmig.comments, pgmig.views, pgmig.issues, pgmig.ddl, pgmig.tasks RESTART IDENTITY;

  EXECUTE format('CALL pgmig.%I()', 'src_' || v_type || '_catalog');

  -- 제외 패턴 (SCHEMA.TABLE, LIKE 패턴, 콤마 구분)
  UPDATE pgmig.tables t SET migrate = false, note = '설정(EXCLUDE_TABLES)으로 제외'
   WHERE EXISTS (SELECT FROM unnest(string_to_array(pgmig.cfg('exclude_tables', ''), ',')) p
                  WHERE t.src_schema || '.' || t.src_table LIKE btrim(p));

  -- 미지원 타입
  INSERT INTO pgmig.issues (level, object, msg)
  SELECT 'ERROR', t.src_schema || '.' || t.src_table || '.' || c.src_col,
         '미지원 타입 ' || coalesce(c.src_type, '?') || ' -> 테이블 이관 제외. '
         || '가이드: 이 컬럼을 text 등으로 바꾼 뷰를 소스에 만들어 별도 이관하거나, 컬럼 값을 변환해 수동 적재'
    FROM pgmig.columns c JOIN pgmig.tables t ON t.id = c.table_id
   WHERE c.tgt_type IS NULL AND t.migrate;
  UPDATE pgmig.tables t SET migrate = false, note = '미지원 타입 컬럼 포함'
   WHERE migrate AND EXISTS (SELECT FROM pgmig.columns c WHERE c.table_id = t.id AND c.tgt_type IS NULL);

  -- 컬럼 없는 테이블
  UPDATE pgmig.tables t SET migrate = false, note = '컬럼 정보를 읽지 못함'
   WHERE migrate AND NOT EXISTS (SELECT FROM pgmig.columns c WHERE c.table_id = t.id);

  -- 컬럼 이름 충돌 (대소문자 접기/63byte 자르기 결과)
  INSERT INTO pgmig.issues (level, object, msg)
  SELECT 'ERROR', t.src_schema || '.' || t.src_table,
         'target 컬럼 이름 충돌: ' || string_agg(c.src_col, ', ') || ' -> ' || c.tgt_col
         || ' (테이블 이관 제외). 가이드: 소스 컬럼 이름 변경 또는 수동 이관'
    FROM pgmig.columns c JOIN pgmig.tables t ON t.id = c.table_id
   WHERE t.migrate GROUP BY t.id, c.tgt_col HAVING count(*) > 1;
  UPDATE pgmig.tables t SET migrate = false, note = 'target 컬럼 이름 충돌'
   WHERE migrate AND EXISTS (SELECT FROM pgmig.columns c WHERE c.table_id = t.id
                              GROUP BY c.tgt_col HAVING count(*) > 1);

  -- 테이블 이름 충돌
  INSERT INTO pgmig.issues (level, object, msg)
  SELECT 'ERROR', tgt_schema || '.' || tgt_table,
         'target 테이블 이름 충돌: ' || string_agg(src_schema || '.' || src_table, ', ')
         || ' (둘 다 이관 제외). 가이드: SCHEMA_MAP/소스 이름 변경 또는 하나를 EXCLUDE_TABLES 로 빼고 재설치'
    FROM pgmig.tables WHERE migrate GROUP BY tgt_schema, tgt_table HAVING count(*) > 1;
  UPDATE pgmig.tables t SET migrate = false, note = 'target 이름 충돌'
   WHERE migrate AND (tgt_schema, tgt_table) IN
         (SELECT tgt_schema, tgt_table FROM pgmig.tables WHERE migrate GROUP BY 1, 2 HAVING count(*) > 1);

  -- 63 byte 넘는 이름
  INSERT INTO pgmig.issues (level, object, msg)
  SELECT 'WARN', src_schema || '.' || src_table, 'PostgreSQL 이름 한도(63byte) 초과 -> ' || tgt_table || ' 로 잘려서 생성'
    FROM pgmig.tables WHERE migrate AND octet_length(src_table) > 63;
  INSERT INTO pgmig.issues (level, object, msg)
  SELECT 'WARN', t.src_schema || '.' || t.src_table || '.' || c.src_col,
         'PostgreSQL 이름 한도(63byte) 초과 -> ' || c.tgt_col || ' 로 잘려서 생성'
    FROM pgmig.columns c JOIN pgmig.tables t ON t.id = c.table_id
   WHERE t.migrate AND octet_length(c.src_col) > 63;

  -- 파티션 이름이 다른 테이블/파티션과 겹치면 번호 붙여서 회피
  FOR r IN
    SELECT p.ctid AS rid, p.table_id, p.name, t.tgt_schema
      FROM pgmig.partitions p JOIN pgmig.tables t ON t.id = p.table_id
     WHERE EXISTS (SELECT FROM pgmig.tables t2 WHERE t2.tgt_schema = t.tgt_schema AND t2.tgt_table = p.name)
        OR (SELECT count(*) FROM pgmig.partitions p2 JOIN pgmig.tables t3 ON t3.id = p2.table_id
             WHERE t3.tgt_schema = t.tgt_schema AND p2.name = p.name) > 1
  LOOP
    UPDATE pgmig.partitions SET name = pgmig.trunc63(left(name, 50) || '_' || table_id || '_' || pos || '_' || sub_pos)
     WHERE ctid = r.rid;
    UPDATE pgmig.partitions SET parent = pgmig.trunc63(left(r.name, 50) || '_' || table_id || '_' || pos || '_0')
     WHERE table_id = r.table_id AND lvl = 2 AND parent = r.name;
  END LOOP;

  -- 파티션 테이블인데 PK/UK 에 파티션 키가 빠진 경우 (PostgreSQL 은 생성 불가)
  INSERT INTO pgmig.issues (level, object, msg)
  SELECT 'WARN', t.src_schema || '.' || t.src_table || '.' || c.name,
         CASE c.ctype WHEN 'p' THEN 'PK' ELSE 'UK' END || '(' || array_to_string(c.cols, ',') || ') 에 파티션 키('
         || array_to_string(t.part_cols || coalesce(t.sub_cols, '{}'), ',') || ') 가 없음 -> PostgreSQL 에서 생성 실패 예정 (index 단계 리포트 참고)'
    FROM pgmig.constraints c JOIN pgmig.tables t ON t.id = c.table_id
   WHERE t.migrate AND t.part_type IS NOT NULL AND c.ctype IN ('p', 'u')
     AND NOT (c.cols @> (t.part_cols || coalesce(t.sub_cols, '{}')));

  -- PK 없는 테이블
  INSERT INTO pgmig.issues (level, object, msg)
  SELECT 'WARN', t.src_schema || '.' || t.src_table,
         'PK 없음: 행 단위 diff 불가, 청크 분할도 안 됨 (테이블 통째로 이관·검증). 큰 테이블이면 SPLIT_COLS 로 날짜/숫자 분할 컬럼 지정'
    FROM pgmig.tables t
   WHERE t.migrate AND NOT EXISTS (SELECT FROM pgmig.constraints c WHERE c.table_id = t.id AND c.ctype = 'p');
END $$;

-- ---------------------------------------------------------------------
-- DDL 생성 / 실행
-- ---------------------------------------------------------------------
CREATE FUNCTION pgmig.defer_clause(d boolean, i boolean) RETURNS text
LANGUAGE sql IMMUTABLE AS
$$ SELECT CASE WHEN d THEN ' DEFERRABLE INITIALLY ' || CASE WHEN i THEN 'DEFERRED' ELSE 'IMMEDIATE' END ELSE '' END $$;

CREATE PROCEDURE pgmig.gen_ddl() LANGUAGE plpgsql AS $$
BEGIN
  IF EXISTS (SELECT FROM pgmig.ddl) THEN RETURN; END IF;

  INSERT INTO pgmig.ddl (phase, object, sql)
  SELECT 'pre', 'schema ' || s, format('CREATE SCHEMA IF NOT EXISTS %I', s)
    FROM (SELECT tgt_schema s FROM pgmig.tables WHERE migrate
          UNION SELECT tgt_schema FROM pgmig.sequences
          UNION SELECT tgt_schema FROM pgmig.views) x ORDER BY s;

  -- 테이블 + 파티션 (테이블 id 순, 파티션은 상위 -> 하위 순)
  INSERT INTO pgmig.ddl (phase, object, sql)
  SELECT 'pre', obj, stmt FROM (
    SELECT t.id AS tid, 0 AS pos, 0 AS sub_pos, 'table ' || pgmig.rel(t.id) AS obj,
           format('CREATE TABLE %s (%s)%s', pgmig.rel(t.id),
             (SELECT string_agg(format('%I %s%s', c.tgt_col, c.tgt_type,
                                       CASE WHEN c.not_null THEN ' NOT NULL' ELSE '' END), ', ' ORDER BY c.pos)
                FROM pgmig.columns c WHERE c.table_id = t.id),
             CASE WHEN t.part_type IS NOT NULL
                  THEN format(' PARTITION BY %s (%s)', t.part_type, pgmig.qcols(t.part_cols)) ELSE '' END) AS stmt
      FROM pgmig.tables t WHERE t.migrate
    UNION ALL
    SELECT t.id, p.pos, p.sub_pos, 'partition ' || format('%I.%I', t.tgt_schema, p.name),
           format('CREATE TABLE %I.%I PARTITION OF %s %s%s', t.tgt_schema, p.name,
                  CASE WHEN p.lvl = 1 THEN pgmig.rel(t.id) ELSE format('%I.%I', t.tgt_schema, p.parent) END,
                  p.bound,
                  CASE WHEN p.lvl = 1 AND t.sub_type IS NOT NULL
                       THEN format(' PARTITION BY %s (%s)', t.sub_type, pgmig.qcols(t.sub_cols)) ELSE '' END)
      FROM pgmig.partitions p JOIN pgmig.tables t ON t.id = p.table_id
     WHERE t.migrate AND t.part_type IS NOT NULL
  ) x ORDER BY tid, pos, sub_pos;

  -- post1: PK -> UK
  INSERT INTO pgmig.ddl (phase, object, sql)
  SELECT 'post1', CASE c.ctype WHEN 'p' THEN 'pk ' ELSE 'unique ' END || pgmig.rel(t.id) || '.' || c.name,
         format('ALTER TABLE %s ADD CONSTRAINT %I %s (%s)%s', pgmig.rel(t.id), c.name,
                CASE c.ctype WHEN 'p' THEN 'PRIMARY KEY' ELSE 'UNIQUE' END, pgmig.qcols(c.cols),
                pgmig.defer_clause(c.can_defer, c.init_defer))
    FROM pgmig.constraints c JOIN pgmig.tables t ON t.id = c.table_id
   WHERE t.migrate AND c.ctype IN ('p', 'u') ORDER BY c.ctype, c.id;

  -- post1: 인덱스 (식 인덱스도 변환해서 시도)
  INSERT INTO pgmig.ddl (phase, object, sql)
  SELECT 'post1', 'index ' || pgmig.rel(t.id) || '.' || i.name,
         format('CREATE %sINDEX %I ON %s (%s)', CASE WHEN i.is_unique THEN 'UNIQUE ' ELSE '' END, i.name, pgmig.rel(t.id),
           (SELECT string_agg(CASE WHEN u.e IS NOT NULL THEN '(' || u.e || ')' ELSE quote_ident(u.col) END
                              || CASE WHEN u.d THEN ' DESC' ELSE '' END, ', ' ORDER BY u.o)
              FROM unnest(i.cols, i.exprs, i.descs) WITH ORDINALITY u(col, e, d, o)))
    FROM pgmig.indexes i JOIN pgmig.tables t ON t.id = i.table_id
   WHERE t.migrate ORDER BY i.id;

  -- post1: CHECK (오라클에서 NOVALIDATE 였으면 NOT VALID)
  INSERT INTO pgmig.ddl (phase, object, sql)
  SELECT 'post1', 'check ' || pgmig.rel(t.id) || '.' || c.name,
         format('ALTER TABLE %s ADD CONSTRAINT %I CHECK (%s)%s', pgmig.rel(t.id), c.name, c.expr,
                CASE WHEN c.validated THEN '' ELSE ' NOT VALID' END)
    FROM pgmig.constraints c JOIN pgmig.tables t ON t.id = c.table_id
   WHERE t.migrate AND c.ctype = 'c' ORDER BY c.id;

  -- post1: 시퀀스 (default 가 참조할 수 있으니 default 보다 먼저)
  INSERT INTO pgmig.ddl (phase, object, sql)
  SELECT 'post1', 'sequence ' || format('%I.%I', s.tgt_schema, s.name),
         format('CREATE SEQUENCE %I.%I INCREMENT BY %s %s %s START WITH %s CACHE %s%s',
                s.tgt_schema, s.name, s.inc,
                CASE WHEN s.minv IS NULL OR s.minv < -9223372036854775808 THEN 'NO MINVALUE' ELSE 'MINVALUE ' || s.minv END,
                CASE WHEN s.maxv IS NULL OR s.maxv > 9223372036854775807 THEN 'NO MAXVALUE' ELSE 'MAXVALUE ' || s.maxv END,
                s.startv, greatest(coalesce(s.cache, 1), 1),
                CASE WHEN s.cycle THEN ' CYCLE' ELSE '' END)
    FROM pgmig.sequences s ORDER BY s.tgt_schema, s.name;

  -- post1: default (변환 시도, 실패하면 리포트)
  INSERT INTO pgmig.ddl (phase, object, sql)
  SELECT 'post1', 'default ' || pgmig.rel(t.id) || '.' || c.tgt_col,
         format('ALTER TABLE %s ALTER COLUMN %I SET DEFAULT %s', pgmig.rel(t.id), c.tgt_col, c.tgt_default)
    FROM pgmig.columns c JOIN pgmig.tables t ON t.id = c.table_id
   WHERE t.migrate AND c.tgt_default IS NOT NULL AND c.identity IS NULL ORDER BY t.id, c.pos;

  -- post1: identity (데이터 적재 후에 붙이고, 다음 값은 소스 시퀀스 값부터)
  INSERT INTO pgmig.ddl (phase, object, sql)
  SELECT 'post1', 'identity ' || pgmig.rel(t.id) || '.' || c.tgt_col,
         format('ALTER TABLE %s ALTER COLUMN %I ADD GENERATED %s AS IDENTITY%s', pgmig.rel(t.id), c.tgt_col,
                CASE WHEN c.identity = 'ALWAYS' THEN 'ALWAYS' ELSE 'BY DEFAULT' END,
                CASE WHEN c.identity_start IS NOT NULL THEN ' (START WITH ' || c.identity_start || ')' ELSE '' END)
    FROM pgmig.columns c JOIN pgmig.tables t ON t.id = c.table_id
   WHERE t.migrate AND c.identity IS NOT NULL ORDER BY t.id, c.pos;

  -- post1: 코멘트
  INSERT INTO pgmig.ddl (phase, object, sql)
  SELECT 'post1', 'comment ' || pgmig.rel(t.id) || coalesce('.' || m.col, ''),
         CASE WHEN m.col IS NULL THEN format('COMMENT ON TABLE %s IS %L', pgmig.rel(t.id), m.txt)
              ELSE format('COMMENT ON COLUMN %s.%I IS %L', pgmig.rel(t.id), m.col, m.txt) END
    FROM pgmig.comments m JOIN pgmig.tables t ON t.id = m.table_id
   WHERE t.migrate ORDER BY t.id, m.col NULLS FIRST;

  -- post1: 통계
  INSERT INTO pgmig.ddl (phase, object, sql)
  SELECT 'post1', 'analyze ' || pgmig.rel(t.id), 'ANALYZE ' || pgmig.rel(t.id)
    FROM pgmig.tables t WHERE t.migrate ORDER BY t.id;

  -- post2: FK (참조 테이블도 이관 대상일 때만)
  INSERT INTO pgmig.ddl (phase, object, sql)
  SELECT 'post2', 'fk ' || pgmig.rel(t.id) || '.' || c.name,
         format('ALTER TABLE %s ADD CONSTRAINT %I FOREIGN KEY (%s) REFERENCES %s (%s)%s%s%s',
                pgmig.rel(t.id), c.name, pgmig.qcols(c.cols), pgmig.rel(r.id), pgmig.qcols(c.ref_cols),
                CASE upper(coalesce(c.on_delete, '')) WHEN 'CASCADE' THEN ' ON DELETE CASCADE'
                                                      WHEN 'SET NULL' THEN ' ON DELETE SET NULL' ELSE '' END,
                pgmig.defer_clause(c.can_defer, c.init_defer),
                CASE WHEN c.validated THEN '' ELSE ' NOT VALID' END)
    FROM pgmig.constraints c
    JOIN pgmig.tables t ON t.id = c.table_id
    JOIN pgmig.tables r ON r.src_schema = c.ref_schema AND r.src_table = c.ref_table
   WHERE c.ctype = 'f' AND t.migrate AND r.migrate ORDER BY c.id;

  INSERT INTO pgmig.issues (level, object, msg)
  SELECT 'MANUAL', pgmig.rel(t.id) || '.' || c.name,
         'FK 생성 안 함: 참조 테이블 ' || c.ref_schema || '.' || c.ref_table || ' 이 이관 대상 아님. '
         || '가이드: 참조 테이블을 먼저 이관한 뒤 ALTER TABLE ' || pgmig.rel(t.id) || ' ADD CONSTRAINT '
         || quote_ident(c.name) || ' FOREIGN KEY (' || pgmig.qcols(c.cols) || ') REFERENCES <스키마.테이블> ('
         || pgmig.qcols(c.ref_cols) || ')'
    FROM pgmig.constraints c JOIN pgmig.tables t ON t.id = c.table_id
   WHERE c.ctype = 'f' AND t.migrate
     AND NOT EXISTS (SELECT FROM pgmig.tables r
                      WHERE r.src_schema = c.ref_schema AND r.src_table = c.ref_table AND r.migrate);

  INSERT INTO pgmig.issues (level, object, msg)
  SELECT 'WARN', pgmig.rel(t.id) || '.' || c.name,
         CASE c.ctype WHEN 'c' THEN 'CHECK' ELSE 'FK' END
         || ' 가 오라클에서 NOVALIDATE 상태 -> NOT VALID 로 생성 (기존 위반 데이터가 있을 수 있음). '
         || '가이드: 데이터 정리 후 ALTER TABLE ' || pgmig.rel(t.id) || ' VALIDATE CONSTRAINT ' || quote_ident(c.name)
    FROM pgmig.constraints c JOIN pgmig.tables t ON t.id = c.table_id
   WHERE t.migrate AND NOT c.validated AND c.ctype IN ('c', 'f');
END $$;

-- DDL 큐 워커: 여러 세션이 동시에 돌려도 됨 (SKIP LOCKED). 문장 단위로 실패를 기록하고 계속 진행
CREATE PROCEDURE pgmig.run_ddl(p_phase text) LANGUAGE plpgsql AS $$
DECLARE
  r     pgmig.ddl;
  v_err text;
  v_st  text;
BEGIN
  LOOP
    UPDATE pgmig.ddl SET status = 'running', error = NULL, sqlstate = NULL
     WHERE id = (SELECT id FROM pgmig.ddl WHERE phase = p_phase AND status = 'pending'
                  ORDER BY id FOR UPDATE SKIP LOCKED LIMIT 1)
    RETURNING * INTO r;
    EXIT WHEN NOT FOUND;
    COMMIT;
    v_err := NULL; v_st := NULL;
    BEGIN
      EXECUTE r.sql;
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_st = RETURNED_SQLSTATE, v_err = MESSAGE_TEXT;
    END;
    UPDATE pgmig.ddl SET status = CASE WHEN v_err IS NULL THEN 'done' ELSE 'failed' END,
                         error = v_err, sqlstate = v_st
     WHERE id = r.id;
    COMMIT;
  END LOOP;
END $$;

-- 뷰 생성: 의존 순서를 모르니 성공하는 게 없을 때까지 반복
CREATE PROCEDURE pgmig.run_views() LANGUAGE plpgsql AS $$
DECLARE
  r     pgmig.views;
  n_ok  int;
  v_err text;
  v_st  text;
BEGIN
  UPDATE pgmig.views SET status = 'pending' WHERE status = 'failed';
  LOOP
    n_ok := 0;
    FOR r IN SELECT * FROM pgmig.views WHERE status NOT IN ('done', 'manual') ORDER BY id LOOP
      v_err := NULL; v_st := NULL;
      -- 사용자가 수동으로 이미 만들어 둔 뷰
      IF to_regclass(format('%I.%I', r.tgt_schema, r.tgt_view)) IS NOT NULL THEN
        UPDATE pgmig.views SET status = 'manual', error = NULL, sqlstate = NULL WHERE id = r.id;
        CONTINUE;
      END IF;
      BEGIN
        -- 스키마 없이 쓴 이름은 그 뷰의 스키마에서 찾음
        PERFORM set_config('search_path', quote_ident(r.tgt_schema) || ', public', true);
        EXECUTE r.sql;
      EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_st = RETURNED_SQLSTATE, v_err = MESSAGE_TEXT;
      END;
      IF v_err IS NULL THEN
        n_ok := n_ok + 1;
        UPDATE pgmig.views SET status = 'done', error = NULL, sqlstate = NULL WHERE id = r.id;
      ELSE
        UPDATE pgmig.views SET status = 'failed', error = v_err, sqlstate = v_st WHERE id = r.id;
      END IF;
    END LOOP;
    EXIT WHEN n_ok = 0 OR NOT EXISTS (SELECT FROM pgmig.views WHERE status NOT IN ('done', 'manual'));
  END LOOP;
  PERFORM set_config('search_path', 'public', true);
END $$;

-- ---------------------------------------------------------------------
-- 수동 작업 가이드
-- ---------------------------------------------------------------------
CREATE FUNCTION pgmig.ddl_guide(p_object text, p_sqlstate text, p_error text, p_sql text) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
SELECT CASE
  WHEN p_error LIKE '%must include all partitioning columns%' THEN
    'PostgreSQL 파티션 테이블의 PK/UNIQUE 는 파티션 키 컬럼을 반드시 포함해야 함 (오라클 글로벌 인덱스 개념 없음). '
    || '선택지: (1) PK 에 파티션 키 컬럼 추가해서 생성  (2) 파티션별로 UNIQUE 인덱스 생성 (전체 유일성은 보장 안 됨)  '
    || '(3) 유일성이 꼭 필요하면 파티셔닝 해제. 이 PK/UK 를 참조하는 FK 도 같이 실패하므로 함께 처리'
  WHEN p_sqlstate = '42P07' THEN
    '이름 충돌. 오라클은 제약조건 이름과 테이블/인덱스 이름 공간이 따로지만, PostgreSQL 은 PK/UK 가 같은 이름의 인덱스를 만들어 '
    || '같은 스키마의 테이블/인덱스와 겹치면 실패. 가이드: 아래 SQL 에서 이름만 바꿔(예: _pk, _uk, _ix 붙이기) 실행'
  WHEN p_sqlstate = '42710' THEN
    '같은 이름의 객체가 이미 있음. 이름을 바꾸거나 기존 객체 확인 후 실행'
  WHEN p_sqlstate = '23505' THEN
    '중복 데이터 때문에 UNIQUE/PK 생성 실패 (오라클에서 NOVALIDATE/DISABLE 상태였거나 NULL 처리 차이). '
    || '가이드: SELECT <키 컬럼>, count(*) FROM <테이블> GROUP BY <키 컬럼> HAVING count(*) > 1; 로 중복 확인 후 정리하고 실행'
  WHEN p_sqlstate = '23514' THEN
    '기존 데이터가 CHECK 조건 위반. 가이드: 아래 SQL 끝에 NOT VALID 를 붙여 생성(신규 데이터만 검사) 후 '
    || '위반 데이터 정리하고 ALTER TABLE ... VALIDATE CONSTRAINT 실행'
  WHEN p_sqlstate = '23503' THEN
    '참조 대상이 없는 행(고아 데이터)이 있음. 가이드: NOT VALID 로 생성 후 고아 행 정리하고 VALIDATE CONSTRAINT 실행'
  WHEN p_sqlstate = '42830' THEN
    '참조하는 쪽 테이블에 PK/UNIQUE 가 없음. 대부분 참조 테이블의 PK/UK 생성이 먼저 실패한 경우 -> 그쪽을 먼저 해결한 뒤 실행'
  WHEN p_sqlstate = '42P01' THEN
    '참조하는 테이블/뷰가 target 에 없음. (1) 이관 제외된 테이블(미지원 타입/이름 충돌/EXCLUDE_TABLES)인지 report 3번 확인 '
    || '(2) SRC_SCHEMAS 에 없는 스키마의 객체면 그 스키마도 이관하거나 참조를 바꿈 '
    || '(3) 다른 실패한 뷰를 참조하는 경우 그 뷰를 먼저 해결. 객체를 만든 뒤 ./pgmig.sh view 재실행'
  WHEN p_sqlstate = '42883' THEN
    '함수가 없음. 사용자 PL/SQL 함수(패키지 함수 포함)면 PostgreSQL 함수로 먼저 작성한 뒤 재실행. '
    || '오라클 내장 함수면 대표 치환: NVL->coalesce, NVL2(a,b,c)->CASE WHEN a IS NOT NULL THEN b ELSE c END, '
    || 'LENGTHB->octet_length, INSTR->strpos, DECODE->CASE, TO_NUMBER(x)->x::numeric, SYS_GUID()->gen_random_uuid(), '
    || 'TRUNC(날짜)->date_trunc(''day'', x), ADD_MONTHS(d,n)->d + n * interval ''1 month''. '
    || 'orafce 확장을 쓰면 NVL/DECODE 등은 그대로 동작'
  WHEN p_sqlstate = '42703' THEN
    '없는 컬럼 참조. 식 안의 대소문자(따옴표 이름) 또는 오라클 의사컬럼(ROWNUM, ROWID, LEVEL, USER 등) 확인'
  WHEN p_sqlstate LIKE '42%' THEN
    '오라클 문법이 그대로 남아 있음. 아래 SQL 을 PostgreSQL 문법으로 고쳐서 실행'
  WHEN p_sqlstate = '0A000' THEN
    'PostgreSQL 에서 지원하지 않는 기능. 아래 SQL 을 지원 범위에 맞게 바꿔서 실행'
  ELSE '에러 메시지 확인 후 아래 SQL 을 수정해서 실행'
END
$$;

CREATE FUNCTION pgmig.view_hints(p_src text) RETURNS text
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
  h text[] := '{}';
  s text := coalesce(p_src, '');
BEGIN
  IF s ~ '\(\s*\+\s*\)' THEN
    h := array_append(h, '(+) 외부조인 -> ANSI JOIN. 예) FROM a, b WHERE a.id = b.id(+)  =>  FROM a LEFT JOIN b ON a.id = b.id');
  END IF;
  IF s ~* '\mconnect\s+by\M|\mstart\s+with\M|sys_connect_by_path' THEN
    h := array_append(h, 'CONNECT BY 계층쿼리 -> WITH RECURSIVE 로 재작성 (LEVEL 은 재귀 단계 컬럼으로, SYS_CONNECT_BY_PATH 는 문자열 누적 컬럼으로)');
  END IF;
  IF s ~* '\mrownum\M' THEN
    h := array_append(h, 'ROWNUM -> WHERE ROWNUM <= n 은 LIMIT n, 번호 컬럼은 row_number() OVER ()');
  END IF;
  IF s ~* '\mdecode\s*\(' THEN
    h := array_append(h, 'DECODE(x, a, r1, b, r2, d) -> CASE x WHEN a THEN r1 WHEN b THEN r2 ELSE d END (주의: DECODE 는 NULL=NULL 을 같다고 봄 -> IS NOT DISTINCT FROM)');
  END IF;
  IF s ~* '\mnvl2\s*\(' THEN
    h := array_append(h, 'NVL2(x, a, b) -> CASE WHEN x IS NOT NULL THEN a ELSE b END');
  END IF;
  IF s ~* '\mrowid\M' THEN
    h := array_append(h, 'ROWID -> PostgreSQL 에 대응 개념 없음 (ctid 는 바뀜). PK 컬럼으로 대체');
  END IF;
  IF s ~* '\.\s*(nextval|currval)\M' THEN
    h := array_append(h, 'seq.NEXTVAL -> nextval(''스키마.seq''), seq.CURRVAL -> currval(''스키마.seq'')');
  END IF;
  IF s ~* '\m(un)?pivot\M' THEN
    h := array_append(h, 'PIVOT/UNPIVOT -> 집계 + CASE (예: sum(CASE WHEN k = ''A'' THEN v END) AS a) 또는 tablefunc 의 crosstab');
  END IF;
  IF s ~* '\mlistagg\s*\(' THEN
    h := array_append(h, 'LISTAGG(x, '','') WITHIN GROUP (ORDER BY y) -> string_agg(x, '','' ORDER BY y)');
  END IF;
  IF s ~* '\madd_months\s*\(|\mmonths_between\s*\(|\mlast_day\s*\(' THEN
    h := array_append(h, 'ADD_MONTHS(d, n) -> d + n * interval ''1 month'', LAST_DAY(d) -> (date_trunc(''month'', d) + interval ''1 month - 1 day'')::date, MONTHS_BETWEEN -> age()/extract 조합 (또는 orafce)');
  END IF;
  IF s ~* '\mtrunc\s*\(' THEN
    h := array_append(h, 'TRUNC(날짜) -> date_trunc(''day'', x), TRUNC(숫자) 는 그대로 trunc()');
  END IF;
  IF s ~* '\minstr\s*\(|\mlengthb\s*\(|\msubstrb\s*\(' THEN
    h := array_append(h, 'INSTR(s, t) -> strpos(s, t), LENGTHB -> octet_length');
  END IF;
  IF s ~* '\mto_number\s*\(' THEN
    h := array_append(h, 'TO_NUMBER(x) -> x::numeric');
  END IF;
  IF s ~* '\mto_date\s*\(' THEN
    h := array_append(h, 'TO_DATE 는 PostgreSQL 에서 date 반환(시분초 버림) -> 시각까지 필요하면 to_timestamp(x, fmt)');
  END IF;
  IF s ~* '\msys_guid\s*\(|\muserenv\s*\(|\msys_context\s*\(' THEN
    h := array_append(h, 'SYS_GUID() -> gen_random_uuid(), SYS_CONTEXT/USERENV -> current_user, current_setting() 등으로 대체');
  END IF;
  IF s ~* '\mregexp_(like|substr|instr|replace|count)\s*\(' THEN
    h := array_append(h, 'REGEXP_* 는 PostgreSQL 버전에 따라 지원 범위가 다름 (15+ 는 regexp_like/substr/instr/count 지원). 인자 순서/옵션 확인');
  END IF;
  IF s ~ '\|\|' THEN
    h := array_append(h, '주의: 오라클은 ''a'' || NULL = ''a'' 이지만 PostgreSQL 은 NULL -> concat() 또는 coalesce 로 감싸기');
  END IF;
  RETURN array_to_string(h, E'\n');
END $$;

-- ---------------------------------------------------------------------
-- stage foreign table / 청크 계획
-- ---------------------------------------------------------------------
CREATE PROCEDURE pgmig.make_stage(p_only_unfinished boolean DEFAULT false) LANGUAGE plpgsql AS $$
DECLARE
  r      record;
  v_type text := pgmig.cfg('src_type');
  v_sql  text;
BEGIN
  FOR r IN SELECT t.id FROM pgmig.tables t
            WHERE t.migrate
              AND (NOT p_only_unfinished
                   OR EXISTS (SELECT FROM pgmig.tasks k WHERE k.table_id = t.id AND k.status <> 'done'))
            ORDER BY t.id LOOP
    EXECUTE format('DROP FOREIGN TABLE IF EXISTS pgmig_stage.%I', 't' || r.id);
    EXECUTE format('SELECT pgmig.%I($1)', 'src_' || v_type || '_stage_sql') USING r.id INTO v_sql;
    EXECUTE v_sql;
  END LOOP;
END $$;

-- SPLIT_COLS 에서 이 테이블의 분할 컬럼 찾기 ('SCHEMA.TABLE:COL,...'  테이블은 대소문자 무시, 컬럼은 소스/타깃 이름)
--   반환: col(타깃 컬럼명), kind(num/time, 지원 안 하는 타입이면 NULL), spec(설정 원문, 지정 없으면 NULL)
CREATE FUNCTION pgmig.split_col(p_table int, OUT col text, OUT kind text, OUT ctype text, OUT spec text)
LANGUAGE plpgsql STABLE AS $$
DECLARE
  t pgmig.tables;
  e text;
BEGIN
  SELECT * INTO t FROM pgmig.tables WHERE id = p_table;
  SELECT btrim(x) INTO spec
    FROM unnest(string_to_array(pgmig.cfg('split_cols', ''), ',')) x
   WHERE upper(btrim(split_part(btrim(x), ':', 1))) = upper(t.src_schema || '.' || t.src_table) LIMIT 1;
  IF spec IS NULL THEN RETURN; END IF;
  e := btrim(split_part(spec, ':', 2));
  SELECT c.tgt_col, c.tgt_type,
         CASE WHEN c.tgt_type ~ '^(smallint|integer|bigint|numeric|real|double)' THEN 'num'
              WHEN c.tgt_type ~ '^(date|timestamp)' THEN 'time' END
    INTO col, ctype, kind
    FROM pgmig.columns c
   WHERE c.table_id = p_table AND (c.src_col = e OR c.tgt_col = e)
   ORDER BY (c.src_col = e) DESC LIMIT 1;
END $$;

-- 청크 계획
--   분할 컬럼: SPLIT_COLS 로 지정한 숫자/날짜 컬럼 > 숫자 PK(또는 복합 PK 의 숫자 선두 컬럼). 첫 청크 하한 / 마지막 청크 상한 없음.
--   경계값: CHUNK_SPLIT=quantile(기본) 이면 소스에서 분위수(NTILE)로 → 값이 치우쳐도 청크 크기가 고름
--           uniform 이거나 플러그인이 지원 안 하면 (max-min)/n 균등 분할 (예전 방식)
--   분할 컬럼이 없는 큰 테이블은 1청크 → WARN 으로 알림 (병렬 / 부분 재시도 불가)
CREATE PROCEDURE pgmig.plan_tasks() LANGUAGE plpgsql AS $$
DECLARE
  r        record;
  sc       record;
  v_type   text   := pgmig.cfg('src_type');
  v_chunk  bigint := pgmig.cfg('chunk_rows', '500000')::bigint;
  v_force  boolean := pgmig.cfg('chunk_always_count', 'off') = 'on';
  v_split  text   := lower(pgmig.cfg('chunk_split', 'quantile'));
  v_col    text;
  v_kind   text;
  v_lo     numeric;
  v_hi     numeric;
  v_cnt    bigint;
  v_bounds numeric[];
  n        int;
  step     numeric;
  i        int;
BEGIN
  IF v_split NOT IN ('quantile', 'uniform') THEN
    RAISE EXCEPTION 'CHUNK_SPLIT 는 quantile 또는 uniform (현재: %)', v_split;
  END IF;
  FOR r IN
    SELECT t.id, t.est_rows, t.src_schema, t.src_table,
           (SELECT c.cols[1]
              FROM pgmig.constraints c
              JOIN pgmig.columns col ON col.table_id = c.table_id AND col.tgt_col = c.cols[1]
             WHERE c.table_id = t.id AND c.ctype = 'p'
               AND col.tgt_type ~ '^(smallint|integer|bigint|numeric)' LIMIT 1) AS pk
      FROM pgmig.tables t
     WHERE t.migrate AND NOT EXISTS (SELECT FROM pgmig.tasks k WHERE k.table_id = t.id)
     ORDER BY t.id
  LOOP
    n := 1;
    v_bounds := NULL;
    v_col  := r.pk;
    v_kind := NULL;

    sc := pgmig.split_col(r.id);
    IF sc.spec IS NOT NULL THEN
      IF sc.col IS NULL THEN
        INSERT INTO pgmig.issues (level, object, msg)
        VALUES ('WARN', r.src_schema || '.' || r.src_table,
                'SPLIT_COLS 의 컬럼을 찾지 못함 (' || sc.spec || ') -> 무시하고 기본 규칙으로 분할');
      ELSIF sc.kind IS NULL THEN
        INSERT INTO pgmig.issues (level, object, msg)
        VALUES ('WARN', r.src_schema || '.' || r.src_table,
                format('SPLIT_COLS 의 %s 컬럼 타입(%s)은 분할 불가 (숫자/날짜/시각만) -> 무시하고 기본 규칙으로 분할', sc.col, sc.ctype));
      ELSE
        v_col := sc.col; v_kind := sc.kind;
      END IF;
    END IF;

    IF v_col IS NOT NULL AND (v_force OR r.est_rows IS NULL OR r.est_rows > v_chunk) THEN
      EXECUTE format('SELECT lo, hi, cnt FROM pgmig.%I($1, $2, NULL, $3)', 'src_' || v_type || '_stats')
        USING r.id, v_col, v_kind INTO v_lo, v_hi, v_cnt;
      UPDATE pgmig.tables SET est_rows = v_cnt WHERE id = r.id;
      r.est_rows := v_cnt;
      IF v_cnt > v_chunk AND v_hi > v_lo THEN
        n    := ceil(v_cnt::numeric / v_chunk);
        step := ceil((v_hi - v_lo + 1) / n);
        IF v_split = 'quantile' THEN
          BEGIN
            EXECUTE format('SELECT pgmig.%I($1, $2, $3, $4)', 'src_' || v_type || '_bounds')
              USING r.id, v_col, n, v_kind INTO v_bounds;
          EXCEPTION WHEN undefined_function THEN
            v_bounds := NULL;           -- 플러그인 미지원 → 균등 분할
          WHEN OTHERS THEN
            v_bounds := NULL;
            INSERT INTO pgmig.issues (level, object, msg)
            VALUES ('INFO', r.src_schema || '.' || r.src_table,
                    '분위수 경계 계산 실패 → 균등 분할로 진행: ' || SQLERRM);
          END;
        END IF;
      END IF;
    END IF;

    IF v_bounds IS NOT NULL AND cardinality(v_bounds) >= 1 THEN
      -- 경계 b1 < b2 < ... : (-inf,b1) [b1,b2) ... [bk,+inf)
      n := cardinality(v_bounds) + 1;
      FOR i IN 1 .. n LOOP
        INSERT INTO pgmig.tasks (table_id, pk_col, split_kind, lo, hi)
        VALUES (r.id, v_col, v_kind,
                CASE WHEN i > 1 THEN v_bounds[i - 1] END,
                CASE WHEN i < n THEN v_bounds[i] END);
      END LOOP;
    ELSIF n = 1 THEN
      INSERT INTO pgmig.tasks (table_id) VALUES (r.id);
      IF v_col IS NULL AND r.est_rows IS NULL THEN
        -- 분할 컬럼이 없고 통계 추정치도 없으면 크기를 한 번 센다 (1청크 대형 테이블 경고용)
        BEGIN
          EXECUTE format('SELECT pgmig.%I($1, NULL, NULL, NULL)', 'src_' || v_type || '_count')
            USING r.id INTO r.est_rows;
          UPDATE pgmig.tables SET est_rows = r.est_rows WHERE id = r.id;
        EXCEPTION WHEN OTHERS THEN NULL;
        END;
      END IF;
      IF v_col IS NULL AND coalesce(r.est_rows, 0) > v_chunk * 2 THEN
        INSERT INTO pgmig.issues (level, object, msg)
        VALUES ('WARN', r.src_schema || '.' || r.src_table,
                format('숫자 PK 가 없어 약 %s행을 1청크(한 트랜잭션)로 이관 — 병렬화 / 부분 재시도 / 시간 나눠 이관 불가. '
                       '시간·WAL·undo 여유를 확인하고, 가능하면 SPLIT_COLS=%s:<날짜/숫자 컬럼> 으로 분할 컬럼을 지정할 것',
                       r.est_rows, r.src_schema || '.' || r.src_table));
      END IF;
    ELSE
      -- 첫 청크는 하한 없음, 마지막 청크는 상한 없음 -> min/max 조사 이후 들어온 값도 누락 없음
      FOR i IN 0 .. n - 1 LOOP
        INSERT INTO pgmig.tasks (table_id, pk_col, split_kind, lo, hi)
        VALUES (r.id, v_col, v_kind,
                CASE WHEN i > 0     THEN v_lo + i * step END,
                CASE WHEN i < n - 1 THEN v_lo + (i + 1) * step END);
      END LOOP;
    END IF;

    IF v_kind IS NOT NULL THEN
      INSERT INTO pgmig.issues (level, object, msg)
      SELECT 'INFO', r.src_schema || '.' || r.src_table,
             format('분할 컬럼 %s (%s) 로 %s청크 (NULL 값 행은 첫 청크에 포함)', v_col, v_kind, count(*))
        FROM pgmig.tasks WHERE table_id = r.id;
    END IF;
  END LOOP;
END $$;

-- ---------------------------------------------------------------------
-- 이관 기간 중 소스에 새로 들어온 행 (분할 컬럼 범위 밖) 따라잡기
--   마지막 청크(상한 없음)가 이미 적재됐으면: 그 청크 상한을 "target 에 적재된 최대값 다음"으로 닫고,
--   그 뒤 범위를 새 청크(필요하면 CHUNK_ROWS 단위로 여러 개)로 추가 -> data 가 신규 행만 가져감.
--   (안 그러면 신규 행 때문에 마지막 청크 전체가 verify 불일치 -> 통째 재이관)
--   기존 범위 안의 변경(UPDATE/DELETE, 늦게 들어온 작은 ID)은 verify(full) + repair 가 처리
-- ---------------------------------------------------------------------
CREATE FUNCTION pgmig.catchup()
RETURNS TABLE (tbl text, closed_task int, new_range text, src_rows bigint, new_chunks int)
LANGUAGE plpgsql AS $$
DECLARE
  r       record;
  v_type  text   := pgmig.cfg('src_type');
  v_chunk bigint := pgmig.cfg('chunk_rows', '500000')::bigint;
  m       numeric;
  b       numeric;
  s_lo    numeric;
  s_hi    numeric;
  s_cnt   bigint;
  n       int;
  step    numeric;
  i       int;
BEGIN
  FOR r IN
    SELECT k.*, c.tgt_type
      FROM pgmig.tasks k
      JOIN pgmig.columns c ON c.table_id = k.table_id AND c.tgt_col = k.pk_col
     WHERE k.pk_col IS NOT NULL AND k.hi IS NULL AND k.status = 'done'
     ORDER BY k.id
  LOOP
    EXECUTE format('SELECT max(%s) FROM %s WHERE %s', pgmig.split_expr(r.pk_col, r.split_kind),
                   pgmig.rel(r.table_id), pgmig.cond(r.pk_col, r.lo, r.hi, r.split_kind)) INTO m;
    CONTINUE WHEN m IS NULL;          -- 아직 빈 마지막 청크: 신규 행은 verify/repair 로 들어옴
    b := CASE WHEN pgmig.split_step(r.tgt_type) = 1 THEN floor(m) + 1 ELSE m + 0.000001 END;
    EXECUTE format('SELECT lo, hi, cnt FROM pgmig.%I($1, $2, $3, $4)', 'src_' || v_type || '_stats')
      USING r.table_id, r.pk_col, b, r.split_kind INTO s_lo, s_hi, s_cnt;

    -- 범위가 줄었으니 검증 결과는 무효 (target 행은 전부 b 미만이라 재적재는 불필요)
    UPDATE pgmig.tasks SET hi = b, v_status = NULL, v_mode = NULL, src_cnt = NULL, tgt_cnt = NULL,
                           src_hash = NULL, tgt_hash = NULL, v_error = NULL
     WHERE id = r.id;

    n := greatest(1, ceil(coalesce(s_cnt, 0)::numeric / v_chunk))::int;
    IF n > 1 AND s_hi > b THEN
      step := ceil((s_hi - b + 1) / n);
    ELSE
      n := 1;
    END IF;
    FOR i IN 0 .. n - 1 LOOP
      INSERT INTO pgmig.tasks (table_id, pk_col, split_kind, lo, hi)
      VALUES (r.table_id, r.pk_col, r.split_kind, b + i * coalesce(step, 0),
              CASE WHEN i < n - 1 THEN b + (i + 1) * step END);
    END LOOP;

    tbl := pgmig.rel(r.table_id); closed_task := r.id;
    new_range := pgmig.cond(r.pk_col, b, NULL, r.split_kind);
    src_rows := coalesce(s_cnt, 0); new_chunks := n;
    RETURN NEXT;
  END LOOP;
END $$;

-- ---------------------------------------------------------------------
-- 데이터 이관 워커
--   청크 적재(INSERT)와 상태 갱신(done)이 같은 트랜잭션 -> 세션이 죽어도 반쪽 청크가 남지 않음
--   마감(graceful stop): p_stop 이후엔 새 청크를 잡지 않음 (진행 중인 청크는 끝까지 -> 커밋)
--     p_deadline 이 있으면 "그 테이블의 완료 청크 평균 소요시간" 안에 못 끝날 청크도 시작 안 함
--     (긴 청크는 건너뛰고 남은 시간에 끝낼 수 있는 다른 테이블 청크는 계속 진행)
-- ---------------------------------------------------------------------
CREATE PROCEDURE pgmig.worker(p_stop timestamptz DEFAULT NULL, p_deadline timestamptz DEFAULT NULL)
LANGUAGE plpgsql AS $$
DECLARE
  t      pgmig.tasks;
  v_rel  text;
  v_cols text;
  v_cond text;
  v_rows bigint;
  v_err  text;
BEGIN
  LOOP
    UPDATE pgmig.tasks SET status = 'running', started = clock_timestamp(), finished = NULL, error = NULL,
                           pid = pg_backend_pid()
     WHERE id = (SELECT k.id FROM pgmig.tasks k
                  WHERE k.status = 'pending'
                    AND (p_stop IS NULL OR clock_timestamp() < p_stop)
                    AND (p_deadline IS NULL
                         OR clock_timestamp() + coalesce((SELECT avg(d.finished - d.started) FROM pgmig.tasks d
                                                           WHERE d.table_id = k.table_id AND d.status = 'done'
                                                             AND d.finished IS NOT NULL), interval '0') < p_deadline)
                  ORDER BY k.id FOR UPDATE SKIP LOCKED LIMIT 1)
    RETURNING * INTO t;
    EXIT WHEN NOT FOUND;
    COMMIT;

    v_rel  := pgmig.rel(t.table_id);
    v_cols := pgmig.cols(t.table_id);
    v_cond := pgmig.cond(t.pk_col, t.lo, t.hi, t.split_kind);
    v_err  := NULL;
    v_rows := NULL;
    BEGIN
      IF t.redo THEN
        -- 재이관: FK 가 이미 걸려 있어도 같은 범위를 지우고 다시 넣을 수 있게 트리거를 잠시 끔
        SET LOCAL session_replication_role = replica;
        EXECUTE format('DELETE FROM %s WHERE %s', v_rel, v_cond);
      END IF;
      -- OVERRIDING SYSTEM VALUE: identity(ALWAYS) 가 이미 붙은 뒤의 재이관에도 원래 값 그대로
      EXECUTE format('INSERT INTO %s (%s) OVERRIDING SYSTEM VALUE SELECT %s FROM pgmig_stage.%I WHERE %s',
                     v_rel, v_cols, v_cols, 't' || t.table_id, v_cond);
      GET DIAGNOSTICS v_rows = ROW_COUNT;
    EXCEPTION WHEN OTHERS THEN
      v_err := SQLERRM;
    END;

    UPDATE pgmig.tasks
       SET status   = CASE WHEN v_err IS NULL THEN 'done' ELSE 'failed' END,
           redo     = CASE WHEN v_err IS NULL THEN false ELSE redo END,
           rows     = v_rows,
           finished = clock_timestamp(),
           error    = v_err,
           pid      = NULL,
           v_status = NULL, v_mode = NULL, src_cnt = NULL, tgt_cnt = NULL,
           src_hash = NULL, tgt_hash = NULL, v_error = NULL, v_at = NULL
     WHERE id = t.id;
    COMMIT;
  END LOOP;
END $$;

-- ---------------------------------------------------------------------
-- 검증 워커
--   count : 청크별 건수 비교 (소스 쪽 count 는 소스 DB 에서 수행)
--   full  : 청크별 건수 + 전 컬럼 행 해시 합 비교 (소스를 한 번 더 읽음)
-- ---------------------------------------------------------------------
--   p_stop 이후엔 새 청크 검증을 시작하지 않음. 검증한 지 오래된 청크(미검증 포함)부터
--     -> 매일 시간 제한으로 돌려도 전 청크가 돌아가며 검증됨
CREATE PROCEDURE pgmig.verify_worker(p_mode text, p_stop timestamptz DEFAULT NULL) LANGUAGE plpgsql AS $$
DECLARE
  t      pgmig.tasks;
  v_type text := pgmig.cfg('src_type');
  v_rel  text;
  v_cond text;
  v_agg  text;
  s_cnt  bigint;
  t_cnt  bigint;
  s_hash numeric;
  t_hash numeric;
  v_err  text;
BEGIN
  IF p_mode NOT IN ('count', 'full') THEN
    RAISE EXCEPTION '검증 모드는 count 또는 full';
  END IF;
  LOOP
    UPDATE pgmig.tasks SET v_status = 'running', pid = pg_backend_pid()
     WHERE id = (SELECT id FROM pgmig.tasks WHERE status = 'done' AND v_status = 'pending'
                    AND (p_stop IS NULL OR clock_timestamp() < p_stop)
                  ORDER BY v_at NULLS FIRST, id FOR UPDATE SKIP LOCKED LIMIT 1)
    RETURNING * INTO t;
    EXIT WHEN NOT FOUND;
    COMMIT;

    v_rel  := pgmig.rel(t.table_id);
    v_cond := pgmig.cond(t.pk_col, t.lo, t.hi, t.split_kind);
    v_err  := NULL; s_cnt := NULL; t_cnt := NULL; s_hash := NULL; t_hash := NULL;
    BEGIN
      IF p_mode = 'count' THEN
        EXECUTE format('SELECT pgmig.%I($1, $2, $3, $4, $5)', 'src_' || v_type || '_count')
          USING t.table_id, t.pk_col, t.lo, t.hi, t.split_kind INTO s_cnt;
        EXECUTE format('SELECT count(*) FROM %s WHERE %s', v_rel, v_cond) INTO t_cnt;
      ELSE
        -- 행 전체를 text 로 만든 뒤 64bit 해시, 그 합(순서 무관)을 비교
        v_agg := format('count(*), coalesce(sum(hashtextextended(ROW(%s)::text, 0)::numeric), 0)',
                        pgmig.cols(t.table_id));
        EXECUTE format('SELECT %s FROM pgmig_stage.%I WHERE %s', v_agg, 't' || t.table_id, v_cond)
          INTO s_cnt, s_hash;
        EXECUTE format('SELECT %s FROM %s WHERE %s', v_agg, v_rel, v_cond)
          INTO t_cnt, t_hash;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      v_err := SQLERRM;
    END;

    UPDATE pgmig.tasks
       SET v_status = CASE WHEN v_err IS NOT NULL THEN 'error'
                           WHEN s_cnt = t_cnt AND s_hash IS NOT DISTINCT FROM t_hash THEN 'ok'
                           ELSE 'mismatch' END,
           v_mode = p_mode, src_cnt = s_cnt, tgt_cnt = t_cnt,
           src_hash = s_hash, tgt_hash = t_hash, v_error = v_err, v_at = clock_timestamp(), pid = NULL
     WHERE id = t.id;
    COMMIT;
  END LOOP;
END $$;

-- ---------------------------------------------------------------------
-- FK 고아 행 검사 (repair 는 session_replication_role=replica 로 트리거/FK 를 끄고 지웠다 넣으므로,
--   그 사이 소스에서 부모 행이 사라졌으면 자식이 고아로 남을 수 있음)
--   p_tables: 검사할 pgmig.tables id. 이 테이블들이 자식이거나 부모인 FK 를 전부 검사
-- ---------------------------------------------------------------------
CREATE FUNCTION pgmig.fk_orphans(p_tables int[])
RETURNS TABLE (fk text, child text, parent text, orphans bigint) LANGUAGE plpgsql AS $$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT c.oid, c.conname, c.conrelid::regclass AS ch, c.confrelid::regclass AS pa,
           (SELECT string_agg(format('c.%I IS NOT NULL', a.attname), ' AND ')
              FROM unnest(c.conkey) k JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = k) AS notnull,
           (SELECT string_agg(format('p.%I = c.%I', pa.attname, ca.attname), ' AND ')
              FROM unnest(c.conkey, c.confkey) AS u(ck, pk)
              JOIN pg_attribute ca ON ca.attrelid = c.conrelid  AND ca.attnum = u.ck
              JOIN pg_attribute pa ON pa.attrelid = c.confrelid AND pa.attnum = u.pk) AS joincond
      FROM pg_constraint c
     WHERE c.contype = 'f'
       AND (c.conrelid  IN (SELECT to_regclass(pgmig.rel(x)) FROM unnest(p_tables) x)
         OR c.confrelid IN (SELECT to_regclass(pgmig.rel(x)) FROM unnest(p_tables) x))
  LOOP
    fk := r.conname; child := r.ch::text; parent := r.pa::text;
    EXECUTE format('SELECT count(*) FROM %s c WHERE %s AND NOT EXISTS (SELECT 1 FROM %s p WHERE %s)',
                   r.ch, r.notnull, r.pa, r.joincond) INTO orphans;
    RETURN NEXT;
  END LOOP;
END $$;

-- 불일치 청크에서 어떤 행이 다른지 (PK 있는 테이블만)
CREATE FUNCTION pgmig.diff(p_task int, p_limit int DEFAULT 20)
RETURNS TABLE (pk text, kind text) LANGUAGE plpgsql AS $$
DECLARE
  t      pgmig.tasks;
  v_pk   text;
  v_cols text;
  v_cond text;
BEGIN
  SELECT * INTO t FROM pgmig.tasks WHERE id = p_task;
  IF NOT FOUND THEN RAISE EXCEPTION '태스크 % 없음', p_task; END IF;
  SELECT pgmig.qcols(c.cols) INTO v_pk
    FROM pgmig.constraints c WHERE c.table_id = t.table_id AND c.ctype = 'p' LIMIT 1;
  IF v_pk IS NULL THEN RAISE EXCEPTION 'PK 없는 테이블은 행 단위 비교 불가'; END IF;
  v_cols := pgmig.cols(t.table_id);
  v_cond := pgmig.cond(t.pk_col, t.lo, t.hi, t.split_kind);
  RETURN QUERY EXECUTE format($q$
    SELECT k, CASE WHEN t.h IS NULL THEN 'target 에 없음'
                   WHEN s.h IS NULL THEN 'source 에 없음'
                   ELSE '값 다름' END
      FROM (SELECT ROW(%1$s)::text AS k, hashtextextended(ROW(%2$s)::text, 0) AS h
              FROM pgmig_stage.%3$I WHERE %5$s) s
      FULL JOIN
           (SELECT ROW(%1$s)::text AS k, hashtextextended(ROW(%2$s)::text, 0) AS h
              FROM %4$s WHERE %5$s) t USING (k)
     WHERE s.h IS DISTINCT FROM t.h
     ORDER BY 1 LIMIT %6$s $q$,
    v_pk, v_cols, 't' || t.table_id, pgmig.rel(t.table_id), v_cond, p_limit);
END $$;

-- ---------------------------------------------------------------------
-- 수동 작업 파일 (report 가 디렉터리로 떨굼): (파일명, 내용)
-- ---------------------------------------------------------------------
CREATE FUNCTION pgmig.manual_files() RETURNS TABLE (fname text, body text)
LANGUAGE sql STABLE AS $$
  -- 실패한 뷰: 뷰 하나당 파일 하나. 고쳐서 psql -f 로 실행
  SELECT format('views/%s.%s.sql', v.tgt_schema, v.tgt_view),
         concat_ws(E'\n',
           '-- 뷰 ' || v.src_schema || '.' || v.src_view || ' -> ' || format('%I.%I', v.tgt_schema, v.tgt_view),
           '-- 에러: [' || coalesce(v.sqlstate, '') || '] ' || coalesce(v.error, ''),
           '--',
           '-- 가이드:',
           regexp_replace(concat_ws(E'\n', nullif(pgmig.view_hints(v.src_text), ''),
                                    pgmig.ddl_guide(NULL, v.sqlstate, v.error, NULL)), '^', '--   ', 'gn'),
           '--   고친 뒤: psql -f 이파일.sql  (또는 수정 없이 의존 객체만 만들었다면 ./pgmig.sh view)',
           '--',
           '-- [오라클 원문]',
           regexp_replace(coalesce(v.src_text, ''), '^', '--   ', 'gn'),
           '',
           '-- [자동 변환 결과: 여기를 고쳐서 실행]',
           'SET search_path = ' || quote_ident(v.tgt_schema) || ', public;',
           v.sql || ';',
           '')
    FROM pgmig.views v WHERE v.status = 'failed'
  UNION ALL
  -- 실패한 DDL 전체
  SELECT 'ddl_failed.sql',
         string_agg(concat_ws(E'\n',
           '-- #' || d.id || ' [' || d.phase || '] ' || d.object,
           '-- 에러: [' || coalesce(d.sqlstate, '') || '] ' || coalesce(d.error, ''),
           '-- 가이드: ' || pgmig.ddl_guide(d.object, d.sqlstate, d.error, d.sql),
           '-- 처리 후: ./pgmig.sh resolved ' || d.id,
           d.sql || ';', ''), E'\n' ORDER BY d.id)
    FROM pgmig.ddl d WHERE d.status = 'failed' HAVING count(*) > 0
  UNION ALL
  -- 이관하지 않는 객체 / 수동 작업 목록
  SELECT 'manual_items.txt',
         string_agg(format('[%s] %s%s%s', i.level, coalesce(i.object, ''), E'\n    ', i.msg), E'\n'
                    ORDER BY CASE i.level WHEN 'ERROR' THEN 1 WHEN 'MANUAL' THEN 2 WHEN 'WARN' THEN 3 ELSE 4 END, i.id)
    FROM pgmig.issues i WHERE i.level IN ('ERROR', 'MANUAL', 'WARN') HAVING count(*) > 0
$$;
