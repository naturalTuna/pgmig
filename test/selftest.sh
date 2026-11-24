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
-- PK 값이 한쪽으로 몰린 테이블: 1..29000 + 1조 근처 1000개 (균등 분할이면 한 청크에 29000행이 몰림)
CREATE TABLE app.skew (id bigint PRIMARY KEY, v text);
INSERT INTO app.skew SELECT g, 's' || g FROM generate_series(1, 29000) g;
INSERT INTO app.skew SELECT 1000000000000 + g, 's' || g FROM generate_series(1, 1000) g;
-- 복합 PK (숫자 선두 컬럼) — 선두 컬럼으로 분할
CREATE TABLE app.events (dev int, seq int, val text, PRIMARY KEY (dev, seq));
INSERT INTO app.events SELECT g % 50, g, 'e' || g FROM generate_series(1, 25000) g;
-- 문자 PK 대형 테이블 — 1청크, WARN 대상
CREATE TABLE app.textpk (code varchar(20) PRIMARY KEY, v int);
INSERT INTO app.textpk SELECT 'C' || lpad(g::text, 8, '0'), g FROM generate_series(1, 25000) g;
-- SPLIT_COLS: 문자 PK 대형 테이블을 시각 컬럼으로 분할 (일부 NULL, 밀리초 포함)
CREATE TABLE app.logs (lid varchar(20) PRIMARY KEY, created timestamp, msg text);
INSERT INTO app.logs
SELECT 'L' || lpad(g::text, 8, '0'),
       CASE WHEN g % 1000 = 0 THEN NULL ELSE timestamp '2024-01-01' + g * interval '1 minute' + (g % 7) * interval '1 millisecond' END,
       'm' || g
  FROM generate_series(1, 25000) g;
-- SPLIT_COLS: PK 없는 대형 테이블을 숫자 컬럼(중복값, NULL 있음)으로 분할
CREATE TABLE app.meas (grp int, v numeric);
INSERT INTO app.meas SELECT CASE WHEN g % 997 = 0 THEN NULL ELSE g / 3 END, g * 0.5 FROM generate_series(1, 25000) g;
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
SPLIT_COLS='app.logs:created,app.meas:grp'
CONF
export PGMIG_CONF="$WORK/pgmig.conf"
M="$BASE/pgmig.sh"
cd "$WORK"

echo "== install / analyze =="
"$M" install
"$M" analyze
check "이관 대상 테이블 수" "$(tq "SELECT count(*) FROM pgmig.tables WHERE migrate")" 12
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
check "skew 청크 수 (분위수 분할)" "$(tq "SELECT count(*) FROM pgmig.tasks k JOIN pgmig.tables t ON t.id = k.table_id WHERE t.src_table = 'skew'")" 3
check "events 청크 수 (복합 PK 선두 컬럼 분할)" "$(tq "SELECT count(*) FROM pgmig.tasks k JOIN pgmig.tables t ON t.id = k.table_id WHERE t.src_table = 'events'")" 3
check "문자 PK 대형 테이블 1청크 경고" "$(tq "SELECT count(*) FROM pgmig.issues WHERE level = 'WARN' AND object = 'app.textpk' AND msg LIKE '%1청크%'")" 1
tcnt() { tq "SELECT count(*) FROM pgmig.tasks k JOIN pgmig.tables t ON t.id = k.table_id WHERE t.src_table = '$1' ${2:+AND $2}"; }
check "SPLIT_COLS 시각 컬럼 분할 (logs)" "$(tcnt logs "k.split_kind = 'time' AND k.pk_col = 'created'")" 3
check "SPLIT_COLS 숫자 컬럼 분할 (PK 없는 meas)" "$(tcnt meas "k.split_kind = 'num' AND k.pk_col = 'grp'")" 3
check "SPLIT_COLS 테이블은 1청크 경고 없음" "$(tq "SELECT count(*) FROM pgmig.issues WHERE level = 'WARN' AND object IN ('app.logs', 'app.meas') AND msg LIKE '%1청크%'")" 0
check "첫 청크가 NULL 값 포함" "$(tq "SELECT pgmig.cond(pk_col, lo, hi, split_kind) LIKE '%created IS NULL%' FROM pgmig.tasks k JOIN pgmig.tables t ON t.id = k.table_id WHERE t.src_table = 'logs' AND k.lo IS NULL")" t

