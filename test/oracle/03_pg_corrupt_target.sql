-- =====================================================================
-- 시나리오 B: target(PostgreSQL) 데이터가 깨진 경우 -> verify 가 잡는지, repair 로 복구되는지
--   실행 시점: verify 가 전부 OK 인 상태에서
--   실행: psql -d <테스트 DB> -f 03_pg_corrupt_target.sql
--   기대: ./pgmig.sh verify full -> 아래 5개 테이블의 청크가 불일치
--         ./pgmig.sh diff <task>  -> 어떤 PK 가 없음/값 다름인지
--         ./pgmig.sh repair       -> 해당 청크만 삭제 후 재적재, 재검증 OK
-- =====================================================================
DELETE FROM app.orders WHERE order_id = 150000;                        -- 행 누락
UPDATE app.orders SET note = '변조' WHERE order_id = 270000;            -- 값 변조
UPDATE app.all_types SET c_blob = c_blob || '\x00'::bytea WHERE id = 5; -- 큰 BLOB 끝에 1바이트
INSERT INTO app.no_pk_log VALUES ('2024-01-01', 'extra row');          -- PK 없는 테이블에 행 추가
UPDATE app.sales_range SET amount = amount + 1 WHERE sale_id = 77;     -- 파티션 테이블 값 변조
