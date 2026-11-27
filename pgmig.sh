#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 naturalTuna — https://github.com/naturalTuna/pgmig
# =====================================================================
# pgmig : FDW 기반 anyDB -> PostgreSQL 마이그레이션 (설치 -> 이관 -> 검증 -> 삭제)
#   v0.2 소스: oracle (oracle_fdw), postgres (postgres_fdw, selftest 용)
#   필요한 것: bash, psql  (target 서버에 해당 FDW 가 설치되어 있어야 함)
# =====================================================================
set -euo pipefail
umask 077   # 리포트 / 수동작업 / 임시 파일은 실행 계정만 읽기 (스키마 구조·오류 메시지 포함)

BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="${PGMIG_CONF:-$BASE/conf/pgmig.conf}"

die() { echo "[pgmig] ERROR: $*" >&2; exit 1; }
log() { echo "[pgmig $(date +%H:%M:%S)] $*"; }

usage() {
  cat <<EOF
사용법: $(basename "$0") <명령> [옵션]      (설정: \$PGMIG_CONF 또는 conf/pgmig.conf)

  install            FDW 확장/서버/유저매핑 + pgmig 스키마 설치
  analyze            소스 카탈로그 수집, 타입 매핑, 이슈 점검
  schema             target 스키마/테이블 생성, stage foreign table 생성, 청크 계획
  data               데이터 이관 (병렬 JOBS). 실패/중단된 청크만 다시 돌림
  sync               이관 기간 중 소스 변경분 반영: 범위 밖 신규 행 -> 새 청크 적재, 전 청크 재검증, 불일치 재이관
  index              PK/UK/인덱스/CHECK/시퀀스/default/identity/코멘트 생성 + ANALYZE (실패분만 재시도)
  verify [count|full]  정합성 검증 (기본 VERIFY_MODE)
  diff <태스크id> [n]  불일치 청크에서 다른 행의 PK 를 n 개까지 출력
  repair             불일치 청크만 삭제 후 재이관하고 다시 검증
  fk                 FK 생성 (실패분만 재시도)
  view               뷰 생성 시도 (실패분만 재시도. 의존 객체를 만든 뒤 다시 돌리면 됨)
  status             진행 상황 요약
  resolved <id>...   실패한 DDL 을 수동으로 처리했다고 표시 (report 의 [id] 번호)
  report [파일]      전체 리포트 txt + 수동 작업 폴더(<파일>_manual/) 저장
  cleanup [--force]  pgmig 스키마/foreign table/서버/확장 제거 (검증 전부 OK 일 때만, --force 는 무시)
  run                install(미설치 시) -> analyze -> schema -> data -> index -> verify -> fk -> view -> report

권장 순서: install -> analyze -> (report 로 이슈 확인) -> schema -> data -> index -> verify -> fk -> view -> report -> cleanup

마감 옵션 (data / verify / repair / sync / run) — 매일 정해진 시간만 이관할 때
  --until HH:MM[:SS] | 'YYYY-MM-DD HH:MM'   이 시각까지 (지난 시각이면 다음 날)     conf: UNTIL
  --max-minutes N                          지금부터 N 분까지                        conf: MAX_MINUTES
  --stop-before N                          마감 N 분 전부터 새 청크 시작 안 함 (기본 10)  conf: STOP_BEFORE_MIN
  진행 중인 청크는 끝까지 적재(커밋)하고 멈춤. 남은 청크는 다음 실행에서 이어서 진행
  종료 코드: 0 완료 / 1 실패·불일치 / 3 마감으로 멈춤(남은 작업 있음)
EOF
}

[ $# -ge 1 ] || { usage; exit 1; }
case "$1" in -h|--help|help) usage; exit 0 ;; esac

[ -f "$CONF" ] || die "설정 파일 없음: $CONF  (conf/pgmig.conf.example 을 복사해서 작성)"
# shellcheck disable=SC1090
source "$CONF"

SRC_TYPE="${SRC_TYPE:-oracle}"
JOBS="${JOBS:-4}"
CHUNK_ROWS="${CHUNK_ROWS:-500000}"
VERIFY_MODE="${VERIFY_MODE:-full}"
PROGRESS_SEC="${PROGRESS_SEC:-5}"
for v in PGHOST PGPORT PGDATABASE PGUSER PGPASSWORD; do
  if [ -n "${!v:-}" ]; then export "${v?}"; fi
done

export PGOPTIONS="${PGOPTIONS:-} -c client_min_messages=warning"
PSQL=(psql -X -q -v ON_ERROR_STOP=1)
q()  { "${PSQL[@]}" -At -c "$1"; }      # 값만
qt() { "${PSQL[@]}" -c "$1"; }          # 표로

installed()      { [ "$(q "SELECT count(*) FROM pg_namespace WHERE nspname = 'pgmig'")" = "1" ]; }
need_installed() { installed || die "pgmig 미설치. 먼저: $(basename "$0") install"; sync_conf; }

# conf 파일의 조정 가능한 값을 매 명령마다 DB(pgmig.config) 에 반영 -> conf 고치고 다시 실행하면 적용됨
#   (src_type/서버 접속정보는 install 때만. ORA_SCN 은 비어 있으면 자동으로 잡은 값을 유지)
CONF_KEYS=(schemas:SRC_SCHEMAS schema_map:SCHEMA_MAP exclude_tables:EXCLUDE_TABLES chunk_rows:CHUNK_ROWS
           chunk_split:CHUNK_SPLIT split_cols:SPLIT_COLS
           chunk_always_count:CHUNK_ALWAYS_COUNT ora_dict:ORA_DICT ora_use_scn:ORA_USE_SCN ora_prefetch:ORA_PREFETCH
           ora_lob_prefetch:ORA_LOB_PREFETCH ora_max_long:ORA_MAX_LONG ora_strip_zeros:ORA_STRIP_ZEROS
           ora_partitions:ORA_PARTITIONS)
