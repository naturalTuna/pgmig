pgmig v0.2 - FDW 기반 anyDB -> PostgreSQL 마이그레이션 툴
=====================================================================

target PostgreSQL 에 FDW 를 잠깐 설치해서 데이터를 끌어오고,
청크 단위로 정합성을 검증한 뒤, 툴 흔적을 전부 지우는 방식.

  설치(install) -> 이관(data) -> 검증(verify) -> 삭제(cleanup)

- 필요한 것: bash, psql 뿐 (python/perl 의존성 없음 -> 폐쇄망에 그대로 반입)
- 로직은 전부 target DB 안의 pgmig 스키마(PL/pgSQL)에 들어감 -> cleanup 하면 같이 사라짐
- 소스 종류별 차이는 sql/src_<type>.sql 플러그인으로 분리
    oracle   : 실사용 대상 (oracle_fdw)
    postgres : selftest 용 (postgres_fdw)
- 자동으로 못 하는 건 "시도 -> 실패 -> 리포트에 원인/가이드/고칠 SQL" 로 넘김


1. 구성
---------------------------------------------------------------------
pgmig.sh                        CLI
conf/pgmig.conf.example         설정 예시
conf/pgmig.conf.oracle-test     오라클 테스트용 설정
sql/core.sql                    공통부 (DDL 큐, 청크 태스크, 이관/검증 워커, diff, 수동 가이드)
sql/src_oracle.sql              Oracle 플러그인 (딕셔너리 수집, 타입/식/파티션/뷰 변환)
sql/src_postgres.sql            PostgreSQL 플러그인 (selftest 용)
test/selftest.sh                PG->PG 로 코어 흐름(이관/검증/불일치/재이관/삭제) 점검
test/mock_oracle/               오라클 없이 오라클 플러그인 변환 로직 점검 (가짜 딕셔너리)
test/oracle/                    실제 오라클로 하는 테스트 (데이터 생성 스크립트, 시나리오, 결과 확인)
                                -> test/oracle/README_TEST.txt 부터 읽을 것


2. 사전 준비 (Oracle 소스)
---------------------------------------------------------------------
[target PG 서버]
  - Oracle Instant Client (basic + sdk) 설치, LD_LIBRARY_PATH / ldconfig 등록
  - oracle_fdw 빌드/설치 (make && make install)
    -> pg_project 기준이면 download 단계에서 소스 tarball + Instant Client 를 같이 받아두고
       extensions 쪽에 "마이그레이션용(임시)" 항목으로 넣으면 됨
    -> Instant Client 는 재배포 라이선스 조건 확인 후 번들
  - HA 구성이면: 스탠바이 붙이기 전에 프라이머리 단독으로 이관하는 게 제일 단순.
    이미 HA 라면 전 노드에 oracle_fdw 를 설치해 둘 것

[Oracle 접속 계정] (예: test/oracle/01_oracle_testdata.sql 의 PGMIG_READER)
  - CREATE SESSION, SELECT ANY TABLE (또는 대상 테이블 SELECT)
  - SELECT ANY DICTIONARY + ORA_DICT=dba  (권장: ALL_* 뷰로는 남의 PL/SQL/시퀀스가 안 보일 수 있음)
  - ORA_USE_SCN=on 을 쓰면 FLASHBACK ANY TABLE

[target 접속 계정]
  - superuser (CREATE EXTENSION / SERVER, repair 시 session_replication_role 사용)


