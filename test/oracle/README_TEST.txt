pgmig Oracle -> PostgreSQL 실전 테스트 가이드
=====================================================================

파일
  01_oracle_testdata.sql         오라클에 테스트 스키마/데이터 생성 (성공 + 실패 케이스 전부)
  02_oracle_change_after_load.sql 시나리오 A: 이관 후 소스가 바뀐 경우
  03_pg_corrupt_target.sql       시나리오 B: target 데이터가 깨진 경우
  04_oracle_daily_changes.sql    시나리오 D: 며칠에 나눠 이관하는 도중 소스가 바뀌는 경우 (마감 / SPLIT_COLS / sync)
  check_result.sql               target 에서 결과 자동 확인 (PASS/FAIL/SKIP)
  ../../conf/pgmig.conf.oracle-test  이 테스트용 설정


0. 준비
---------------------------------------------------------------------
[오라클 서버]  19c 이상 (23ai Free 도 됨). DB 문자셋 AL32UTF8 권장 (한글/이모지 데이터 있음)
[PG 서버]      PostgreSQL + Oracle Instant Client + oracle_fdw 설치
               PG 서버에서 오라클 1521 포트 접속 가능해야 함
               확인: psql -c "SELECT * FROM pg_available_extensions WHERE name = 'oracle_fdw'"


1. 오라클에 테스트 데이터 생성
---------------------------------------------------------------------
  sqlplus system/<비번>@//<오라클IP>:1521/<PDB서비스명> @test/oracle/01_oracle_testdata.sql

  - 2~3분 정도 걸림 (ORDERS 30만 건)
  - 출력에 "SKIP" 이 있으면 그 DB 에디션/버전에서 안 되는 기능 (그 케이스만 빠지고 나머지 테스트는 됨)
    예) SE2 는 파티션 불가, 12.2 미만은 다중컬럼 LIST/긴 이름 불가, XML DB 없으면 XMLTYPE 불가
  - 마지막에 "INVALID" 객체가 나오면 안 됨


2. 설정
---------------------------------------------------------------------
  createdb migtest      (target 테스트 DB)
  cp conf/pgmig.conf.oracle-test conf/pgmig.conf
  chmod 600 conf/pgmig.conf
  vi conf/pgmig.conf    -> PGDATABASE, SRC_DBSERVER 만 바꾸면 됨


3. 단계별 실행과 기대 결과
---------------------------------------------------------------------
(1) ./pgmig.sh install
    기대: oracle_fdw 확장/서버 생성, 마지막에 oracle_diag 결과(오라클 버전 등) 출력
    실패하면: 접속 문자열/방화벽/Instant Client(LD_LIBRARY_PATH) 확인 후 cleanup --force -> install

(2) ./pgmig.sh analyze  그리고  ./pgmig.sh report
    기대: 이관 대상 37 / 제외 6 (에디션 따라 SKIP 된 테이블만큼 적을 수 있음)
          ERROR 4  : COLCASE(컬럼 이름 충돌), CUST_ADDR(사용자 타입), ROWID_REF(ROWID), emp_dup/EMP_DUP(이름 충돌)
          MANUAL   : PL/SQL 6종 목록(FUNCTION/PROCEDURE/PACKAGE/TRIGGER/SYNONYM/TYPE) + MVIEW,
                     GTT_SESSION, DIS_CONS 의 비활성 CHECK, VIRT_COL 가상컬럼, REF_CHILD(REFERENCE 파티션),
                     LIST_MULTI(다중컬럼 LIST), SALES_INTERVAL(INTERVAL), CUSTOMER->PGMIG_EXT FK
          WARN     : TIMESTAMP(9), PK 없음 3개, 63byte 초과 이름, SALES_INTERVAL PK 실패 예정,
                     V_CONCAT 의 || , NOVALIDATE 제약 2개
    리포트 8번(이슈) 섹션을 먼저 읽어볼 것

(3) ./pgmig.sh schema
    기대: 스키마 app, ref 생성 / 파티션 테이블은 PARTITION BY 로 생성 / ORDERS 는 6개 청크

(4) ./pgmig.sh data
    기대: NULL_CHAR 청크 1개만 실패 (0x00 문자: invalid byte sequence ... 0x00)
          "실패한 청크가 있음" 메시지
    -> conf/pgmig.conf 에서 ORA_STRIP_ZEROS=on 으로 바꾸고
       ./pgmig.sh data       (실패한 청크만 다시 돌아감 -> 전부 완료)