echo "== 마감 시각 (graceful stop) =="
# orders 청크마다 0.7초 걸리게 (target 문장 트리거) -> 시간 안에 일부만 끝나는 상황 재현. JOBS=1 로 결정적으로
tq "CREATE FUNCTION public.pgmig_slow() RETURNS trigger LANGUAGE plpgsql AS \$\$ BEGIN PERFORM pg_sleep(0.7); RETURN NULL; END \$\$;
    CREATE TRIGGER pgmig_slow AFTER INSERT ON app_new.orders FOR EACH STATEMENT EXECUTE FUNCTION public.pgmig_slow()" >/dev/null
{ cat "$WORK/pgmig.conf"; echo "JOBS=1"; } >"$WORK/pgmig1.conf"
{ cat "$WORK/pgmig1.conf"; echo "MAX_MINUTES=5"; echo "STOP_BEFORE_MIN=10"; } >"$WORK/pgmig2.conf"
rc=0; PGMIG_CONF="$WORK/pgmig2.conf" "$M" data >"$WORK/dl0.log" 2>&1 || rc=$?
check "conf MAX_MINUTES < STOP_BEFORE_MIN: 시작 안 함 (종료코드 3)" "$rc" 3
check "  적재된 청크 없음" "$(tq "SELECT count(*) FROM pgmig.tasks WHERE status <> 'pending'")" 0
DL=$(date -d '+4 seconds' '+%F %T'); DL_EPOCH=$(date -d "$DL" +%s)
rc=0; PGMIG_CONF="$WORK/pgmig1.conf" "$M" data --until "$DL" --stop-before 0 >"$WORK/dl1.log" 2>&1 || rc=$?
END_EPOCH=$(date +%s.%N)
check "--until 마감: 종료코드 3" "$rc" 3
grep -q "마감으로 멈춤" "$WORK/dl1.log" && ok "마감 메시지" || { bad "마감 메시지 없음"; cat "$WORK/dl1.log"; }
OD=$(tcnt orders "k.status = 'done'"); OP=$(tcnt orders "k.status = 'pending'")
[ "$OD" -ge 2 ] && [ "$OP" -ge 1 ] && ok "orders 일부만 적재 (done $OD / pending $OP)" || bad "orders 부분 적재 아님: done $OD pending $OP"
check "  running/failed 로 남은 청크 없음 (진행 중 청크는 커밋)" "$(tq "SELECT count(*) FROM pgmig.tasks WHERE status IN ('running', 'failed')")" 0
check "  적재 건수 = 완료 청크 rows 합 (반쪽 적재 없음)" "$(tq "SELECT count(*) FROM app_new.orders")" \
      "$(tq "SELECT sum(rows) FROM pgmig.tasks k JOIN pgmig.tables t ON t.id = k.table_id WHERE t.src_table = 'orders' AND k.status = 'done'")"
# 명령 종료는 진행 표시 폴링(1초) + 결과 출력만큼 늦을 수 있음. 청크 자체가 마감 전에 끝났는지는 아래 항목에서 봄
awk -v e="$END_EPOCH" -v d="$DL_EPOCH" 'BEGIN { exit !(e <= d + 3.0) }' && ok "마감 직후 명령 종료 (+3초 이내)" || bad "마감 초과 종료: end=$END_EPOCH deadline=$DL_EPOCH"
check "  평균 소요시간 안에 못 끝날 orders 청크는 시작 안 함 (마감 후 끝난 청크 없음)" \
      "$(tq "SELECT count(*) FROM pgmig.tasks WHERE status = 'done' AND finished > to_timestamp($DL_EPOCH)")" 0
OID=$(tq "SELECT id FROM pgmig.tables WHERE src_table = 'orders'")
[ "$(tq "SELECT count(*) FROM pgmig.tasks WHERE status = 'done' AND table_id > $OID")" -gt 0 ] \
  && ok "남은 시간에 짧은 다른 테이블 청크는 계속 진행" || bad "다른 테이블 청크가 진행되지 않음"
tq "DROP TRIGGER pgmig_slow ON app_new.orders; DROP FUNCTION public.pgmig_slow()" >/dev/null
"$M" data
check "다음 실행에서 남은 청크 이어서 완료" "$(tq "SELECT count(*) FROM pgmig.tasks WHERE status <> 'done'")" 0
check "orders 적재 건수" "$(tq "SELECT count(*) FROM app_new.orders")" 100000
SKEW_MAX=$(tq "SELECT max(n) FROM (SELECT (SELECT count(*) FROM app_new.skew s WHERE (k.lo IS NULL OR s.id >= k.lo) AND (k.hi IS NULL OR s.id < k.hi)) n
                FROM pgmig.tasks k JOIN pgmig.tables t ON t.id = k.table_id WHERE t.src_table = 'skew') x")
