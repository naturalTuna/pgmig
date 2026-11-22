#!/usr/bin/env bash
# pgmig selftest : 오라클 없이 postgres_fdw 로 코어 흐름(이관/검증/불일치 탐지/재이관/삭제)을 점검
#   전제: 실행 중인 PostgreSQL(superuser 접속, postgres_fdw 설치됨). PGHOST/PGPORT/PGUSER 환경변수 사용
#   DB 두 개(pgmig_st_src, pgmig_st_tgt)를 만들었다가 끝나면 지움
set -euo pipefail
BASE="$(cd "$(dirname "$0")/.." && pwd)"
WORK=$(mktemp -d)
P=(psql -X -q -v ON_ERROR_STOP=1)
pass=0; fail=0
ok()  { echo "  [PASS] $1"; pass=$((pass + 1)); }
bad() { echo "  [FAIL] $1"; fail=$((fail + 1)); }
check() { if [ "$2" = "$3" ]; then ok "$1 ($2)"; else bad "$1: 기대=$3 실제=$2"; fi; }
tq() { "${P[@]}" -d pgmig_st_tgt -At -c "$1"; }

"${P[@]}" -d postgres -c "DROP DATABASE IF EXISTS pgmig_st_src" -c "DROP DATABASE IF EXISTS pgmig_st_tgt" \
                      -c "CREATE DATABASE pgmig_st_src" -c "CREATE DATABASE pgmig_st_tgt"

"${P[@]}" -d pgmig_st_src <<'SQL'
CREATE SCHEMA app;
CREATE TABLE app.customers (id int PRIMARY KEY, name varchar(30) NOT NULL);
INSERT INTO app.customers SELECT g, 'cust' || g FROM generate_series(1, 500) g;
CREATE TABLE app.orders (id bigint PRIMARY KEY, cust int, amount numeric(12,2), memo varchar(50),
                         created timestamp, payload bytea, note text, ratio double precision);
INSERT INTO app.orders
SELECT g * 3, 1 + g % 500, (g * 7919 % 1000000) / 100.0,
       CASE WHEN g % 7 = 0 THEN NULL ELSE '메모 ' || g END,
       timestamp '2020-01-01' + g * interval '37 seconds',
       CASE WHEN g % 5 = 0 THEN NULL ELSE decode(md5(g::text), 'hex') END,
       CASE WHEN g % 11 = 0 THEN '' ELSE repeat('x', g % 40) END, g / 7.0
  FROM generate_series(1, 100000) g;
CREATE TABLE app.nopk (a int, b text);
INSERT INTO app.nopk SELECT g % 100, 'dup' FROM generate_series(1, 5000) g;
CREATE TABLE app."MixedCase" (id int PRIMARY KEY, "Val" text);
INSERT INTO app."MixedCase" SELECT g, 'v' || g FROM generate_series(1, 300) g;
CREATE TABLE app.codes (code char(3) PRIMARY KEY, name varchar(20));
INSERT INTO app.codes SELECT lpad(g::text, 3, '0'), 'name' || g FROM generate_series(1, 200) g;
CREATE TABLE app.pairs (a int, b int, v numeric, PRIMARY KEY (a, b));
INSERT INTO app.pairs SELECT g % 50, g, g * 1.5 FROM generate_series(1, 2000) g;
CREATE TABLE app.empty_t (id int PRIMARY KEY, t text);
CREATE TABLE app.arr (id int PRIMARY KEY, tags int[]);
INSERT INTO app.arr VALUES (1, '{1,2}');
SQL

cat >"$WORK/pgmig.conf" <<CONF
PGDATABASE=pgmig_st_tgt
SRC_TYPE=postgres
SRC_PG_HOST=${PGHOST:-/tmp}
SRC_PG_PORT=${PGPORT:-5432}
SRC_PG_DBNAME=pgmig_st_src
SRC_USER=${PGUSER:-postgres}
SRC_SCHEMAS='app'
SCHEMA_MAP='app:app_new'
JOBS=4
CHUNK_ROWS=10000
VERIFY_MODE=full
PROGRESS_SEC=60
CONF
export PGMIG_CONF="$WORK/pgmig.conf"
M="$BASE/pgmig.sh"
cd "$WORK"