(5) ./pgmig.sh index
    기대 실패 6개 (전부 리포트 7번에 가이드 나옴):
      pk app.coll_t.dept                   [42P07] 제약 이름 DEPT 가 테이블 dept 와 충돌
      pk app.sales_interval.pk_sales_interval [0A000] 파티션 키 없는 PK
      unique app.uq_noval.uq_noval_code    [23505] NOVALIDATE 였던 UNIQUE 에 중복 데이터
      index app.emp.emp_ename_substrb_ix   [42883] substrb 없음
      check app.chk_fail.ck_name_bytes     [42883] lengthb 없음
      default app.def_tab.e                [42883] sys_guid 없음
    성공해야 하는 것: upper(email)/coalesce(comm,0) 함수 인덱스, DESC 인덱스, 비트맵->btree,
                      DEFERRABLE UNIQUE, CHECK NOT VALID(chk_noval), identity 2개, 시퀀스 4개, 코멘트

(6) ./pgmig.sh verify
    기대: 전 청크 OK

(7) ./pgmig.sh fk
    기대 실패 1개: fk app.sales_note.fk_note_sale [42830] (참조 PK 가 5번에서 실패했으므로)
    성공: 자기참조 FK, ON DELETE SET NULL/CASCADE, 스키마 간 FK(customer -> ref.ref_code), NOT VALID FK(fk_noval)

(8) ./pgmig.sh view
    기대: 생성 11 / 실패 9
      생성: v_emp_simple, v_emp_dept_ansi, v_emp_nvl(nvl->coalesce), v_z_base, v_a_depends(뷰 의존),
            v_dual(dual 제거), v_minus(MINUS->EXCEPT), v_cross_schema(스키마 이름 매핑), v_readonly,
            v_quoted(대소문자), v_concat
      실패: v_emp_dept_outer((+)), v_emp_tree(CONNECT BY), v_emp_decode(DECODE), v_top10(ROWNUM),
            v_listagg(LISTAGG), v_trunc(TRUNC 날짜), v_plsql_func(PL/SQL 함수), v_ext(이관 안 한 스키마),
            v_unsupported(이관 제외된 테이블)

(9) ./pgmig.sh report rpt.txt
    기대: rpt.txt + rpt_manual/ 폴더
          rpt_manual/views/app.v_*.sql   실패한 뷰마다 원문 / 에러 / 가이드 / 고칠 SQL
          rpt_manual/ddl_failed.sql      실패한 DDL + 가이드
          rpt_manual/manual_items.txt    수동 작업 목록
          rpt_manual/plsql_objects.txt   PL/SQL, 트리거 등 목록

(10) psql -d migtest -f test/oracle/check_result.sql
    기대: 전부 PASS (SKIP 은 오라클에서 그 객체가 안 만들어진 경우)
    !! 수동 처리(11번) 전에 돌릴 것. 수동 처리하면 4/5번 항목이 manual 로 바뀌어 FAIL 로 나옴

※ (1)~(9) 를 한 번에: ./pgmig.sh run  (단, 4번 NULL_CHAR 에서 멈춤 -> STRIP_ZEROS=on 후 run 다시)


4. 수동 처리 연습
---------------------------------------------------------------------
(11) 뷰 하나 고치기
     vi rpt_manual/views/app.v_emp_dept_outer.sql
        맨 아래 CREATE VIEW 의 "FROM EMP E, DEPT D WHERE E.DEPTNO = D.DEPTNO(+)" 를
        "FROM EMP E LEFT JOIN DEPT D ON E.DEPTNO = D.DEPTNO" 로 수정
     psql -d migtest -f rpt_manual/views/app.v_emp_dept_outer.sql
     ./pgmig.sh view          -> "수동생성 1" 로 집계됨

(12) 실패한 DDL 하나 고치기
     psql -d migtest -c "ALTER TABLE app.coll_t ADD CONSTRAINT coll_t_pk PRIMARY KEY (id)"
     ./pgmig.sh resolved <리포트의 #번호>      -> 리포트에서 manual 로 표시


5. 정합성 시나리오
---------------------------------------------------------------------
[A] 이관 후 소스가 바뀐 경우
    sqlplus system/...@... @test/oracle/02_oracle_change_after_load.sql
    ./pgmig.sh verify count   기대: ORDERS 마지막 청크 + ORDER_ITEM 만 불일치 (건수 변화)
    ./pgmig.sh verify full    기대: 위 + ORDERS 30000 들어있는 청크, DEPT, ALL_TYPES 불일치 (값 변화)
    ./pgmig.sh diff <task번호>  기대: 바뀐 PK 와 "값 다름 / target 에 없음 / source 에 없음"
    ./pgmig.sh repair         기대: 불일치 청크만 재적재 후 재검증 -> 전부 OK

[B] target 이 깨진 경우
    psql -d migtest -f test/oracle/03_pg_corrupt_target.sql
    ./pgmig.sh verify         기대: orders(2개 청크), all_types, no_pk_log, sales_range 불일치
    ./pgmig.sh diff <task>    (no_pk_log 는 PK 가 없어서 diff 불가 메시지)
    ./pgmig.sh repair         기대: 전부 OK

[C] 중간에 죽이기
    ./pgmig.sh data 실행 중 Ctrl+C (또는 PG 세션 kill)
    -> 다시 ./pgmig.sh data : 끝난 청크는 건너뛰고 나머지만 진행, 반쪽 적재 없음
    (처음부터 해보려면: psql 로 DROP SCHEMA app, ref CASCADE; ./pgmig.sh cleanup --force; install 부터)