[ "$SKEW_MAX" -le 11000 ] && ok "skew 청크 최대 ${SKEW_MAX}행 (균등 분할이면 29000)" || bad "skew 청크 불균형: 최대 ${SKEW_MAX}행"
check "events 적재 건수" "$(tq "SELECT count(*) FROM app_new.events")" 25000
check "logs 적재 건수 (NULL 시각 포함)" "$(tq "SELECT count(*) FROM app_new.logs")" 25000
check "meas 적재 건수 (PK 없음, NULL 포함)" "$(tq "SELECT count(*) FROM app_new.meas")" 25000
check "대소문자 혼용 이름 유지" "$(tq "SELECT count(*) FROM app_new.\"MixedCase\" WHERE \"Val\" IS NOT NULL")" 300

echo "== index / verify / fk =="
"$M" index
check "PK 생성" "$(tq "SELECT count(*) FROM pg_constraint WHERE contype = 'p' AND connamespace = 'app_new'::regnamespace")" 10
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

echo "== repair 후 FK 고아 행 검사 =="
# 소스에서 부모(customers 5) 삭제 → 타깃 customers 청크 불일치 → repair(FK 끈 상태로 재적재) → 자식 orders 가 고아
"${P[@]}" -d pgmig_st_src -c "DELETE FROM app.customers WHERE id = 5"
"$M" verify full >/dev/null 2>&1 || true
"$M" repair > "$WORK/repair_fk.log" 2>&1 || true
grep -q "FK 고아 행 발견" "$WORK/repair_fk.log" && ok "repair 후 FK 고아 행 경고" || { bad "FK 고아 경고 없음"; cat "$WORK/repair_fk.log"; }
check "고아 행 수 (cust=5 인 orders)" "$(tq "SELECT orphans FROM pgmig.fk_orphans(ARRAY(SELECT id FROM pgmig.tables WHERE src_table = 'customers')) WHERE fk = 'orders_cust_fk'")" \
      "$("${P[@]}" -d pgmig_st_tgt -At -c "SELECT count(*) FROM app_new.orders WHERE cust = 5")"
check "고아 경고가 이슈로 기록" "$(tq "SELECT count(*) FROM pgmig.issues WHERE level = 'WARN' AND object = 'repair' AND msg LIKE 'orders_cust_fk%'")" 1
# 원상복구: 소스에 다시 넣고 repair → 고아 없음
"${P[@]}" -d pgmig_st_src -c "INSERT INTO app.customers VALUES (5, 'cust5')"
"$M" verify full >/dev/null 2>&1 || true
"$M" repair > "$WORK/repair_fk2.log" 2>&1
grep -q "FK 고아 행 없음" "$WORK/repair_fk2.log" && ok "부모 복구 후 고아 없음" || bad "복구 후에도 고아"

echo "== 중단된 청크(세션 죽음 = 적재 롤백 + running 상태로 남음) 재시도 =="
tq "TRUNCATE app_new.codes;
    UPDATE pgmig.tasks SET status = 'running' WHERE table_id = (SELECT id FROM pgmig.tables WHERE src_table = 'codes')" >/dev/null
"$M" data
check "재시도 후 codes 건수" "$(tq "SELECT count(*) FROM app_new.codes")" 200
"$M" cleanup >/dev/null 2>&1 && bad "미검증 청크가 있는데 cleanup 이 됨" || ok "미검증 상태에서 cleanup 거부"
"$M" verify full

echo "== 이관 기간 중 소스 변경 (sync: 범위 밖 신규 행 + verify/redo) =="
sq() { "${P[@]}" -d pgmig_st_src -At -c "$1"; }
sq "UPDATE app.orders SET memo = '소스 변경' WHERE id = 150003;              -- 기존 범위 안 값 변경
    DELETE FROM app.orders WHERE id = 60000;                                -- 기존 범위 안 삭제
    INSERT INTO app.orders (id, cust, amount, memo, created, note, ratio)   -- PK 최대값 밖 신규 15000행 (> CHUNK_ROWS)
      SELECT 300000 + g * 3, 1 + g % 500, g, 'new', now(), 'n', 1 FROM generate_series(1, 15000) g;
    INSERT INTO app.logs SELECT 'N' || lpad(g::text, 8, '0'), timestamp '2030-01-01' + g * interval '1.5 second', 'new'
      FROM generate_series(1, 500) g;                                       -- 시각 범위 밖 신규
    INSERT INTO app.logs VALUES ('NNULL', NULL, 'null 시각');               -- NULL -> 첫 청크
    INSERT INTO app.meas SELECT 100000 + g, g FROM generate_series(1, 300) g;
    UPDATE app.meas SET v = v + 1 WHERE grp = 5                             -- PK 없는 테이블 값 변경" >/dev/null
