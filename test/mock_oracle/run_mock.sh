#!/usr/bin/env bash
# Oracle 없이 Oracle 플러그인 변환 로직(파티션/뷰/제약/default/가이드)을 점검
#   가짜 딕셔너리(mock_dictionary.sql)로 analyze -> schema -> (데이터 흉내) -> index -> fk -> view -> report
#   전제: PGHOST/PGPORT/PGUSER 로 접속 가능한 PostgreSQL (superuser)
set -euo pipefail
BASE="$(cd "$(dirname "$0")/../.." && pwd)"
WORK=${MOCK_WORK:-$(mktemp -d)}
DB=pgmig_mock
P=(psql -X -q -v ON_ERROR_STOP=1)
"${P[@]}" -d postgres -c "DROP DATABASE IF EXISTS $DB" -c "CREATE DATABASE $DB"

cat >"$WORK/pgmig.conf" <<CONF
PGDATABASE=$DB
SRC_TYPE=oracle
SRC_SCHEMAS='PGMIG_SRC,PGMIG_REF'
SCHEMA_MAP='PGMIG_SRC:app,PGMIG_REF:ref'
EXCLUDE_TABLES='PGMIG_SRC.TMP_%'
SPLIT_COLS='PGMIG_SRC.NO_PK_LOG:LOG_TIME'
CHUNK_ROWS=50000
JOBS=2
PROGRESS_SEC=60
CONF
export PGMIG_CONF="$WORK/pgmig.conf"

# install 대신: 가짜 FDW 서버 + pgmig 스키마 + 가짜 딕셔너리
{
  echo "CREATE FOREIGN DATA WRAPPER pgmig_dummy; CREATE SERVER pgmig_src FOREIGN DATA WRAPPER pgmig_dummy;"
  cat "$BASE/sql/core.sql" "$BASE/sql/src_oracle.sql"
  echo "INSERT INTO pgmig.config VALUES ('src_type','oracle'),('ext','oracle_fdw'),('ext_created','no');"
  cat "$BASE/test/mock_oracle/mock_dictionary.sql"
} | PGOPTIONS="-c client_min_messages=warning" "${P[@]}" -d $DB -1 -f - >/dev/null

M="$BASE/pgmig.sh"
cd "$WORK"
"$M" analyze
"$M" schema

# data 단계 흉내: 실패/성공이 데이터에 좌우되는 케이스만 행을 넣고 청크를 완료 처리
"${P[@]}" -d $DB <<'SQL'
INSERT INTO app.dept (deptno, dname) SELECT g * 10, 'd' || g FROM generate_series(1, 10) g;
INSERT INTO app.emp (empno, ename, mgr, deptno) SELECT g, 'e' || g, NULLIF(g % 10, 0), 10 FROM generate_series(1, 20) g;
INSERT INTO app.chk_noval VALUES (1, 5), (2, -5);
INSERT INTO app.fk_noval VALUES (1, 10), (2, 99);
INSERT INTO app.uq_noval VALUES (1, 'DUP'), (2, 'DUP'), (3, 'C3');
INSERT INTO app.sales_range VALUES (1, '2024-02-01', 1), (2, '2025-03-01', 2);
INSERT INTO app.region_list VALUES (1, 'SEOUL', 1), (2, NULL, 1), (3, 'JEJU', 1);
INSERT INTO app.sales_comp VALUES (1, '2024-03-01', 'ONLINE', 1), (2, '2024-08-01', 'PHONE', 1);
INSERT INTO app.sales_multi VALUES (1, 2023, 5, 1), (2, 2024, 7, 1), (3, 2030, 1, 1);
INSERT INTO app.acct_hash SELECT g, g FROM generate_series(1, 100) g;
INSERT INTO app.sales_interval VALUES (1, '2024-05-05', 1);
UPDATE pgmig.tasks SET status = 'done', rows = 0, v_status = 'ok', v_mode = 'full';
SQL

"$M" index || true
"$M" fk || true
"$M" view || true
"$M" report "$WORK/report.txt"

# SPLIT_COLS / 이관 기간 중 변경분(sync) 이 오라클로 보내는 범위 조건 점검 (PG 쪽 pgmig.cond 와 같은 범위여야 함)
echo "== 분할 컬럼 오라클 SQL 생성 점검 =="
fail=0
chk() {
  local got
  got=$("${P[@]}" -d $DB -At -c "$2")
  if [ "$got" = "$3" ]; then echo "  [PASS] $1"; else echo "  [FAIL] $1"; echo "     기대: $3"; echo "     실제: $got"; fail=1; fi
}
TID="(SELECT id FROM pgmig.tables WHERE src_table = 'ORDERS')"
LID="(SELECT id FROM pgmig.tables WHERE src_table = 'NO_PK_LOG')"
chk "TIMESTAMP 컬럼: 첫 청크는 NULL 포함, 마이크로초 유지" \
    "SELECT pgmig.ora_cond($LID, 'log_time', NULL, extract(epoch FROM timestamp '2024-01-01 06:00:00.5'), 'time')" \
    "(\"LOG_TIME\" < TIMESTAMP '2024-01-01 06:00:00.500000' OR \"LOG_TIME\" IS NULL)"
chk "DATE 컬럼: TO_DATE(인덱스 사용 가능), 초 단위로 올림" \
    "SELECT pgmig.ora_cond($TID, 'order_date', 1704067200.5, 1704153600, 'time')" \
    "\"ORDER_DATE\" >= TO_DATE('2024-01-01 00:00:01', 'YYYY-MM-DD HH24:MI:SS') AND \"ORDER_DATE\" < TO_DATE('2024-01-02 00:00:00', 'YYYY-MM-DD HH24:MI:SS')"
chk "DATE 컬럼 epoch 식 (분위수/min/max 용)" \
    "SELECT pgmig.ora_split_expr($TID, 'order_date', 'time')" \
    "((CAST(\"ORDER_DATE\" AS DATE) - DATE '1970-01-01') * 86400)"
chk "숫자 PK 는 기존과 같음" "SELECT pgmig.ora_cond($TID, 'order_id', 3, NULL, NULL)" "\"ORDER_ID\" >= 3"
chk "PG 쪽 조건 (stage foreign table 로 push down)" \
    "SELECT pgmig.cond('order_date', 1704067200.5, NULL, 'time')" "order_date >= '2024-01-01 00:00:00.500000+00'"
chk "SPLIT_COLS 지정 테이블 (NO_PK_LOG:LOG_TIME, 소형 -> 1청크라 분할 안 함)" \
    "SELECT count(*) FROM pgmig.issues WHERE object = 'PGMIG_SRC.NO_PK_LOG' AND msg LIKE '분할 컬럼 log_time (time)%'" 1
echo "WORK=$WORK"
[ $fail -eq 0 ]
