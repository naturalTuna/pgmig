-- =====================================================================
-- 시나리오 A: 이관이 끝난 뒤 소스(오라클)가 바뀐 경우 -> verify 가 잡는지, repair 로 맞춰지는지
--   실행 시점: ./pgmig.sh data (+ index, verify OK) 이후
--   실행: sqlplus system/<비번>@//<호스트>:1521/<PDB> @02_oracle_change_after_load.sql
--   기대:
--     ./pgmig.sh verify count  -> 건수가 바뀐 청크만 불일치 (ORDERS 마지막 청크, ORDER_ITEM)
--     ./pgmig.sh verify full   -> 값만 바뀐 청크까지 불일치 (ORDERS 30000 이 있는 청크, DEPT, ALL_TYPES)
--     ./pgmig.sh diff <task>   -> 바뀐 PK 표시
--     ./pgmig.sh repair        -> 불일치 청크만 다시 가져와서 전부 OK
-- =====================================================================
SET DEFINE OFF
ALTER SESSION SET CURRENT_SCHEMA = PGMIG_SRC;

-- 행 추가 (PK 최대값보다 큼 -> 마지막 청크는 상한이 없어서 여기에 포함됨)
INSERT INTO ORDERS (ORDER_ID, CUST_ID, EMPNO, ORDER_DATE, AMOUNT, STATUS, NOTE)
SELECT 900000 + LEVEL * 3, 1, 1, SYSDATE, 100, 'NEW', '이관 후 추가 ' || LEVEL FROM DUAL CONNECT BY LEVEL <= 5;

-- 값만 변경 (건수는 그대로 -> count 검증은 못 잡고 full 검증만 잡음)
UPDATE ORDERS SET AMOUNT = AMOUNT + 0.01 WHERE ORDER_ID = 30000;
UPDATE DEPT SET LOC = '부산' WHERE DEPTNO = 10;
UPDATE ALL_TYPES SET C_CLOB = C_CLOB || '!' WHERE ID = 2;    -- 큰 CLOB 끝 1글자

-- 행 삭제 (복합 PK 테이블 = 청크 1개)
DELETE FROM ORDER_ITEM WHERE ORDER_ID = 3 AND LINE_NO = 1;
COMMIT;

ALTER SESSION SET CURRENT_SCHEMA = SYSTEM;
PROMPT 소스 변경 완료. 이제 PG 쪽에서: ./pgmig.sh verify count ; ./pgmig.sh verify full
