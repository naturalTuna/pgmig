-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 naturalTuna — https://github.com/naturalTuna/pgmig
-- =====================================================================
-- 시나리오 D: 며칠에 나눠 이관하는 도중 소스(오라클)가 계속 바뀌는 경우 -> sync 가 따라잡는지
--   실행 시점: README_TEST.txt 5-[D] 의 (3) 단계 (data 를 마감으로 일부만 돌린 뒤)
--   실행: sqlplus system/<비번>@//<호스트>:1521/<PDB> @04_oracle_daily_changes.sql
--   기대 (sync 후):
--     ORDERS     : PK 최대값 밖 신규 3000건 -> 새 청크로만 적재 (기존 마지막 청크는 닫히고 재적재 안 됨)
--                  기존 범위 안 UPDATE 1건 / DELETE 1건 -> 그 청크만 verify 불일치 -> 재이관
--     NO_PK_LOG  : SPLIT_COLS 시각 컬럼 범위 밖 신규 200건 -> 새 청크 / LOG_TIME NULL 행 -> 첫 청크 재이관
-- =====================================================================
SET DEFINE OFF
ALTER SESSION SET CURRENT_SCHEMA = PGMIG_SRC;

-- 범위 밖 신규 (PK 최대값 900000 보다 큼)
INSERT INTO ORDERS (ORDER_ID, CUST_ID, EMPNO, ORDER_DATE, AMOUNT, STATUS, NOTE)
SELECT 1000000 + LEVEL * 3, MOD(LEVEL, 5000) + 1, 1, SYSDATE, 10, 'NEW', '기간 중 신규 ' || LEVEL
  FROM DUAL CONNECT BY LEVEL <= 3000;

-- 기존 범위 안 변경
UPDATE ORDERS SET NOTE = '기간 중 변경' WHERE ORDER_ID = 450000;
DELETE FROM ORDER_ITEM WHERE ORDER_ID = 600000;
DELETE FROM ORDERS WHERE ORDER_ID = 600000;

-- PK 없는 로그: 시각 범위 밖 신규 + 분할 컬럼 NULL
INSERT INTO NO_PK_LOG
SELECT TIMESTAMP '2025-06-01 00:00:00' + NUMTODSINTERVAL(LEVEL, 'SECOND'), 'daily new ' || LEVEL
  FROM DUAL CONNECT BY LEVEL <= 200;
INSERT INTO NO_PK_LOG VALUES (NULL, 'log_time 없음');
COMMIT;

SELECT 'ORDERS' t, COUNT(*) cnt FROM ORDERS UNION ALL SELECT 'NO_PK_LOG', COUNT(*) FROM NO_PK_LOG;

ALTER SESSION SET CURRENT_SCHEMA = SYSTEM;
PROMPT 소스 변경 완료. 이제 PG 쪽에서: ./pgmig.sh data ; ./pgmig.sh index ; ./pgmig.sh sync