3. 사용법
---------------------------------------------------------------------
  cp conf/pgmig.conf.example conf/pgmig.conf ; chmod 600 conf/pgmig.conf ; vi conf/pgmig.conf

  ./pgmig.sh install       # 확장/서버/유저매핑/pgmig 스키마 설치 + 접속 테스트
  ./pgmig.sh analyze       # 소스 딕셔너리 수집, 타입 매핑, 이슈 점검
  ./pgmig.sh report        # <- 여기서 리포트의 ERROR/WARN/MANUAL 을 먼저 읽어볼 것
  ./pgmig.sh schema        # target 테이블/파티션 생성(인덱스/제약 없이), 청크 계획
  ./pgmig.sh data          # 병렬 이관. 실패하면 원인 해결 후 다시 실행 (실패분만 재시도)
  ./pgmig.sh index         # PK/UK/인덱스/CHECK/시퀀스/default/identity/코멘트 + ANALYZE
  ./pgmig.sh verify        # 정합성 검증 (기본 full)
  ./pgmig.sh diff 12       # 불일치 청크(태스크 12)에서 어떤 PK 가 다른지
  ./pgmig.sh repair        # 불일치 청크만 삭제 후 재이관 + 재검증
  ./pgmig.sh fk            # FK 생성
  ./pgmig.sh view          # 뷰 생성 시도 (의존 순서 자동, 실패분은 수동 가이드)
  ./pgmig.sh report r.txt  # 최종 리포트 r.txt + 수동 작업 폴더 r_manual/
  ./pgmig.sh resolved 85   # 실패 DDL #85 를 수동으로 처리했다고 표시
  ./pgmig.sh cleanup       # 전 청크 검증 OK 일 때만 삭제됨 (최종 리포트 자동 저장)
  ./pgmig.sh sync          # 이관 기간 중 소스 변경분 반영 (4-(7) 참고)

  data / verify / repair / sync / run 에 마감 옵션:  --until 04:00 | --max-minutes 180 | --stop-before 15
  (매일 정해진 시간만 이관하는 법은 4-(7))

  한 번에:  ./pgmig.sh run    (cleanup 직전까지. 검증 실패 시 FK 전에 멈춤)
  설정은 명령마다 다시 읽음 -> conf 고치고 같은 명령 다시 실행하면 적용 (예: ORA_STRIP_ZEROS)
  index / fk / view 는 다시 실행하면 실패한 것만 재시도

순서를 index -> verify -> fk -> view 로 둔 이유
  - verify/repair 가 청크 범위(PK)로 target 을 읽으므로 PK 인덱스가 먼저 있어야 빠름
  - PK/UK 생성 자체가 중복 검사 역할
  - FK 는 검증·재이관이 끝난 뒤에 거는 게 안전
  - 뷰는 테이블/다른 뷰가 다 있어야 만들어짐


4. 정합성을 어떻게 보장하나
---------------------------------------------------------------------
(1) 청크 = 이관/검증/재이관의 단위
    숫자 PK (단일, 또는 복합 PK 의 숫자 선두 컬럼) 테이블은 CHUNK_ROWS 단위 범위로 쪼개고,
    SPLIT_COLS 로 지정한 테이블은 그 날짜/숫자 컬럼으로 쪼개고 (아래 (7)),
    나머지는 테이블 통째로 1청크 (CHUNK_ROWS x 2 보다 크면 analyze/schema 단계에서 WARN).
    경계값은 CHUNK_SPLIT=quantile(기본) 이면 소스에서 PK 분위수(NTILE)로 정함
      -> ID 가 1~29000 + 1조 근처처럼 치우쳐도 청크 크기가 고름 (균등 분할이면 한 청크에 몰림)
      -> 소스에서 PK 를 한 번 정렬해 읽는 비용이 있음. 싫으면 CHUNK_SPLIT=uniform (예전 방식)
    첫 청크는 하한 없음 / 마지막 청크는 상한 없음 -> 범위 밖 값 누락 없음.
    청크 조건은 FDW 가 소스로 push down 하는 형태로 만들어서 청크마다 자기 범위만 읽음.

(2) 반쪽 적재가 남지 않음
    청크 INSERT 와 "done" 기록이 한 트랜잭션. 세션이 죽으면 그 청크는 통째로 롤백되고
    다음 data 실행 때 다시 적재됨. 중복 적재도 생기지 않음.

(3) 검증
    count : 청크별 건수 비교. 소스 건수는 소스 DB 에서 직접 count (빠름)
    full  : 청크별 건수 + 전 컬럼 행 해시 합 비교. 소스를 한 번 더 읽음 (느리지만 값 변조까지 잡음)
    불일치 청크는 diff 로 PK 단위 확인, repair 로 그 청크만 재이관.

(4) 조용히 바뀌는 데이터가 없게
    - 길이 초과, 0x00 문자, LONG 길이 초과 등은 잘라서 넣지 않고 청크 실패로 멈춤
      (0x00 은 ORA_STRIP_ZEROS=on 으로 명시적으로 켰을 때만 제거)
    - FLOAT -> numeric, NUMBER(정밀도 없음) -> numeric : 손실 없는 쪽으로 매핑
    - TIMESTAMP(7~9) 처럼 손실이 불가피한 건 analyze 에서 WARN 으로 미리 알림
    - target 에 같은 이름 테이블이 있으면 덮어쓰지 않고 중단

(5) cleanup 게이트
    적재 미완료/미검증/불일치 청크가 하나라도 있으면 삭제 거부 (--force 로만 무시).