sync_conf() {
  local kv k v args=() vals=""
  for kv in "${CONF_KEYS[@]}"; do
    k=${kv%%:*}; v=${kv#*:}
    args+=(-v "$k=${!v:-}")
    vals+="${vals:+,}('$k', :'$k')"
  done
  if [ -n "${ORA_SCN:-}" ]; then args+=(-v "ora_scn=$ORA_SCN"); vals+=",('ora_scn', :'ora_scn')"; fi
  echo "INSERT INTO pgmig.config (key, value) VALUES $vals ON CONFLICT (key) DO UPDATE SET value = excluded.value;" \
    | "${PSQL[@]}" "${args[@]}" -f - >/dev/null
}

# ---------------------------------------------------------------------
# 마감 시각 (graceful stop). DEADLINE/STOP 은 epoch 초, 없으면 빈 값
#   STOP = DEADLINE - STOP_BEFORE_MIN 분 : 이 시각 이후엔 새 청크를 시작하지 않음
# ---------------------------------------------------------------------
DEADLINE=""; STOP=""; DL_STOP=NULL; DL_END=NULL
set_deadline() {
  local now t
  now=$(date +%s)
  if [ -n "${UNTIL:-}" ]; then
    if [[ "$UNTIL" =~ ^[0-9]{1,2}:[0-9]{2}(:[0-9]{2})?$ ]]; then
      t=$(date -d "today $UNTIL" +%s) || die "--until 시각 형식 오류: $UNTIL"
      [ "$t" -gt "$now" ] || t=$(date -d "tomorrow $UNTIL" +%s)
    else
      t=$(date -d "$UNTIL" +%s 2>/dev/null) || die "--until 형식: HH:MM[:SS] 또는 'YYYY-MM-DD HH:MM[:SS]' (입력: $UNTIL)"
    fi
    DEADLINE=$t
  fi
  if [ -n "${MAX_MINUTES:-}" ]; then
    [[ "$MAX_MINUTES" =~ ^[0-9]+$ ]] || die "MAX_MINUTES / --max-minutes 는 0 이상의 정수(분)"
    t=$((now + MAX_MINUTES * 60))
    if [ -z "$DEADLINE" ] || [ "$t" -lt "$DEADLINE" ]; then DEADLINE=$t; fi
  fi
  [ -n "$DEADLINE" ] || return 0
  local m=${STOP_BEFORE_MIN:-10}
  [[ "$m" =~ ^[0-9]+$ ]] || die "STOP_BEFORE_MIN / --stop-before 는 0 이상의 정수(분)"
  STOP=$((DEADLINE - m * 60))
  DL_STOP="to_timestamp($STOP)"; DL_END="to_timestamp($DEADLINE)"
}
dl_msg() {
  [ -n "$DEADLINE" ] || return 0
  printf ', 마감 %s (새 청크는 %s 까지만 시작)' "$(date -d "@$DEADLINE" '+%m-%d %H:%M:%S')" "$(date -d "@$STOP" '+%H:%M:%S')"
}
time_up() { [ -n "$STOP" ] && [ "$(date +%s)" -ge "$STOP" ]; }

# 실패/중단된 청크를 다시 대기 상태로. 살아 있는 세션(다른 실행)이 잡고 있는 running 은 건드리지 않음
reset_stale() {
  q "UPDATE pgmig.tasks SET status = 'pending', pid = NULL
      WHERE status = 'failed'
         OR (status = 'running' AND (pid IS NULL OR pid NOT IN (SELECT pid FROM pg_stat_activity)))" >/dev/null
}

# 워커 N 개를 띄우고 끝날 때까지 진행 상황 출력.  $1=워커 SQL  $2=진행상황 SQL
run_workers() {
  local sql=$1 prog=$2 pids=() i rc=0 tick=0
  for ((i = 0; i < JOBS; i++)); do
    "${PSQL[@]}" -c "SET synchronous_commit = off" -c "$sql" >/dev/null &
    pids+=($!)
  done
  while kill -0 "${pids[@]}" 2>/dev/null; do
    sleep 1
    tick=$((tick + 1))
    if [ $((tick % PROGRESS_SEC)) -eq 0 ]; then log "$(q "$prog" || true)"; fi
  done
  for i in "${pids[@]}"; do wait "$i" || rc=1; done
  log "$(q "$prog")"
  [ $rc -eq 0 ] || log "주의: 비정상 종료한 워커 세션이 있음 (같은 명령을 다시 실행하면 이어서 진행)"
  return 0
}

# ---------------------------------------------------------------------
cmd_install() {
  installed && die "이미 설치되어 있음 (처음부터 다시 하려면 cleanup --force)"
  local ext srv map
  case "$SRC_TYPE" in
    oracle)
      ext=oracle_fdw
      [ -n "${SRC_DBSERVER:-}" ] || die "SRC_DBSERVER 필요 (예: //10.0.0.5:1521/ORCL)"
      srv="CREATE SERVER pgmig_src FOREIGN DATA WRAPPER oracle_fdw OPTIONS (dbserver :'dbserver', isolation_level :'iso');"
      ;;
    postgres)
      ext=postgres_fdw
      srv="CREATE SERVER pgmig_src FOREIGN DATA WRAPPER postgres_fdw OPTIONS (host :'shost', port :'sport', dbname :'sdb');"
      ;;
    *) die "지원하지 않는 SRC_TYPE: $SRC_TYPE (oracle | postgres)" ;;
  esac
  [ -f "$BASE/sql/src_${SRC_TYPE}.sql" ] || die "플러그인 파일 없음: sql/src_${SRC_TYPE}.sql"
  [ -n "${SRC_SCHEMAS:-}" ] || die "SRC_SCHEMAS 필요"
  [ "$(q "SELECT count(*) FROM pg_available_extensions WHERE name = '$ext'")" = "1" ] \
    || die "target 서버에 $ext 가 설치되어 있지 않음 (바이너리 먼저 설치)"
  [ "$(q "SELECT count(*) FROM pg_foreign_server WHERE srvname = 'pgmig_src'")" = "0" ] \
    || die "foreign server pgmig_src 가 이미 있음"

  if [ -n "${SRC_PASSWORD:-}" ]; then
    map="CREATE USER MAPPING FOR CURRENT_USER SERVER pgmig_src OPTIONS (user :'suser', password :'spass');"
  else
    map="CREATE USER MAPPING FOR CURRENT_USER SERVER pgmig_src OPTIONS (user :'suser');"
  fi
  local ext_created=no
  [ "$(q "SELECT count(*) FROM pg_extension WHERE extname = '$ext'")" = "0" ] && ext_created=yes

  log "설치: $ext / server pgmig_src / schema pgmig, pgmig_stage"
  {
    echo '\getenv spass PGMIG_SPASS'
    echo "CREATE EXTENSION IF NOT EXISTS $ext;"
    echo "$srv"
    echo "$map"
    cat "$BASE/sql/core.sql" "$BASE/sql/src_${SRC_TYPE}.sql"
    cat <<'EOF'
INSERT INTO pgmig.config (key, value) VALUES
  ('src_type', :'src_type'), ('ext', :'ext'), ('ext_created', :'ext_created'),
  ('schemas', :'schemas'), ('schema_map', :'schema_map'), ('exclude_tables', :'exclude_tables'),
  ('chunk_rows', :'chunk_rows'), ('chunk_always_count', :'chunk_always_count'),
  ('ora_dict', :'ora_dict'), ('ora_use_scn', :'ora_use_scn'), ('ora_scn', :'ora_scn'),
  ('ora_prefetch', :'ora_prefetch'), ('ora_lob_prefetch', :'ora_lob_prefetch'),
  ('ora_max_long', :'ora_max_long'), ('ora_strip_zeros', :'ora_strip_zeros'),
  ('ora_partitions', :'ora_partitions');
EOF
  } | PGMIG_SPASS="${SRC_PASSWORD:-}" "${PSQL[@]}" -1 \
        -v dbserver="${SRC_DBSERVER:-}" -v iso="${ORA_ISOLATION_LEVEL:-serializable}" \
        -v shost="${SRC_PG_HOST:-localhost}" -v sport="${SRC_PG_PORT:-5432}" -v sdb="${SRC_PG_DBNAME:-postgres}" \
        -v suser="${SRC_USER:-}" \
        -v src_type="$SRC_TYPE" -v ext="$ext" -v ext_created="$ext_created" \
        -v schemas="$SRC_SCHEMAS" -v schema_map="${SCHEMA_MAP:-}" -v exclude_tables="${EXCLUDE_TABLES:-}" \
        -v chunk_rows="$CHUNK_ROWS" -v chunk_always_count="${CHUNK_ALWAYS_COUNT:-off}" \
        -v ora_dict="${ORA_DICT:-all}" -v ora_use_scn="${ORA_USE_SCN:-off}" -v ora_scn="${ORA_SCN:-}" \
        -v ora_prefetch="${ORA_PREFETCH:-1000}" -v ora_lob_prefetch="${ORA_LOB_PREFETCH:-}" \
        -v ora_max_long="${ORA_MAX_LONG:-32767}" -v ora_strip_zeros="${ORA_STRIP_ZEROS:-off}" \
        -v ora_partitions="${ORA_PARTITIONS:-on}" \
        -f - >/dev/null

  if [ "$SRC_TYPE" = oracle ]; then
    log "소스 접속 테스트"
    q "SELECT oracle_diag('pgmig_src')" || die "오라클 접속 실패. 접속 정보 수정 후 cleanup --force -> install 다시"
  fi
  log "설치 완료"
}

