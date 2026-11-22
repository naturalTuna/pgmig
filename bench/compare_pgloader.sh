#!/usr/bin/env bash
# pgmig vs pgloader (PostgreSQL -> PostgreSQL, 같은 서버) 비교
#   전제: PGHOST/PGPORT/PGUSER (superuser), postgres_fdw, pgloader 설치
#   측정: 이관 시간, 원본 대비 행 해시 일치, 컬럼 타입 보존, 타깃 변조 시 탐지·부분 복구
set -uo pipefail
BASE="$(cd "$(dirname "$0")/.." && pwd)"; W=$(mktemp -d); cd "$W"
P=(psql -X -q -v ON_ERROR_STOP=1)
t() { local s; s=$(date +%s.%N); "$@" >/dev/null 2>&1; local rc=$?; printf '%.2f' "$(echo "$(date +%s.%N)-$s" | bc)"; return $rc; }
"${P[@]}" -d postgres -c "DROP DATABASE IF EXISTS cmpsrc" -c "DROP DATABASE IF EXISTS tgt_pgmig" -c "DROP DATABASE IF EXISTS tgt_pgloader" \
          -c "CREATE DATABASE cmpsrc" -c "CREATE DATABASE tgt_pgmig" -c "CREATE DATABASE tgt_pgloader"
"${P[@]}" -d cmpsrc <<'SQL'
CREATE SCHEMA app;
CREATE TABLE app.orders (id bigint PRIMARY KEY, cust int, amount numeric(12,2), memo varchar(50), created timestamp, payload bytea, note text);
INSERT INTO app.orders SELECT g*3, 1+g%5000, (g::bigint*7919%1000000)/100.0, CASE WHEN g%7=0 THEN NULL ELSE '메모 '||g END,
  timestamp '2020-01-01' + g*interval '37 seconds', CASE WHEN g%5=0 THEN NULL ELSE decode(md5(g::text),'hex') END, repeat('x', g%40)
  FROM generate_series(1,1000000) g;
CREATE TABLE app.skew (id bigint PRIMARY KEY, v text);
INSERT INTO app.skew SELECT g, 's'||g FROM generate_series(1,290000) g;
INSERT INTO app.skew SELECT 1000000000000+g, 's'||g FROM generate_series(1,10000) g;
CREATE TABLE app.events (dev int, seq int, val text, PRIMARY KEY (dev, seq));
INSERT INTO app.events SELECT g%50, g, 'e'||g FROM generate_series(1,250000) g;
CREATE TABLE app.textpk (code varchar(20) PRIMARY KEY, v int);
INSERT INTO app.textpk SELECT 'C'||lpad(g::text,8,'0'), g FROM generate_series(1,250000) g;
ANALYZE;
SQL
H=${PGHOST:-/tmp}; PT=${PGPORT:-5432}; U=${PGUSER:-postgres}
if [[ "$H" == /* ]]; then URI="pgsql://$U@unix:$H:$PT"; else URI="pgsql://$U@$H:$PT"; fi
cat > pgl.load <<L
LOAD DATABASE FROM $URI/cmpsrc INTO $URI/tgt_pgloader
WITH include drop, create tables, create indexes, reset sequences, workers = 4, concurrency = 1;
L
# pgloader 는 가끔 COPY 도중 멈춤(이 환경에서 2회 중 1회) → 300초 제한, 실패 시 1회 재시도
x=$(t timeout 300 pgloader pgl.load) || { echo "pgloader 1회차 실패/멈춤(${x}초) → 재시도"; x=$(t timeout 300 pgloader pgl.load) || x="실패"; }
echo "pgloader 전체 : ${x}초 (검증 없음)"
cat > pgmig.conf <<C
PGDATABASE=tgt_pgmig
SRC_TYPE=postgres
SRC_PG_HOST=$H
SRC_PG_PORT=$PT
SRC_PG_DBNAME=cmpsrc
SRC_USER=$U
SRC_SCHEMAS='app'
SCHEMA_MAP='app:app'
JOBS=4
CHUNK_ROWS=100000
VERIFY_MODE=full
PROGRESS_SEC=600
C
export PGMIG_CONF=$W/pgmig.conf; M="$BASE/pgmig.sh"
tot=0; for s in install analyze schema data index; do x=$(t "$M" $s); tot=$(echo "$tot+$x"|bc); done
echo "pgmig 이관   : ${tot}초 (install~index)"
echo "pgmig 검증   : $(t "$M" verify full)초 (full: 건수 + 전 컬럼 해시)"
h() { psql -XAtd "$1" -c "select 'orders '||md5(string_agg(t::text,'|' order by id)) from app.orders t union all
  select 'skew '||md5(string_agg(t::text,'|' order by id)) from app.skew t union all
  select 'events '||md5(string_agg(t::text,'|' order by dev,seq)) from app.events t union all
  select 'textpk '||md5(string_agg(t::text,'|' order by code)) from app.textpk t" | sort; }
[[ "$(h cmpsrc)" == "$(h tgt_pgmig)" ]] && echo "pgmig    원본 해시 일치" || echo "pgmig    원본 해시 불일치"
[[ "$(h cmpsrc)" == "$(h tgt_pgloader)" ]] && echo "pgloader 원본 해시 일치" || echo "pgloader 원본 해시 불일치"
ty() { psql -XAtd "$1" -c "select string_agg(format_type(atttypid, atttypmod), ', ' order by attnum) from pg_attribute where attrelid='app.orders'::regclass and attname in ('amount','memo')"; }
echo "타입 (amount, memo): 원본=$(ty cmpsrc) / pgmig=$(ty tgt_pgmig) / pgloader=$(ty tgt_pgloader)"
for d in tgt_pgmig tgt_pgloader; do
  psql -Xq -d $d -c "DELETE FROM app.orders WHERE id = 1500000; UPDATE app.skew SET v='x' WHERE id = 1000000000005; UPDATE app.textpk SET v=-1 WHERE code='C00012345'"
done
"$M" verify full >/dev/null 2>&1 && echo "pgmig 변조 탐지 실패" || echo "pgmig 변조 탐지: 불일치 청크 $(psql -XAtd tgt_pgmig -c "select count(*) from pgmig.tasks where v_status='mismatch'")개"
echo "pgmig repair : $(t "$M" repair)초 (불일치 청크만)"
[[ "$(h cmpsrc)" == "$(h tgt_pgmig)" ]] && echo "pgmig    repair 후 원본 일치" || echo "pgmig    repair 후 불일치"
[[ "$(h cmpsrc)" == "$(h tgt_pgloader)" ]] && echo "pgloader 변조 후 일치(?)" || echo "pgloader 변조 그대로 (검증 기능 없음, 복구 = 전체 재적재)"
"$M" cleanup >/dev/null 2>&1
"${P[@]}" -d postgres -c "DROP DATABASE cmpsrc" -c "DROP DATABASE tgt_pgmig" -c "DROP DATABASE tgt_pgloader"; rm -rf "$W"