(6) 소스가 살아 있는 상태에서 이관할 때
    기본은 "소스 서비스 중지 후 이관" 전제. 청크마다 읽는 시점이 다르기 때문.
    Oracle 은 ORA_USE_SCN=on 으로 모든 청크/검증을 같은 SCN 시점으로 읽을 수 있음(flashback query).
    단 undo 보존 기간 안에 끝나야 하고(ORA-01555), 그 시점 이후 변경분은 이 툴이 따라가지 않음(CDC 아님).
    며칠에 걸쳐 나눠 이관하면서 소스가 계속 바뀌는 경우는 (7) 의 sync 로 따라잡음.

(7) 큰 테이블을 매일 정해진 시간씩 나눠 이관 (예: 매일 01:00~04:00, 몇 주간)
    [마감 시각 graceful stop]
      ./pgmig.sh data --until 04:00                 04:00 마감 (지난 시각이면 다음 날 04:00)
      ./pgmig.sh data --max-minutes 180             지금부터 3시간
      conf 로 고정: UNTIL=04:00 / MAX_MINUTES=180, STOP_BEFORE_MIN=15
      - 마감 STOP_BEFORE_MIN 분 전(기본 10)부터는 새 청크를 시작하지 않음
      - 그 테이블 청크 평균 소요시간 안에 마감 전까지 못 끝낼 청크도 시작하지 않음
        (긴 청크는 건너뛰고, 남은 시간에 끝낼 수 있는 다른 테이블의 짧은 청크는 계속)
      - 진행 중인 청크는 끝까지 적재 후 커밋 -> 반쪽 적재 없음. 남은 청크는 다음 실행에서 이어서
      - 종료 코드 3 = 마감으로 멈춤(남은 작업 있음). cron 에서 실패(1)와 구분 가능
      - 청크 하나가 마감 여유(STOP_BEFORE_MIN)보다 오래 걸리면 마감을 넘길 수 있음
        -> status 의 "청크 평균(초)" 보고 CHUNK_ROWS 를 줄이거나 STOP_BEFORE_MIN 을 늘릴 것
      - status 에 남은 청크 / 청크 평균 소요 / 남은 적재 예상 시간(분) 표시
      cron 예)  0 1 * * * cd /opt/pgmig && ./pgmig.sh data --until 04:00 >> data_$(date +\%m\%d).log 2>&1

    [숫자 PK 가 없는 큰 테이블: 분할 컬럼 지정]
      SPLIT_COLS='HR.ACCESS_LOG:LOG_TIME,HR.EVENTS:SEQ_NO'     (SCHEMA.TABLE:컬럼, 소스 이름 기준)
      - 숫자 / DATE / TIMESTAMP 컬럼. 유일할 필요 없음, NULL 있어도 됨 (NULL 행은 첫 청크에 포함)
      - 경계는 PK 와 같은 방식 (분위수, 첫 청크 하한 / 마지막 청크 상한 없음 -> 누락 없음)
      - 숫자 PK 가 있는 테이블에 지정하면 PK 대신 그 컬럼으로 분할
      - schema(청크 계획) 전에 설정. 이미 계획된 테이블은 다시 계획하지 않음
      - 날짜 경계는 UTC epoch 로 계산해서 양쪽에 같은 시각 리터럴로 보냄
        (오라클 DATE 컬럼은 TO_DATE 로 보내 인덱스를 탈 수 있게)
      - 소스에 그 컬럼 인덱스가 없으면 청크마다 소스 풀스캔. 대형이면 인덱스 있는 컬럼을 고를 것
      - target 에도 그 컬럼 인덱스가 없으면 verify/sync 가 청크마다 target 풀스캔
        -> 오래 걸리면 target 에 임시 인덱스를 만들어 두고 끝나고 지울 것 (PK 가 아니므로 index 단계에서 안 만들어짐)
      - 행이 다른 청크로 옮겨가는 UPDATE(분할 컬럼 값 변경)도 sync 의 verify/redo 가 양쪽 청크를 다 맞춤

    [이관 기간 중 소스 변경분: sync]
      ./pgmig.sh sync [--until 04:00]
        1) 범위 밖 신규 행: 적재가 끝난 마지막 청크(상한 없음)를 "target 에 적재된 최대값 다음"에서 닫고,
           그 뒤를 새 청크로 추가 (신규 행이 많으면 CHUNK_ROWS 단위로 여러 개)
           -> 신규 행만 가져옴 (마지막 청크 전체를 다시 넣지 않음)
        2) 대기 청크 적재 (신규 청크 + 전날 마감으로 못 한 청크)
        3) 전 청크 재검증 (VERIFY_MODE, full 권장) — 검증한 지 오래된 청크부터.
           마감에 걸려도 다음 sync 가 이어서 돌므로 며칠에 걸쳐 한 바퀴 돎
        4) 불일치 청크(기존 범위 안의 UPDATE / DELETE / 늦게 들어온 작은 ID) 만 삭제 후 재이관 -> 재검증
      ORA_USE_SCN=on 이면 sync 할 때마다 새 SCN 으로 다시 읽음 (ORA_SCN 을 conf 에 고정했으면 그대로)

    [권장 운영 순서]
      1일차      install -> analyze -> report 확인 -> schema
      매일       data --until 04:00                     (적재 끝날 때까지. 종료 코드 3 이면 내일 계속)
      적재 완료  index                                   (PK 가 있어야 verify/sync 가 빠름)
      매일       sync --until 04:00                     (선택: 변경분을 미리 따라가서 컷오버 시간 단축)
      컷오버     소스 서비스 중지 -> sync (마감 없이)      -> 종료 코드 0 = 전 청크가 멈춘 소스와 일치
                 -> fk -> view -> report -> cleanup
      * 컷오버 다운타임 = 마지막 sync 시간 (신규 범위 적재 + 전 청크 full 검증 + 불일치 재이관)
        full 검증은 소스를 전부 다시 읽으므로, 대형 DB 면 그 시간을 미리 재 볼 것
      * 기존 범위 안의 변경은 "검증 -> 청크 통째로 재이관" 이라 변경이 고르게 퍼진 테이블은 재이관량이 큼
        (행 단위 CDC 가 아님). 그런 테이블은 컷오버 때 한 번에 처리하는 게 나음