cmd_analyze() {
  need_installed
  log "소스 카탈로그 수집 중"
  q "CALL pgmig.analyze()"
  qt "SELECT count(*) FILTER (WHERE migrate) AS \"이관 대상 테이블\", count(*) FILTER (WHERE NOT migrate) AS \"제외\" FROM pgmig.tables"
  qt "SELECT level, count(*) AS cnt FROM pgmig.issues GROUP BY level ORDER BY level"
  log "상세 내용은: $(basename "$0") report"
}

cmd_schema() {
  need_installed
  [ "$(q "SELECT count(*) FROM pgmig.tables WHERE migrate")" != "0" ] || die "이관 대상 테이블 없음 (analyze 먼저)"
  q "CALL pgmig.gen_ddl()"
  q "UPDATE pgmig.ddl SET status = 'pending', error = NULL WHERE phase = 'pre' AND status IN ('failed', 'running')"
  q "CALL pgmig.run_ddl('pre')"
  if [ "$(q "SELECT count(*) FROM pgmig.ddl WHERE phase = 'pre' AND status = 'failed'")" != "0" ]; then
    qt "SELECT object, error FROM pgmig.ddl WHERE phase = 'pre' AND status = 'failed' ORDER BY id"
    die "테이블 생성 실패 (target 에 같은 이름의 테이블이 이미 있으면 덮어쓰지 않음)"
  fi
  log "stage foreign table 생성"
  q "CALL pgmig.make_stage()"
  log "청크 계획 수립 (큰 테이블은 소스에서 min/max/count 조회)"
  q "CALL pgmig.plan_tasks()"
  qt "SELECT count(DISTINCT table_id) AS tables, count(*) AS chunks FROM pgmig.tasks"
}

PROG_DATA="SELECT format('청크 %s/%s 완료, 실패 %s, 적재 %s rows', count(*) FILTER (WHERE status = 'done'), count(*), count(*) FILTER (WHERE status = 'failed'), coalesce(sum(rows) FILTER (WHERE status = 'done'), 0)) FROM pgmig.tasks"

