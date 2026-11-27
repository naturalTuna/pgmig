-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 naturalTuna — https://github.com/naturalTuna/pgmig
-- =====================================================================
-- 테스트 결과 자동 확인 (target PostgreSQL 에서 실행)
--   실행 시점: ./pgmig.sh run (또는 data/index/verify/fk/view 까지) 끝난 뒤, 시나리오 A/B 전에, cleanup 전에
--   실행: psql -d <테스트 DB> -f test/oracle/check_result.sql
--   결과: 항목별 PASS / FAIL / SKIP(오라클 에디션에서 해당 객체가 안 만들어진 경우)
-- =====================================================================
\pset pager off
CREATE OR REPLACE FUNCTION pg_temp.cnt(r text) RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE n bigint;
BEGIN
  IF to_regclass(r) IS NULL THEN RETURN NULL; END IF;
  EXECUTE 'SELECT count(*) FROM ' || r INTO n;
  RETURN n;
END $$;
CREATE OR REPLACE FUNCTION pg_temp.val(q text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE v text;
BEGIN
  EXECUTE q INTO v;
  RETURN v;
EXCEPTION WHEN undefined_table THEN RETURN NULL;
END $$;

WITH checks(grp, item, expected, actual) AS (
  -- 1. 테이블별 건수 (소스 건수와 같아야 함)
  SELECT '1.건수', r, e::text, pg_temp.cnt(r)::text FROM (VALUES
    ('ref.ref_code', 5), ('app.dept', 10), ('app.emp', 1000), ('app.all_types', 300), ('app.customer', 5000),
    ('app.orders', 300000), ('app.order_item', 20000), ('app.id_always', 100), ('app.id_default', 50),
    ('app.no_pk_log', 3000), ('app."MixedCase"', 100), ('app.lowercase_tab', 10), ('app.reserved_words', 10),
    ('app.virt_col', 100), ('app.long_tab', 20), ('app.iot_code', 26), ('app.empty_t', 0), ('app.def_tab', 5),
    ('app.sales_range', 20000), ('app.sales_interval', 12000), ('app.sales_note', 100), ('app.region_list', 1000),
    ('app.acct_hash', 4000), ('app.sales_comp', 6000), ('app.sales_multi', 2400), ('app.ref_parent', 100),
    ('app.ref_child', 1000), ('app.list_multi', 300), ('app.coll_t', 10), ('app.chk_fail', 10), ('app.chk_noval', 10),
    ('app.fk_noval', 10), ('app.uq_noval', 10), ('app.dis_cons', 10), ('app.null_char', 100), ('app.xml_doc', 10),
    ('app.long_table_name_abcdefghijklmnopqrstuvwxyz_0123456789_abcdefghi', 10)) v(r, e)
  UNION ALL
  -- 2. 이관 제외돼야 하는 테이블 (target 에 없어야 함)
  SELECT '2.제외', r, '없음', CASE WHEN to_regclass(r) IS NULL THEN '없음' ELSE '있음' END FROM (VALUES
    ('app.cust_addr'), ('app.rowid_ref'), ('app.emp_dup'), ('app.colcase'), ('app.tmp_backup_emp'), ('app.gtt_session'),
    ('app.mv_dept_sal')) v(r)
  UNION ALL
  -- 3. 파티션 개수 (leaf 기준)
  SELECT '3.파티션', r, e::text,
         CASE WHEN to_regclass(r) IS NULL THEN NULL
              ELSE (SELECT count(*) FROM pg_partition_tree(r::regclass) WHERE isleaf AND level > 0)::text END
    FROM (VALUES ('app.sales_range', 5), ('app.sales_interval', 13), ('app.region_list', 4), ('app.acct_hash', 4),
                 ('app.sales_comp', 6), ('app.sales_multi', 4), ('app.ref_parent', 2),
                 ('app.ref_child', 0), ('app.list_multi', 0)) v(r, e)
  UNION ALL
  -- 4. 실패해야 하는 DDL (수동 가이드 대상)
  SELECT '4.DDL실패', o, 'failed', coalesce((SELECT string_agg(status, ',') FROM pgmig.ddl WHERE object = o), '없음')
    FROM (VALUES ('pk app.coll_t.dept'), ('pk app.sales_interval.pk_sales_interval'), ('unique app.uq_noval.uq_noval_code'),
                 ('index app.emp.emp_ename_substrb_ix'), ('check app.chk_fail.ck_name_bytes'), ('default app.def_tab.e'),
                 ('fk app.sales_note.fk_note_sale')) v(o)
  UNION ALL
  SELECT '4.DDL실패', '그 외 실패 DDL 개수', '0',
         (SELECT count(*) FROM pgmig.ddl WHERE status = 'failed' AND object NOT IN
           ('pk app.coll_t.dept', 'pk app.sales_interval.pk_sales_interval', 'unique app.uq_noval.uq_noval_code',
            'index app.emp.emp_ename_substrb_ix', 'check app.chk_fail.ck_name_bytes', 'default app.def_tab.e',
            'fk app.sales_note.fk_note_sale'))::text
  UNION ALL
  -- 5. 뷰
  SELECT '5.뷰', v, e, coalesce((SELECT status FROM pgmig.views WHERE tgt_view = v), '없음') FROM (VALUES
    ('v_emp_simple', 'done'), ('v_emp_dept_ansi', 'done'), ('v_emp_nvl', 'done'), ('v_z_base', 'done'), ('v_a_depends', 'done'),
    ('v_dual', 'done'), ('v_minus', 'done'), ('v_cross_schema', 'done'), ('v_readonly', 'done'), ('v_quoted', 'done'),
    ('v_concat', 'done'),
    ('v_emp_dept_outer', 'failed'), ('v_emp_tree', 'failed'), ('v_emp_decode', 'failed'), ('v_top10', 'failed'),
    ('v_listagg', 'failed'), ('v_trunc', 'failed'), ('v_plsql_func', 'failed'), ('v_ext', 'failed'),
    ('v_unsupported', 'failed')) x(v, e)
  UNION ALL
  -- 6. 검증
  SELECT '6.검증', '검증 OK 아닌 청크 수', '0',
         (SELECT count(*) FROM pgmig.tasks WHERE status <> 'done' OR v_status IS DISTINCT FROM 'ok')::text
  UNION ALL
  -- 7. 값 확인 (타입 변환)
  SELECT '7.값', '빈 문자열 -> NULL (all_types id=1 c_varchar2)', 'NULL',
         pg_temp.val('SELECT coalesce(c_varchar2, ''NULL'') FROM app.all_types WHERE id = 1')
  UNION ALL SELECT '7.값', '이모지/한글 (id=3)', 'emoji 😀 3', pg_temp.val('SELECT c_varchar2 FROM app.all_types WHERE id = 3')
  UNION ALL SELECT '7.값', '기원전 DATE (id=6)', '4000-01-01 12:30:45 BC', pg_temp.val('SELECT c_date::text FROM app.all_types WHERE id = 6')
  UNION ALL SELECT '7.값', 'DATE 9999-12-31 (id=7)', '9999-12-31 23:59:59', pg_temp.val('SELECT c_date::text FROM app.all_types WHERE id = 7')
  UNION ALL SELECT '7.값', 'BINARY_FLOAT NaN (id=5)', 'NaN', pg_temp.val('SELECT c_bfloat::text FROM app.all_types WHERE id = 5')
  UNION ALL SELECT '7.값', 'BINARY_FLOAT -Inf (id=7)', '-Infinity', pg_temp.val('SELECT c_bfloat::text FROM app.all_types WHERE id = 7')
  UNION ALL SELECT '7.값', 'TIMESTAMP(9) 반올림 (id=1)', '2024-01-01 10:20:31.123457', pg_temp.val('SELECT c_ts9::text FROM app.all_types WHERE id = 1')
  UNION ALL SELECT '7.값', 'NUMBER(38) 최대 (id=2)', '99999999999999999999999999999999999999', pg_temp.val('SELECT c_num_38::text FROM app.all_types WHERE id = 2')
  UNION ALL SELECT '7.값', 'NUMBER 큰 소수 (id=4)', '12345678901234567890.123456789', pg_temp.val('SELECT c_num::text FROM app.all_types WHERE id = 4')
  UNION ALL SELECT '7.값', '큰 CLOB 글자수 (id=2)', '148000', pg_temp.val('SELECT length(c_clob)::text FROM app.all_types WHERE id = 2')
  UNION ALL SELECT '7.값', '큰 BLOB 바이트 (id=2)', '200000', pg_temp.val('SELECT length(c_blob)::text FROM app.all_types WHERE id = 2')
  UNION ALL SELECT '7.값', 'EMPTY_BLOB -> 0바이트 (id=1)', '0', pg_temp.val('SELECT length(c_blob)::text FROM app.all_types WHERE id = 1')
  UNION ALL SELECT '7.값', 'LONG 30000자', '30000', pg_temp.val('SELECT min(length(body))::text FROM app.long_tab')
  UNION ALL SELECT '7.값', '가상컬럼 값 (virt_col id=10)', '45.00', pg_temp.val('SELECT total::numeric(10,2)::text FROM app.virt_col WHERE id = 10')
  UNION ALL SELECT '7.값', '0x00 제거 (STRIP_ZEROS=on 후)', 'badvalue', pg_temp.val('SELECT txt FROM app.null_char WHERE id = 50')
  UNION ALL SELECT '7.값', '대소문자 컬럼', 'Camel7', pg_temp.val('SELECT "CamelCol" FROM app."MixedCase" WHERE "Id" = 7')
  UNION ALL
  -- 8. 객체 동작
  SELECT '8.동작', 'identity ALWAYS 시작값 > 100 (소스 다음 값부터)', 'true', pg_temp.val('SELECT (start_value > 100)::text FROM pg_sequences WHERE schemaname = ''app'' AND sequencename = ''id_always_id_seq''')
  UNION ALL SELECT '8.동작', 'orders.order_id default = 시퀀스', 'true', pg_temp.val('SELECT (column_default LIKE ''nextval(%orders_seq%'')::text FROM information_schema.columns WHERE table_schema = ''app'' AND table_name = ''orders'' AND column_name = ''order_id''')
  UNION ALL SELECT '8.동작', 'UK DEFERRABLE', 'true', pg_temp.val('SELECT condeferrable::text FROM pg_constraint WHERE conname = ''uk_emp_name_dept''')
  UNION ALL SELECT '8.동작', 'CHECK NOT VALID (chk_noval)', 'false', pg_temp.val('SELECT convalidated::text FROM pg_constraint WHERE conname = ''ck_amt_pos''')
  UNION ALL SELECT '8.동작', 'FK NOT VALID (fk_noval)', 'false', pg_temp.val('SELECT convalidated::text FROM pg_constraint WHERE conname = ''fk_noval_dept''')
  UNION ALL SELECT '8.동작', '스키마 간 FK (customer -> ref.ref_code)', '1', pg_temp.val('SELECT count(*)::text FROM pg_constraint WHERE conname = ''fk_cust_grade''')
  UNION ALL SELECT '8.동작', '이관 안 한 스키마로의 FK 는 없음', '0', pg_temp.val('SELECT count(*)::text FROM pg_constraint WHERE conname = ''fk_cust_country''')
  UNION ALL SELECT '8.동작', '함수기반 인덱스 upper(email)', '1', pg_temp.val('SELECT count(*)::text FROM pg_indexes WHERE indexname = ''emp_email_upper_ix''')
  UNION ALL SELECT '8.동작', '코멘트', '부서', pg_temp.val('SELECT obj_description(''app.dept''::regclass, ''pg_class'')')
  UNION ALL SELECT '8.동작', 'LIST 파티션 NULL 라우팅', '167', pg_temp.val('SELECT count(*)::text FROM app.region_list_p_null')
)
SELECT grp AS "구분", item AS "항목", expected AS "기대", coalesce(actual, '-') AS "실제",
       CASE WHEN actual IS NULL THEN 'SKIP'
            WHEN actual = expected THEN 'PASS' ELSE 'FAIL' END AS "결과"
  FROM checks ORDER BY grp, item;