TAIL=$(tq "SELECT k.id FROM pgmig.tasks k JOIN pgmig.tables t ON t.id = k.table_id WHERE t.src_table = 'orders' AND k.hi IS NULL")
TAIL_FIN=$(tq "SELECT finished FROM pgmig.tasks WHERE id = $TAIL")
NTASK=$(tq "SELECT count(*) FROM pgmig.tasks")
rc=0; "$M" sync --max-minutes 0 >"$WORK/sync0.log" 2>&1 || rc=$?
check "sync 마감 지남: 종료코드 3, 아무것도 안 함" "$rc/$(tq "SELECT count(*) FROM pgmig.tasks")" "3/$NTASK"
"$M" status >/dev/null
rc=0; "$M" sync >"$WORK/sync.log" 2>&1 || rc=$?
check "sync 종료코드" "$rc" 0
[ $rc -eq 0 ] || cat "$WORK/sync.log"
check "sync 후 전 청크 검증 OK" "$(tq "SELECT count(*) FROM pgmig.tasks WHERE status <> 'done' OR v_status IS DISTINCT FROM 'ok'")" 0
check "orders 마지막 청크를 적재된 최대값 다음에서 닫음" "$(tq "SELECT hi FROM pgmig.tasks WHERE id = $TAIL")" 300001
check "  닫은 청크는 재적재하지 않음" "$(tq "SELECT finished FROM pgmig.tasks WHERE id = $TAIL")" "$TAIL_FIN"
check "  신규 15000행 -> CHUNK_ROWS 단위 새 청크 2개" "$(tcnt orders "k.lo >= 300001")" 2
check "orders 건수 = 소스" "$(tq "SELECT count(*) FROM app_new.orders")" "$(sq "SELECT count(*) FROM app.orders")"
check "  기존 범위 안 변경 반영 (verify -> redo)" "$(tq "SELECT memo FROM app_new.orders WHERE id = 150003")/$(tq "SELECT count(*) FROM app_new.orders WHERE id = 60000")" "소스 변경/0"
check "logs 시각 범위 밖 신규 -> 새 청크 1개 (time)" "$(tcnt logs)" 4
check "  닫은 경계 = 적재된 최대 시각 + 1µs" "$(tq "SELECT lo = extract(epoch FROM timestamp '2024-01-01' + 24999 * interval '1 minute' + interval '2 ms') + 0.000001
                                              FROM pgmig.tasks k JOIN pgmig.tables t ON t.id = k.table_id WHERE t.src_table = 'logs' AND k.hi IS NULL")" t
check "logs 건수 = 소스 (NULL 시각 행 포함)" "$(tq "SELECT count(*) FROM app_new.logs")" "$(sq "SELECT count(*) FROM app.logs")"
check "meas 건수/합계 = 소스 (PK 없음)" "$(tq "SELECT count(*) || '/' || sum(v) FROM app_new.meas")" "$(sq "SELECT count(*) || '/' || sum(v) FROM app.meas")"
H="SELECT sum(hashtextextended(x::text, 0)) FROM"
check "전 컬럼 해시 = 소스 (orders/logs/meas)" \
      "$(tq "$H app_new.orders x")/$(tq "$H app_new.logs x")/$(tq "$H app_new.meas x")" \
      "$(sq "$H app.orders x")/$(sq "$H app.logs x")/$(sq "$H app.meas x")"
rc=0; "$M" sync >"$WORK/sync2.log" 2>&1 || rc=$?
check "변경 없을 때 sync 재실행: 새 청크/재적재 없음" "$rc/$(grep -c '재이관 (해당' "$WORK/sync2.log" || true)" "0/0"

echo "== report / cleanup =="
"$M" report "$WORK/report.txt"
check "리포트 생성" "$(grep -c '== 2. 테이블별 결과 ==' "$WORK/report.txt")" 1
cp "$WORK/report.txt" /tmp/pgmig_selftest_report.txt
"$M" cleanup
check "cleanup 후 pgmig 스키마" "$(tq "SELECT count(*) FROM pg_namespace WHERE nspname LIKE 'pgmig%'")" 0
check "cleanup 후 foreign server" "$(tq "SELECT count(*) FROM pg_foreign_server")" 0
check "cleanup 후 postgres_fdw 확장" "$(tq "SELECT count(*) FROM pg_extension WHERE extname = 'postgres_fdw'")" 0
check "cleanup 후 데이터는 그대로" "$(tq "SELECT count(*) FROM app_new.orders")" 114999

"${P[@]}" -d postgres -c "DROP DATABASE pgmig_st_src" -c "DROP DATABASE pgmig_st_tgt"
rm -rf "$WORK"
echo
echo "결과: PASS $pass / FAIL $fail"
[ "$fail" -eq 0 ]