cmd_data() {
  need_installed
  [ "$(q "SELECT count(*) FROM pgmig.tasks")" != "0" ] || die "청크 없음 (schema 먼저)"
  if time_up; then log "이미 마감 시각$(dl_msg) -> 시작하지 않음"; return 3; fi
  reset_stale
  # 남은 청크의 stage 테이블은 현재 설정(ORA_STRIP_ZEROS, ORA_MAX_LONG 등)으로 다시 만듦
  q "CALL pgmig.make_stage(true)"
  log "데이터 이관 시작 (JOBS=$JOBS$(dl_msg))"
  load_chunks
}

# 대기 청크 적재 + 결과 판정 (0 완료 / 1 실패 / 3 마감으로 남음)
load_chunks() {
  run_workers "CALL pgmig.worker($DL_STOP, $DL_END)" "$PROG_DATA"
  if [ "$(q "SELECT count(*) FROM pgmig.tasks WHERE status = 'failed'")" != "0" ]; then
    qt "SELECT k.id AS task, pgmig.rel(k.table_id) AS tbl, pgmig.cond(k.pk_col, k.lo, k.hi, k.split_kind) AS chunk, k.status, k.error FROM pgmig.tasks k WHERE k.status = 'failed' ORDER BY k.id LIMIT 30"
    log "실패한 청크가 있음. 원인 해결 후 data 를 다시 실행하면 실패분만 재시도"
    return 1
  fi
  local left
  left=$(q "SELECT count(*) FROM pgmig.tasks WHERE status <> 'done'")
  if [ "$left" != "0" ] && [ -n "$DEADLINE" ]; then
    log "마감으로 멈춤: 남은 청크 ${left}개 (진행 중이던 청크는 커밋 완료). 다음 실행에서 이어서 진행"
    qt "SELECT pgmig.rel(table_id) AS tbl, count(*) AS \"남은 청크\" FROM pgmig.tasks WHERE status <> 'done' GROUP BY table_id ORDER BY table_id"
    return 3
  fi
  if [ "$left" != "0" ]; then
    qt "SELECT k.id AS task, pgmig.rel(k.table_id) AS tbl, pgmig.cond(k.pk_col, k.lo, k.hi, k.split_kind) AS chunk, k.status FROM pgmig.tasks k WHERE k.status <> 'done' ORDER BY k.id LIMIT 30"
    log "끝나지 않은 청크 ${left}개 (다른 실행이 진행 중이거나 워커가 비정상 종료). 다시 실행하면 이어서 진행"
    return 1
  fi
  log "데이터 이관 완료"
}

run_ddl_phase() {  # $1=phase  $2=설명
  need_installed
  q "UPDATE pgmig.ddl SET status = 'pending', error = NULL WHERE phase = '$1' AND status IN ('failed', 'running')"
  log "$2 (JOBS=$JOBS)"
  run_workers "CALL pgmig.run_ddl('$1')" \
    "SELECT format('DDL %s/%s 완료, 실패 %s', count(*) FILTER (WHERE status = 'done'), count(*), count(*) FILTER (WHERE status = 'failed')) FROM pgmig.ddl WHERE phase = '$1'"
  if [ "$(q "SELECT count(*) FROM pgmig.ddl WHERE phase = '$1' AND status = 'failed'")" != "0" ]; then
    # 병렬 실행 중 락 충돌(deadlock 등)일 수 있으니 실패분만 직렬로 한 번 더
    q "UPDATE pgmig.ddl SET status = 'pending', error = NULL WHERE phase = '$1' AND status = 'failed'"
    q "CALL pgmig.run_ddl('$1')"
  fi
  if [ "$(q "SELECT count(*) FROM pgmig.ddl WHERE phase = '$1' AND status = 'failed'")" != "0" ]; then
    qt "SELECT id, object, '[' || sqlstate || '] ' || error AS error FROM pgmig.ddl WHERE phase = '$1' AND status = 'failed' ORDER BY id"
    log "실패한 DDL 은 수동 처리 대상 -> report 의 '수동 작업 가이드' 와 <리포트>_manual/ddl_failed.sql 참고"
  fi
}

do_verify() {  # $1=mode ; v_status='pending' 인 청크만 검증.  0 OK / 1 불일치·미검증 / 3 마감으로 남음
  run_workers "CALL pgmig.verify_worker('$1', $DL_STOP)" \
    "SELECT format('검증 %s/%s, OK %s, 불일치 %s, 에러 %s', count(*) FILTER (WHERE v_status IN ('ok', 'mismatch', 'error')), count(*), count(*) FILTER (WHERE v_status = 'ok'), count(*) FILTER (WHERE v_status = 'mismatch'), count(*) FILTER (WHERE v_status = 'error')) FROM pgmig.tasks WHERE status = 'done'"
  q "UPDATE pgmig.tasks SET v_status = 'pending', pid = NULL
      WHERE v_status = 'running' AND (pid IS NULL OR pid NOT IN (SELECT pid FROM pg_stat_activity))" >/dev/null
  local bad left
  left=$(q "SELECT count(*) FROM pgmig.tasks WHERE status = 'done' AND v_status = 'pending'")
  if [ "$left" != "0" ] && [ -n "$DEADLINE" ]; then
    log "마감으로 검증 멈춤: 미검증 청크 ${left}개 (다음 실행에서 검증한 지 오래된 것부터 이어서)"
    return 3
  fi
  bad=$(q "SELECT count(*) FROM pgmig.tasks WHERE status <> 'done' OR v_status IS DISTINCT FROM 'ok'")
  if [ "$bad" != "0" ]; then
    qt "SELECT k.id AS task, pgmig.rel(k.table_id) AS tbl, pgmig.cond(k.pk_col, k.lo, k.hi, k.split_kind) AS chunk, k.status, coalesce(k.v_status, '-') AS verify, k.src_cnt, k.tgt_cnt, k.v_error FROM pgmig.tasks k WHERE k.status <> 'done' OR k.v_status IS DISTINCT FROM 'ok' ORDER BY k.id LIMIT 30"
    log "정합성 불일치/미검증 청크 ${bad}개.  행 확인: diff <task>   재이관: repair"
    return 1
  fi
  log "정합성 검증 OK (mode=$1, 전 청크 일치)"
}