echo "== install / analyze =="
"$M" install
"$M" analyze
check "이관 대상 테이블 수" "$(tq "SELECT count(*) FROM pgmig.tables WHERE migrate")" 7
check "미지원 타입(배열) 테이블 제외" "$(tq "SELECT migrate FROM pgmig.tables WHERE src_table = 'arr'")" f
check "PK 없는 테이블 경고" "$(tq "SELECT count(*) FROM pgmig.issues WHERE level = 'WARN' AND object = 'app.nopk'")" 1

# postgres 플러그인이 수집하지 않는 객체 종류는 정규화 테이블에 직접 넣어서 DDL 생성/실행 경로를 점검
tq "INSERT INTO pgmig.indexes (table_id, name, is_unique, cols, descs)
      SELECT id, 'orders_cust_created_ix', false, '{cust,created}', '{f,t}' FROM pgmig.tables WHERE src_table = 'orders';
    INSERT INTO pgmig.constraints (table_id, name, ctype, cols, ref_schema, ref_table, ref_cols, on_delete)
      SELECT id, 'orders_cust_fk', 'f', '{cust}', 'app', 'customers', '{id}', 'CASCADE' FROM pgmig.tables WHERE src_table = 'orders';
    INSERT INTO pgmig.constraints (table_id, name, ctype, expr)
      SELECT id, 'orders_amount_ck', 'c', 'amount >= 0' FROM pgmig.tables WHERE src_table = 'orders';
    INSERT INTO pgmig.constraints (table_id, name, ctype, expr)
      SELECT id, 'orders_bad_ck', 'c', 'no_such_func(amount) > 0' FROM pgmig.tables WHERE src_table = 'orders';
    INSERT INTO pgmig.sequences (src_schema, name, tgt_schema, inc, minv, maxv, startv, cache, cycle)
      VALUES ('app', 'order_seq', 'app_new', 1, 1, 9999999999999999999999999999, 300001, 20, false);
    UPDATE pgmig.columns SET tgt_default = '0' WHERE tgt_col = 'amount'" >/dev/null

echo "== schema / data =="
"$M" schema
check "orders 청크 수" "$(tq "SELECT count(*) FROM pgmig.tasks k JOIN pgmig.tables t ON t.id = k.table_id WHERE t.src_table = 'orders'")" 10
"$M" data
check "orders 적재 건수" "$(tq "SELECT count(*) FROM app_new.orders")" 100000
check "대소문자 혼용 이름 유지" "$(tq "SELECT count(*) FROM app_new.\"MixedCase\" WHERE \"Val\" IS NOT NULL")" 300

echo "== index / verify / fk =="
"$M" index
check "PK 생성" "$(tq "SELECT count(*) FROM pg_constraint WHERE contype = 'p' AND connamespace = 'app_new'::regnamespace")" 6
check "인덱스(DESC) 생성" "$(tq "SELECT count(*) FROM pg_indexes WHERE indexname = 'orders_cust_created_ix' AND indexdef LIKE '%created DESC%'")" 1
check "시퀀스 다음 값" "$(tq "SELECT nextval('app_new.order_seq')")" 300001
check "실패 DDL 은 기록만 하고 진행" "$(tq "SELECT count(*) FROM pgmig.ddl WHERE status = 'failed' AND object LIKE '%orders_bad_ck'")" 1
"$M" verify full
check "full 검증 전 청크 OK" "$(tq "SELECT count(*) FROM pgmig.tasks WHERE v_status IS DISTINCT FROM 'ok'")" 0
"$M" fk
check "FK 생성" "$(tq "SELECT count(*) FROM pg_constraint WHERE conname = 'orders_cust_fk'")" 1