한계 (알고 쓸 것)
    - full 검증은 "FDW 가 읽어준 값" 끼리 비교함. 즉 적재 누락/중복/변조는 잡지만,
      FDW 의 타입 변환 자체가 틀린 경우(예: 문자셋 변환)는 같은 값으로 보임
      -> 한글/특수문자 컬럼은 소스 툴(sqlplus)로 몇 건 직접 눈으로 대조 권장
    - PK 없는 테이블은 diff 불가. 청크 분할은 SPLIT_COLS 로 컬럼을 지정했을 때만 (아니면 통째로 이관·검증·재이관)
    - 문자 PK(VARCHAR2 등) 테이블도 1청크. 오라클 정렬(NLS)과 PG collation 이 달라
      청크 경계가 양쪽에서 다르게 잘릴 수 있어 아직 분할하지 않음 (대형이면 WARN -> SPLIT_COLS 로 날짜/숫자 컬럼 지정)
    - repair 는 FK/트리거를 끈 상태(session_replication_role=replica)로 지웠다 다시 넣음
      -> 끝나고 관련 FK 의 고아 행을 자동 검사해서 있으면 WARN + 이슈 기록 (차단은 안 함)


5. Oracle 지원 범위
---------------------------------------------------------------------
[자동]
  스키마        소문자로 생성. SCHEMA_MAP 으로 이름 변경
  테이블/데이터 아래 타입 매핑. NOT NULL
  PK / UK       DEFERRABLE 유지
  FK            ON DELETE CASCADE / SET NULL, DEFERRABLE 유지, 스키마 간 FK 포함
  CHECK         식 변환 후 생성 시도 (실패 -> 가이드)
  NOVALIDATE    CHECK/FK 는 NOT VALID 로 생성 + WARN
  인덱스        일반/복합/UNIQUE/DESC. 비트맵/리버스 -> btree. 함수기반은 식 변환 후 시도
  default       리터럴, SYSDATE, SYSTIMESTAMP, NVL, EMPTY_CLOB, seq.NEXTVAL 등 변환 후 시도
  시퀀스        현재 값(last_number)부터, CYCLE/CACHE/감소 시퀀스 포함
  identity      ALWAYS / BY DEFAULT, 소스 다음 값부터 (NUMBER -> bigint)
  코멘트        테이블/컬럼
  파티션        RANGE / LIST / HASH / 복합(RANGE-LIST 등 2단계), 다중 컬럼 RANGE, MAXVALUE,
                LIST 의 NULL / DEFAULT 파티션, INTERVAL(현재 있는 파티션까지)
  뷰            식별자/스키마 이름 변환, NVL->coalesce, SYSDATE, FROM DUAL 제거, MINUS->EXCEPT,
                WITH READ ONLY 제거 후 생성 시도. 의존 순서는 반복 시도로 자동 해결