cmd_verify() {
  need_installed
  local mode=${1:-$VERIFY_MODE}
  case "$mode" in count|full) ;; *) die "검증 모드는 count 또는 full" ;; esac
  [ "$(q "SELECT count(*) FROM pgmig.tasks WHERE status = 'done'")" != "0" ] || die "이관 완료된 청크 없음"
  if time_up; then log "이미 마감 시각$(dl_msg) -> 시작하지 않음"; return 3; fi
  q "UPDATE pgmig.tasks SET v_status = 'pending' WHERE status = 'done'" >/dev/null
  log "정합성 검증 시작 (mode=$mode, JOBS=$JOBS$(dl_msg))"
  do_verify "$mode"
}

cmd_diff() {
  need_installed
  [ $# -ge 1 ] || die "사용법: diff <태스크id> [개수]"
  [[ "$1" =~ ^[0-9]+$ && "${2:-20}" =~ ^[0-9]+$ ]] || die "태스크id/개수는 숫자"
  qt "SELECT * FROM pgmig.diff($1, ${2:-20})"
}

cmd_repair() {
  need_installed
  local n ids rc=0
  if time_up; then log "이미 마감 시각$(dl_msg) -> 시작하지 않음"; return 3; fi
  q "UPDATE pgmig.tasks SET status = 'pending', redo = true WHERE status = 'done' AND v_status = 'mismatch'" >/dev/null
  # 이전 실행에서 마감으로 못 끝낸 재이관 청크도 같이
  ids=$(q "SELECT coalesce(string_agg(DISTINCT table_id::text, ','), '') FROM pgmig.tasks WHERE redo AND status <> 'done'")
  n=$(q "SELECT count(*) FROM pgmig.tasks WHERE redo AND status <> 'done'")
  if [ "$n" = "0" ]; then log "불일치 청크 없음"; return 0; fi
  log "불일치 청크 ${n}개 재이관 (해당 범위 삭제 후 다시 적재$(dl_msg))"
  reset_stale
  q "CALL pgmig.make_stage(true)"
  load_chunks || rc=$?
  [ $rc -eq 1 ] && return 1
  q "UPDATE pgmig.tasks SET v_status = 'pending' WHERE status = 'done' AND v_status IS NULL" >/dev/null
  # repair 는 FK/트리거를 끄고(session_replication_role=replica) 지웠다 넣으므로 고아 행 검사
  local orph
  orph=$(q "SELECT coalesce(string_agg(format('%s: %s -> %s 고아 %s행', fk, child, parent, orphans), E'\n'), '')
              FROM pgmig.fk_orphans('{${ids}}'::int[]) WHERE orphans > 0")
  if [ -n "$orph" ]; then
    log "WARN FK 고아 행 발견 (재이관 중 소스에서 부모 행이 바뀐 경우 등) — 확인 필요:"
    printf '%s\n' "$orph" | sed 's/^/    /'
    printf '%s\n' "$orph" | while IFS= read -r line; do
      q "INSERT INTO pgmig.issues (level, object, msg) VALUES ('WARN', 'repair', $(printf "%s" "$line" | sed "s/'/''/g; s/^/'/; s/$/'/"))" >/dev/null
    done
  elif [ -n "$ids" ]; then
    log "FK 고아 행 없음 (재이관 테이블 관련 FK 검사)"
  fi
  [ $rc -eq 3 ] && return 3
  log "재이관한 청크 재검증 (mode=$VERIFY_MODE)"
  do_verify "$VERIFY_MODE"
}

# 이관 기간(며칠~몇 주) 중 소스가 계속 바뀌는 경우의 따라잡기.  0 전부 일치 / 1 실패·불일치 남음 / 3 마감
#   1) 분할 컬럼 범위 밖 신규 행: 적재가 끝난 마지막 청크를 닫고 그 뒤를 새 청크로 (catchup)
#   2) 대기 청크 적재 (신규 청크 + 전날 마감으로 못 한 청크)
#   3) 전 청크 재검증 (검증한 지 오래된 것부터 -> 시간 제한으로 며칠에 나눠 돌려도 한 바퀴 돎)
#   4) 불일치 청크(기존 범위 안의 UPDATE/DELETE) 만 삭제 후 재이관 -> 재검증
#   소스를 멈춘 뒤(컷오버) 마감 없이 한 번 더 돌리면 최종 정합성 확정
cmd_sync() {
  need_installed
  [ "$(q "SELECT count(*) FROM pgmig.tasks")" != "0" ] || die "청크 없음 (schema 먼저)"
  if time_up; then log "이미 마감 시각$(dl_msg) -> 시작하지 않음"; return 3; fi
  local rc=0
  log "sync: 이관 기간 중 소스 변경분 반영 (JOBS=$JOBS$(dl_msg))"
  [ "$VERIFY_MODE" = full ] || log "주의: VERIFY_MODE=$VERIFY_MODE 는 건수만 비교 -> 값만 바뀐(UPDATE) 행은 못 잡음. sync 는 full 권장"
  if [ "$(q "SELECT pgmig.cfg('ora_use_scn', 'off')")" = on ] && [ -z "${ORA_SCN:-}" ]; then
    q "DELETE FROM pgmig.config WHERE key = 'ora_scn'" >/dev/null
    log "ORA_USE_SCN=on: 새 SCN 시점으로 다시 읽음 (이전 SCN 은 undo 보존 기간이 지났을 수 있음)"
  fi
  q "CALL pgmig.make_stage(false)"

  log "[1/4] 분할 컬럼 범위 밖 신규 행 -> 새 청크"
  local out
  out=$("${PSQL[@]}" -c "SELECT * FROM pgmig.catchup()")
  printf '%s\n' "$out"
  reset_stale

  log "[2/4] 대기 청크 적재"
  load_chunks || rc=$?
  [ $rc -eq 0 ] || return $rc

  log "[3/4] 전 청크 재검증 (mode=$VERIFY_MODE, 검증한 지 오래된 것부터)"
  q "UPDATE pgmig.tasks SET v_status = 'pending' WHERE status = 'done' AND v_status IS DISTINCT FROM 'mismatch'" >/dev/null
  do_verify "$VERIFY_MODE" || rc=$?
  [ $rc -eq 3 ] && return 3
  if [ $rc -eq 0 ]; then log "sync 완료: 전 청크 소스와 일치"; return 0; fi

  log "[4/4] 불일치 청크 재이관"
  rc=0; cmd_repair || rc=$?
  [ $rc -eq 0 ] && log "sync 완료: 전 청크 소스와 일치"
  return $rc
}

cmd_view() {
  need_installed
  [ "$(q "SELECT count(*) FROM pgmig.views")" != "0" ] || { log "이관할 뷰 없음"; return 0; }
  log "뷰 생성 시도 (의존 순서대로 될 때까지 반복)"
  q "CALL pgmig.run_views()"
  qt "SELECT count(*) FILTER (WHERE status = 'done') AS \"생성\", count(*) FILTER (WHERE status = 'manual') AS \"수동생성\", count(*) FILTER (WHERE status = 'failed') AS \"실패(수동 필요)\" FROM pgmig.views"
  if [ "$(q "SELECT count(*) FROM pgmig.views WHERE status = 'failed'")" != "0" ]; then
    qt "SELECT format('%I.%I', tgt_schema, tgt_view) AS view, '[' || sqlstate || '] ' || left(error, 80) AS error FROM pgmig.views WHERE status = 'failed' ORDER BY id"
    log "실패한 뷰는 report 실행 후 <리포트>_manual/views/*.sql 에 원문/변환문/가이드가 있음. 고쳐서 psql -f 로 실행"
  fi
}

cmd_resolved() {
  need_installed
  [ $# -ge 1 ] || die "사용법: resolved <DDL id> [id...]   (report 7번 섹션의 #번호)"
  local id
  for id in "$@"; do
    [[ "$id" =~ ^[0-9]+$ ]] || die "id 는 숫자: $id"
    [ "$(q "UPDATE pgmig.ddl SET status = 'manual' WHERE id = $id AND status = 'failed' RETURNING id")" = "$id" ] \
      && log "#$id 수동 처리 완료로 표시" || log "#$id: 실패 상태 DDL 이 아님 (무시)"
  done
}

cmd_status() {
  need_installed
  qt "SELECT count(*) FILTER (WHERE migrate) AS tables, (SELECT count(*) FROM pgmig.tasks) AS chunks,
             (SELECT count(*) FROM pgmig.tasks WHERE status = 'done') AS loaded,
             (SELECT count(*) FROM pgmig.tasks WHERE status = 'failed') AS load_failed,
             (SELECT count(*) FROM pgmig.tasks WHERE v_status = 'ok') AS verified_ok,
             (SELECT count(*) FROM pgmig.tasks WHERE v_status IN ('mismatch', 'error')) AS verify_bad,
             (SELECT count(*) FROM pgmig.ddl WHERE status = 'failed') AS ddl_failed
        FROM pgmig.tables"
  qt "SELECT count(*) FILTER (WHERE status <> 'done') AS \"남은 청크\",
             round(extract(epoch FROM avg(finished - started) FILTER (WHERE status = 'done'))) AS \"청크 평균(초)\",
             round(count(*) FILTER (WHERE status <> 'done')
                   * extract(epoch FROM avg(finished - started) FILTER (WHERE status = 'done')) / $JOBS / 60) AS \"남은 적재 예상(분, JOBS=$JOBS)\",
             to_char(min(v_at) FILTER (WHERE status = 'done'), 'MM-DD HH24:MI') AS \"가장 오래된 검증\"
        FROM pgmig.tasks"
  qt "SELECT phase, status, count(*) FROM pgmig.ddl GROUP BY 1, 2
      UNION ALL SELECT 'view', status, count(*) FROM pgmig.views GROUP BY 2 ORDER BY 1, 2"
}

cmd_report() {
  need_installed
  local f=${1:-pgmig_report_$(date +%Y%m%d_%H%M%S).txt}
  {
    echo "pgmig 리포트  $(date '+%Y-%m-%d %H:%M:%S')"
    echo "source: $SRC_TYPE / schemas: $(q "SELECT pgmig.cfg('schemas')")   target db: $(q "SELECT current_database()")"
    q "SELECT 'oracle SCN 고정 읽기: ' || pgmig.cfg('ora_scn') WHERE pgmig.cfg('ora_scn') IS NOT NULL"
    echo
    echo "== 1. 요약 =="
    qt "SELECT (SELECT count(*) FROM pgmig.tables WHERE migrate) AS \"이관 테이블\",
               (SELECT count(*) FROM pgmig.tables WHERE NOT migrate) AS \"제외 테이블\",
               count(*) AS \"청크\", coalesce(sum(rows), 0) AS \"적재 rows\",
               count(*) FILTER (WHERE status <> 'done') AS \"미적재 청크\",
               count(*) FILTER (WHERE v_status = 'ok') AS \"검증 OK\",
               count(*) FILTER (WHERE v_status IN ('mismatch', 'error')) AS \"검증 불일치\",
               count(*) FILTER (WHERE status = 'done' AND v_status IS NULL) AS \"미검증\",
               (SELECT count(*) FROM pgmig.ddl WHERE status = 'failed') AS \"DDL 실패\"
          FROM pgmig.tasks"
    echo "== 2. 테이블별 결과 =="
    qt "SELECT pgmig.rel(t.id) AS tbl, count(k.id) AS chunks, sum(k.rows) AS loaded,
               sum(k.src_cnt) AS src_cnt, sum(k.tgt_cnt) AS tgt_cnt,
               CASE WHEN count(k.id) = 0 THEN '계획 전'
                    WHEN bool_or(k.status <> 'done') THEN '적재 미완료'
                    WHEN bool_or(k.v_status IN ('mismatch', 'error')) THEN '불일치'
                    WHEN bool_and(k.v_status = 'ok') THEN 'OK(' || min(k.v_mode) || ')'
                    ELSE '미검증' END AS verify,
               round(extract(epoch FROM sum(k.finished - k.started))) AS load_sec
          FROM pgmig.tables t LEFT JOIN pgmig.tasks k ON k.table_id = t.id
         WHERE t.migrate GROUP BY t.id ORDER BY t.tgt_schema, t.tgt_table"
    echo "== 3. 제외된 테이블 =="
    qt "SELECT src_schema || '.' || src_table AS src, note FROM pgmig.tables WHERE NOT migrate ORDER BY 1"
    echo "== 4. 적재 실패 / 검증 불일치 청크 =="
    qt "SELECT k.id AS task, pgmig.rel(k.table_id) AS tbl, pgmig.cond(k.pk_col, k.lo, k.hi, k.split_kind) AS chunk, k.status,
               coalesce(k.v_status, '-') AS verify, k.src_cnt, k.tgt_cnt, coalesce(k.error, k.v_error) AS error
          FROM pgmig.tasks k WHERE k.status <> 'done' OR k.v_status IN ('mismatch', 'error') ORDER BY k.id"
    echo "== 5. 파티션 테이블 =="
    qt "SELECT pgmig.rel(t.id) AS tbl, t.part_type || coalesce('-' || t.sub_type, '') AS type,
               array_to_string(t.part_cols || coalesce(t.sub_cols, '{}'), ',') AS keys,
               count(*) FILTER (WHERE p.lvl = 1) AS parts, count(*) FILTER (WHERE p.lvl = 2) AS subparts
          FROM pgmig.tables t JOIN pgmig.partitions p ON p.table_id = t.id
         WHERE t.migrate GROUP BY t.id ORDER BY 1"
    echo "== 6. 뷰 =="
    qt "SELECT format('%I.%I', tgt_schema, tgt_view) AS view, status,
               coalesce('[' || sqlstate || '] ' || left(error, 100), '') AS error
          FROM pgmig.views ORDER BY status DESC, 1"
    echo "== 7. 수동 작업 가이드 (실패한 DDL / 뷰) =="
    echo "   * 같은 내용을 SQL 파일로: ${f%.txt}_manual/ddl_failed.sql, ${f%.txt}_manual/views/*.sql"
    echo
    q "SELECT string_agg(format(E'#%s [%s] %s\\n  에러  : [%s] %s\\n  가이드: %s\\n  SQL   : %s\\n',
                               d.id, d.phase, d.object, d.sqlstate, d.error,
                               pgmig.ddl_guide(d.object, d.sqlstate, d.error, d.sql), d.sql), E'\\n' ORDER BY d.id)
         FROM pgmig.ddl d WHERE d.status = 'failed'"
    q "SELECT string_agg(format(E'[view] %s\\n  에러  : [%s] %s\\n  가이드:\\n%s\\n',
                               format('%I.%I', v.tgt_schema, v.tgt_view), v.sqlstate, v.error,
                               regexp_replace(concat_ws(E'\\n', nullif(pgmig.view_hints(v.src_text), ''),
                                                        pgmig.ddl_guide(NULL, v.sqlstate, v.error, NULL)),
                                              '^', '    - ', 'gn')), E'\\n' ORDER BY v.id)
         FROM pgmig.views v WHERE v.status = 'failed'"
    echo "== 8. 이슈 (ERROR=이관 제외, WARN=확인, MANUAL=수동 작업, INFO=참고) =="
    qt "SELECT level, object, msg FROM pgmig.issues ORDER BY CASE level WHEN 'ERROR' THEN 1 WHEN 'WARN' THEN 2 WHEN 'MANUAL' THEN 3 ELSE 4 END, object"
  } >"$f"
  log "리포트 저장: $f"
  write_manual "${f%.txt}_manual"
}