[D] 매일 정해진 시간씩 나눠 이관 + 기간 중 소스 변경 (마감 / SPLIT_COLS / sync)
    처음부터 새로: psql 로 DROP SCHEMA app, ref CASCADE; ./pgmig.sh cleanup --force
    conf/pgmig.conf 에 추가:
      CHUNK_ROWS=1000                                   # ORDERS 를 300청크로 -> 마감에 걸리게
      SPLIT_COLS='PGMIG_SRC.NO_PK_LOG:LOG_TIME'         # PK 없는 로그 테이블을 TIMESTAMP 컬럼으로 분할
      ORA_STRIP_ZEROS=on
    (1) ./pgmig.sh install ; ./pgmig.sh analyze ; ./pgmig.sh schema
        기대: NO_PK_LOG 3청크 (리포트 8번 INFO "분할 컬럼 log_time (time) 로 3청크"), "1청크" WARN 없음
    (2) ./pgmig.sh data --max-minutes 1 --stop-before 0 ; echo $?
        기대: 1분 안에 멈춤, "마감으로 멈춤: 남은 청크 N개", 종료코드 3
              ./pgmig.sh status -> 남은 청크 / 청크 평균(초) / 남은 적재 예상(분)
              psql: SELECT status, count(*) FROM pgmig.tasks GROUP BY 1   -> running/failed 없음
    (3) sqlplus ... @test/oracle/04_oracle_daily_changes.sql      (이관 도중 소스 변경)
    (4) ./pgmig.sh data       (남은 청크 이어서 -> 완료)
        ./pgmig.sh index
    (5) ./pgmig.sh sync ; echo $?
        기대: [1/4] 표에 app.orders (신규 3000 -> 새 청크 3개 = 3000/CHUNK_ROWS), app.no_pk_log (신규 200 -> 1개)
              [3/4] 불일치: ORDERS 450000 / 600000 이 든 청크, NO_PK_LOG 첫 청크(NULL 행), ORDER_ITEM
              [4/4] 그 청크만 재이관 -> "sync 완료: 전 청크 소스와 일치", 종료코드 0
        확인: psql: SELECT count(*) FROM app.orders;  SELECT count(*) FROM app.no_pk_log;
              -> 04 스크립트 마지막에 출력된 오라클 건수와 같아야 함
              psql: SELECT note FROM app.orders WHERE order_id = 450000;  -> '기간 중 변경'
    (6) ./pgmig.sh sync 한 번 더 -> 새 청크 없음, 재이관 없음
    다르게 나오면 볼 것: 날짜 분할 조건의 push down (oracle_fdw 디버그: SET client_min_messages = debug2 후
                        EXPLAIN VERBOSE SELECT count(*) FROM pgmig_stage.t<id> WHERE <리포트의 청크 조건>)


6. 정리
---------------------------------------------------------------------
    ./pgmig.sh cleanup
    기대: 검증 안 끝난/불일치 청크가 있으면 거부
          전부 OK 면 최종 리포트 저장 후 pgmig, pgmig_stage 스키마, 서버, oracle_fdw 확장 제거
          (확장이 원래 있었으면 남김). 이관된 데이터/뷰는 그대로
    오라클 테스트 계정 삭제:
      DROP USER PGMIG_SRC CASCADE; DROP USER PGMIG_REF CASCADE;
      DROP USER PGMIG_EXT CASCADE; DROP USER PGMIG_READER CASCADE;


7. 기대와 다르게 나올 수 있는 곳 (실제 오라클로 처음 돌리는 부분)
---------------------------------------------------------------------
이 툴의 오라클 쪽 코드는 개발 환경에 오라클이 없어서 가짜 딕셔너리(test/mock_oracle)로만 검증됨.
아래가 다르게 나오면 그 출력 그대로 알려주면 고칠 수 있음.
  - analyze 에서 ORA-xxxxx : 딕셔너리 조회 쿼리 문제 (어느 ora_* 테이블에서 났는지 같이)
  - 뷰 원문(TEXT) 저장 형태 : 오라클 버전에 따라 SELECT * 를 펼쳐 저장하거나 그대로 둠 (결과는 같아야 함)
  - default 값 저장 형태   : ORDERS_SEQ.NEXTVAL 이 "PGMIG_SRC"."ORDERS_SEQ"."NEXTVAL" 형태로 바뀌어 있을 수 있음 (둘 다 처리)
  - BINARY_FLOAT NaN/Inf, 기원전 날짜, TIMESTAMP WITH LOCAL TIME ZONE 의 oracle_fdw 변환
  - EMPTY_BLOB 이 0바이트로 오는지 NULL 로 오는지
  - check_result.sql 의 identity 시작값 (오라클 캐시 크기에 따라 다름, 100 보다 크기만 하면 됨)
