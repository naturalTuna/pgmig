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
echo "WORK=$WORK"