[시도 후 실패하면 수동 (리포트 7번 + r_manual/ 에 원인/가이드/고칠 SQL)]
  뷰            (+) 조인, CONNECT BY, DECODE, ROWNUM, LISTAGG, TRUNC(날짜), PL/SQL 함수 호출 등
  CHECK/인덱스/default 식에 오라클 전용 함수 (LENGTHB, SUBSTRB, SYS_GUID ...)
  파티션 테이블의 PK/UK 에 파티션 키가 없는 경우 (오라클 글로벌 인덱스)
  제약 이름이 다른 테이블 이름과 같은 경우
  NOVALIDATE 였던 UNIQUE 에 중복 데이터

[이관 안 함 -> 목록만 (리포트 MANUAL, r_manual/plsql_objects.txt)]
  프로시저/함수/패키지/트리거/시노님/타입/MVIEW/DB Link/Job, GTT, 비활성(DISABLED) 제약,
  가상 컬럼의 식(값은 이관), REFERENCE/SYSTEM 파티션과 다중 컬럼 LIST 파티션(일반 테이블로),
  INTERVAL 파티션의 앞으로 생길 파티션, 유저/롤/권한

[이관 제외 (리포트 ERROR)]
  미지원 타입 컬럼이 있는 테이블 (사용자 정의 타입, SDO_GEOMETRY, ROWID, JSON, BOOLEAN ...)
  대소문자 접으면 이름이 같아지는 테이블/컬럼

타입 매핑
  VARCHAR2/NVARCHAR2(n)        varchar(n)      (n = 문자 수 기준)
  CHAR/NCHAR(n)                char(n)
  CLOB/NCLOB/LONG              text
  BLOB/RAW/LONG RAW/BFILE      bytea
  NUMBER(p,0)  p<5/p<10/p<19   smallint / integer / bigint
  NUMBER(p,0)  p>=19           numeric(p)
  NUMBER(p,s)                  numeric(p,s)
  NUMBER / 음수 scale / s>p    numeric
  FLOAT                        numeric
  BINARY_FLOAT / BINARY_DOUBLE real / double precision
  DATE                         timestamp(0)
  TIMESTAMP(n)                 timestamp(min(n,6))
  TIMESTAMP WITH [LOCAL] TZ    timestamptz
  INTERVAL ...                 interval
  XMLTYPE                      xml

이름: 대문자 이름은 소문자로, 대소문자 혼용("MixedCase")은 그대로. 63byte 넘으면 잘림(WARN).
오라클의 '' 는 NULL 이므로 그대로 NULL 로 들어옴.
시퀀스 값은 analyze 시점 기준 -> 소스 서비스 중지 후 analyze 할 것


6. 다른 도구와 비교
---------------------------------------------------------------------
[실측] pgloader 3.6.7 과 PostgreSQL -> PostgreSQL (같은 서버, PG16, JOBS/workers=4)
  데이터: orders 100만 / skew 30만(PK 치우침) / events 25만(복합 PK) / textpk 25만(문자 PK)
  재현: bash bench/compare_pgloader.sh   (결과: bench/result.txt)

                         pgmig                      pgloader
  이관 시간              5.36초 (install~index)     8.28초
  검증                   3.23초 (건수 + 전 컬럼 해시)  없음
  원본 대비 행 해시      4개 테이블 일치             4개 테이블 일치
  타입 보존              varchar(50) 유지            varchar(50) -> text (기본 캐스팅 규칙)
  타깃 변조 3건 후       verify 가 불일치 청크 3개 지목, 없음 (변조 그대로)
                         repair 3.36초로 그 청크만 복구 -> 원본과 일치
                                                     복구하려면 전체 재적재
  기타                   -                           1회 COPY 도중 멈춤 관찰 (재시도 시 정상)
  * 같은 서버 안의 FDW 라 pgmig 에 유리한 조건. 실제 Oracle -> PG 는 네트워크/oracle_fdw 속도가 좌우