# 수동 작업 파일 떨구기 (뷰별 SQL, 실패 DDL, 수동 항목 목록, PL/SQL 객체 목록)
write_manual() {
  local dir=$1 name body n=0
  rm -rf "$dir"; mkdir -p "$dir/views"
  while IFS=$'\x1f' read -r -d $'\x1e' name body; do
    [ -n "$name" ] || continue
    [[ "$name" =~ ^[A-Za-z0-9_./\$#-]+$ && "$name" != *..* ]] || name="views/view_$n.sql"
    printf '%s\n' "$body" >"$dir/$name"
    n=$((n + 1))
  done < <("${PSQL[@]}" -At -F $'\x1f' -R $'\x1e' -c "SELECT fname, body FROM pgmig.manual_files()"; printf '\x1e')
  if [ "$(q "SELECT count(*) FROM pg_class WHERE oid = to_regclass('pgmig.oc_objects')")" = "1" ]; then
    q "SELECT owner || E'\\t' || object_type || E'\\t' || object_name FROM pgmig.oc_objects ORDER BY 1" >"$dir/plsql_objects.txt"
  fi
  rmdir "$dir/views" 2>/dev/null || true
  log "수동 작업 폴더: $dir ($(find "$dir" -type f | wc -l)개 파일)"
}

cmd_cleanup() {
  installed || die "pgmig 가 설치되어 있지 않음"
  local force=no
  [ "${1:-}" = "--force" ] && force=yes
  if [ "$force" = no ]; then
    local total bad
    total=$(q "SELECT count(*) FROM pgmig.tasks")
    bad=$(q "SELECT count(*) FROM pgmig.tasks WHERE status <> 'done' OR v_status IS DISTINCT FROM 'ok'")
    [ "$total" != "0" ] || die "이관 이력이 없음. 그래도 지우려면 cleanup --force"
    [ "$bad" = "0" ] || die "적재 미완료/미검증/불일치 청크 ${bad}개 -> 삭제 거부 (verify 먼저, 무시하려면 cleanup --force)"
    cmd_report "pgmig_final_report_$(date +%Y%m%d_%H%M%S).txt"
  fi
  local ext ext_created
  ext=$(q "SELECT pgmig.cfg('ext')")
  ext_created=$(q "SELECT pgmig.cfg('ext_created', 'no')")
  [[ "$ext" =~ ^[a-z_]+$ ]] || die "config 의 ext 값이 이상함: $ext"
  log "pgmig 제거 (한 트랜잭션. 사용자 객체가 foreign table 을 참조하고 있으면 전체 롤백)"
  local errf; errf=$(mktemp)
  {
    cat <<'EOF'
DO $$
DECLARE r record;
BEGIN
  -- CASCADE 없이 지움: 사용자 뷰/함수가 stage 테이블을 참조하면 여기서 에러 -> 롤백
  FOR r IN SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = 'pgmig_stage' AND c.relkind = 'f' LOOP
    EXECUTE format('DROP FOREIGN TABLE pgmig_stage.%I', r.relname);
  END LOOP;
END $$;
DROP SCHEMA pgmig_stage;
DROP SCHEMA pgmig CASCADE;
DROP SERVER pgmig_src CASCADE;
EOF
    # 이 툴이 만든 확장만 제거 (다른 객체가 쓰고 있으면 에러 -> 롤백)
    if [ "$ext_created" = yes ]; then echo "DROP EXTENSION $ext;"; fi
  } | "${PSQL[@]}" -1 -f - >/dev/null 2>"$errf" || { cat "$errf" >&2; rm -f "$errf"; die "제거 실패 (롤백됨)"; }
  rm -f "$errf"
  log "제거 완료. 남은 흔적 확인:"
  qt "SELECT (SELECT count(*) FROM pg_namespace WHERE nspname LIKE 'pgmig%') AS schemas,
             (SELECT count(*) FROM pg_foreign_server WHERE srvname = 'pgmig_src') AS servers,
             (SELECT count(*) FROM pg_extension WHERE extname = '$ext') AS \"$ext\""
  [ "$ext_created" = yes ] || log "$ext 확장은 설치 전부터 있었으므로 남겨둠"
  log "OS 에 설치한 FDW 바이너리/클라이언트 라이브러리는 직접 제거"
}

cmd_run() {
  installed || cmd_install
  cmd_analyze
  cmd_schema
  local rc=0
  cmd_data || rc=$?
  [ $rc -eq 3 ] && { log "마감으로 중단 -> 다음에 run(또는 data) 을 다시 실행하면 남은 청크부터"; exit 3; }
  [ $rc -eq 0 ] || die "데이터 이관 실패 -> 중단"
  run_ddl_phase post1 "PK/UK/인덱스/CHECK/시퀀스/default/identity/코멘트 생성"
  cmd_verify "$VERIFY_MODE" || rc=$?
  [ $rc -eq 3 ] && { log "마감으로 검증 중단 -> verify 를 다시 실행"; exit 3; }
  [ $rc -eq 0 ] || { cmd_report; die "정합성 검증 실패 -> FK 생성 전 중단 (diff / repair 후 fk, report)"; }
  run_ddl_phase post2 "FK 생성"
  cmd_view
  cmd_report
  log "완료. 리포트(수동 작업 가이드) 확인 후 문제 없으면: $(basename "$0") cleanup"
}

cmd=$1; shift
# 마감 옵션은 어느 위치에 와도 됨 (conf 의 UNTIL / MAX_MINUTES / STOP_BEFORE_MIN 보다 우선)
ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --until)          [ $# -ge 2 ] || die "--until 값 필요"; UNTIL=$2; shift 2 ;;
    --until=*)        UNTIL=${1#*=}; shift ;;
    --max-minutes)    [ $# -ge 2 ] || die "--max-minutes 값 필요"; MAX_MINUTES=$2; shift 2 ;;
    --max-minutes=*)  MAX_MINUTES=${1#*=}; shift ;;
    --stop-before)    [ $# -ge 2 ] || die "--stop-before 값 필요"; STOP_BEFORE_MIN=$2; shift 2 ;;
    --stop-before=*)  STOP_BEFORE_MIN=${1#*=}; shift ;;
    *) ARGS+=("$1"); shift ;;
  esac
done
set -- ${ARGS[@]+"${ARGS[@]}"}
case "$cmd" in data|verify|repair|sync|run) set_deadline ;; esac

case "$cmd" in
  install) cmd_install ;;
  analyze) cmd_analyze ;;
  schema)  cmd_schema ;;
  data)    cmd_data ;;
  sync)    cmd_sync ;;
  index)   run_ddl_phase post1 "PK/UK/인덱스/CHECK/시퀀스/default/identity/코멘트 생성" ;;
  verify)  cmd_verify "$@" ;;
  diff)    cmd_diff "$@" ;;
  repair)  cmd_repair ;;
  fk)      run_ddl_phase post2 "FK 생성" ;;
  view)    cmd_view ;;
  status)  cmd_status ;;
  resolved) cmd_resolved "$@" ;;
  report)  cmd_report "$@" ;;
  cleanup) cmd_cleanup "$@" ;;
  run)     cmd_run ;;
  *)       usage; exit 1 ;;
esac