echo "== 일부러 target 을 망가뜨린 뒤 탐지되는지 =="
tq "DELETE FROM app_new.orders WHERE id = 30000;                      -- 행 누락
    UPDATE app_new.orders SET memo = '변조' WHERE id = 150003;         -- 값 변조 (건수는 그대로)
    UPDATE app_new.orders SET amount = amount + 0.01 WHERE id = 270000; -- 숫자 1틱 차이
    INSERT INTO app_new.nopk VALUES (1, 'extra');                      -- 행 초과
    UPDATE app_new.codes SET name = NULL WHERE code = '007';           -- NULL 로 바뀜
    UPDATE app_new.pairs SET v = v WHERE a = 1" >/dev/null
"$M" verify count >/dev/null 2>&1 && bad "count 검증이 불일치를 못 잡음" || ok "count 검증: 불일치 탐지"
check "count 모드가 잡는 청크 (건수 차이만)" "$(tq "SELECT count(*) FROM pgmig.tasks WHERE v_status = 'mismatch'")" 2
"$M" verify full >/dev/null 2>&1 && bad "full 검증이 불일치를 못 잡음" || ok "full 검증: 불일치 탐지"
check "full 모드가 잡는 청크 (값 변조 포함)" "$(tq "SELECT count(*) FROM pgmig.tasks WHERE v_status = 'mismatch'")" 5
T=$(tq "SELECT k.id FROM pgmig.tasks k JOIN pgmig.tables t ON t.id = k.table_id WHERE t.src_table = 'orders' AND k.v_status = 'mismatch' ORDER BY k.id LIMIT 1")
check "diff: 누락 행 PK 지목" "$(tq "SELECT pk || ' ' || kind FROM pgmig.diff($T)")" "(30000) target 에 없음"
"$M" cleanup >/dev/null 2>&1 && bad "불일치 상태인데 cleanup 이 됨" || ok "불일치 상태에서 cleanup 거부"

echo "== repair =="
"$M" repair
check "repair 후 전 청크 OK" "$(tq "SELECT count(*) FROM pgmig.tasks WHERE v_status IS DISTINCT FROM 'ok'")" 0
check "repair 후 orders 건수" "$(tq "SELECT count(*) FROM app_new.orders")" 100000
check "repair 후 nopk 건수" "$(tq "SELECT count(*) FROM app_new.nopk")" 5000

echo "== 중단된 청크(세션 죽음 = 적재 롤백 + running 상태로 남음) 재시도 =="
tq "TRUNCATE app_new.codes;
    UPDATE pgmig.tasks SET status = 'running' WHERE table_id = (SELECT id FROM pgmig.tables WHERE src_table = 'codes')" >/dev/null
"$M" data
check "재시도 후 codes 건수" "$(tq "SELECT count(*) FROM app_new.codes")" 200
"$M" cleanup >/dev/null 2>&1 && bad "미검증 청크가 있는데 cleanup 이 됨" || ok "미검증 상태에서 cleanup 거부"
"$M" verify full

echo "== report / cleanup =="
"$M" report "$WORK/report.txt"
check "리포트 생성" "$(grep -c '== 2. 테이블별 결과 ==' "$WORK/report.txt")" 1
cp "$WORK/report.txt" /tmp/pgmig_selftest_report.txt
"$M" cleanup
check "cleanup 후 pgmig 스키마" "$(tq "SELECT count(*) FROM pg_namespace WHERE nspname LIKE 'pgmig%'")" 0
check "cleanup 후 foreign server" "$(tq "SELECT count(*) FROM pg_foreign_server")" 0
check "cleanup 후 postgres_fdw 확장" "$(tq "SELECT count(*) FROM pg_extension WHERE extname = 'postgres_fdw'")" 0
check "cleanup 후 데이터는 그대로" "$(tq "SELECT count(*) FROM app_new.orders")" 100000

"${P[@]}" -d postgres -c "DROP DATABASE pgmig_st_src" -c "DROP DATABASE pgmig_st_tgt"
rm -rf "$WORK"
echo
echo "결과: PASS $pass / FAIL $fail"
[ "$fail" -eq 0 ]