[기능 비교 - 실측 못 한 것: 이 환경에 Oracle 없음]
  ora2pg              사실상 표준. PL/SQL 변환 시도, 이관 비용 산정 리포트, 병렬, 데이터 비교 테스트.
                      pgmig 는 PL/SQL 을 목록/가이드로만 넘김 -> 코드 변환은 ora2pg 쪽이 강함
  ora_migrator        (CYBERTEC) pgmig 와 같은 구조 (oracle_fdw + PG 안의 staging). 증분(incremental) 이관 지원
                      -> pgmig 는 CDC 없음. 대신 매일 시간 나눠 이관 + sync(범위 밖 신규 행 추가, verify+청크 재이관)로
                         컷오버 다운타임을 "마지막 sync 시간" 으로 줄임 (행 단위 증분은 아님)
  AWS SCT + DMS       CDC 포함, 클라우드 전제
  pgmig 강점          청크 단위 검증 -> diff(PK 지목) -> repair -> cleanup 게이트 로 이어지는 정합성 루프,
                      bash + psql 만 (폐쇄망), 끝나면 툴 흔적 제거


7. 테스트 상태 (솔직하게)
---------------------------------------------------------------------
검증된 것
  - test/selftest.sh (PG16 + postgres_fdw) 68개 항목 통과
      install ~ cleanup 전체 흐름, 병렬 청크 이관, count/full 검증, 누락·변조·초과 탐지,
      diff, repair, 중단된 청크 재시도, cleanup 게이트,
      PK 치우침 분위수 분할(최대 청크 29000 -> 10000행), 복합 PK 선두 컬럼 분할,
      문자 PK 대형 테이블 WARN, repair 후 FK 고아 행 검출,
      마감 graceful stop (conf/옵션, 진행 중 청크 커밋, 평균 소요시간 기반 청크 건너뛰기, 다음 실행 이어가기),
      SPLIT_COLS (문자 PK 테이블을 시각 컬럼으로 / PK 없는 테이블을 중복·NULL 있는 숫자 컬럼으로),
      sync (PK·시각 범위 밖 신규 행 -> 새 청크, 기존 범위 UPDATE/DELETE -> verify+redo, 소스와 전 컬럼 해시 일치)
  - test/mock_oracle/run_mock.sh : test/oracle 데이터와 같은 모양의 가짜 오라클 딕셔너리로
      타입 매핑, 파티션 DDL 과 실제 행 라우팅, 뷰 변환/의존 재시도, default/시퀀스/identity,
      실패 DDL 가이드, 수동 작업 폴더, resolved / 수동 생성 뷰 감지,
      분할 컬럼 오라클 범위 조건 생성 (DATE -> TO_DATE, TIMESTAMP, NULL 포함 첫 청크)

아직 실제 Oracle 에 붙여보지 못한 것 (개발 환경에서 Oracle 이미지를 받을 수 없었음)
  - 오라클 딕셔너리 조회 쿼리, oracle_fdw 데이터 변환, SCN 고정 읽기,
    날짜 분할 컬럼 조건의 oracle_fdw push down (README_TEST 시나리오 D)
  -> test/oracle/README_TEST.txt 순서대로 한 번 돌려보고, 기대와 다른 출력이 있으면 그대로 공유


8. 소스 DB 추가하는 법 (DB2, MSSQL, MySQL ...)
---------------------------------------------------------------------
sql/src_<type>.sql 에 아래 4개만 구현하면 core 는 그대로 씀.
  PROCEDURE pgmig.src_<type>_catalog()                   pgmig.tables/columns/constraints/indexes/sequences/
                                                         partitions/comments/views/issues 채우기
  FUNCTION  pgmig.src_<type>_stage_sql(table_id) text    CREATE FOREIGN TABLE pgmig_stage.t<id> ... 문 반환
  FUNCTION  pgmig.src_<type>_stats(table_id, col, from, kind)    (lo, hi, cnt) 반환. from 이 있으면 col >= from 범위만
  FUNCTION  pgmig.src_<type>_count(table_id, col, lo, hi, kind)  bigint 반환
    kind: NULL(숫자 PK) / num / time(lo/hi 는 epoch 초). 범위는 pgmig.cond(col, lo, hi, kind) 와 같아야 함
  (선택) FUNCTION pgmig.src_<type>_bounds(table_id, col, n, kind)  numeric[] 분위수 경계 (없으면 균등 분할)
그리고 pgmig.sh 의 cmd_install 에 CREATE SERVER 옵션 한 줄 추가.


9. 라이선스
---------------------------------------------------------------------
MIT License — Copyright (c) 2026 naturalTuna (https://github.com/naturalTuna/pgmig)
저작권 표기와 라이선스 문구(LICENSE)를 남기면 누구나 사용·수정·재배포할 수 있음.
코드 파일 상단의 SPDX-License-Identifier: MIT / Copyright 줄은 지우지 말 것.
