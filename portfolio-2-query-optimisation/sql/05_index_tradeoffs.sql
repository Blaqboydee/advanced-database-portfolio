-- =====================================================================
-- OwoTrust Digital Bank (simulated) - Portfolio 2
-- 05_index_tradeoffs.sql : what the indexes COST
-- Run AFTER 03_indexes.sql.
--
--   E. Storage: index sizes compared with the table
--   F. Partial vs full index, BRIN vs B-tree (built inside a transaction and
--      rolled back: DDL is transactional in PostgreSQL)
--   G. Write overhead: insert speed with and without the indexes
-- =====================================================================

SET timezone = 'Africa/Lagos';
SET statement_timeout = '120s';


\echo
\echo '===================================================================='
\echo 'E. STORAGE: every index is extra data that must be stored and cached'
\echo '===================================================================='
SELECT c.relname                                AS relation,
       CASE c.relkind WHEN 'r' THEN 'table' WHEN 'i' THEN 'index' END AS kind,
       COALESCE(am.amname, 'heap')              AS method,
       pg_size_pretty(pg_relation_size(c.oid))  AS size,
       round(100.0 * pg_relation_size(c.oid) / pg_relation_size('bank_transaction'), 1)
                                                AS pct_of_table
FROM pg_class c
LEFT JOIN pg_am am ON am.oid = c.relam AND c.relkind = 'i'
WHERE c.oid = 'bank_transaction'::regclass
   OR c.oid IN (SELECT indexrelid FROM pg_index WHERE indrelid = 'bank_transaction'::regclass)
ORDER BY pg_relation_size(c.oid) DESC;


\echo
\echo '===================================================================='
\echo 'F. ALTERNATIVE INDEX DESIGNS (built, measured, then rolled back)'
\echo '===================================================================='
BEGIN;

-- F1: a FULL index on (status, created_at) would also serve Q5, but it
--     indexes every row, although Q5 only ever asks for the ~0.02% PENDING ones.
CREATE INDEX tmp_full_status_created ON bank_transaction (status, created_at);

-- F2: a B-tree on created_at, the conventional alternative to the BRIN index.
CREATE INDEX tmp_btree_created ON bank_transaction (created_at);

\echo 'F1/F2. Size comparison:'
SELECT relname AS index_name, pg_size_pretty(pg_relation_size(oid)) AS size, pg_relation_size(oid) AS bytes
FROM pg_class
WHERE relname IN ('ix_txn_pending_created', 'tmp_full_status_created',
                  'brin_txn_created_at',    'tmp_btree_created')
ORDER BY bytes;

\echo
\echo 'F3. Q6 with the B-tree instead of BRIN (BRIN dropped inside this transaction).'
\echo '    Compare the Execution Time with Q6 in evidence/05_plans_after_indexing.txt.'
DROP INDEX brin_txn_created_at;
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT c.customer_id, c.first_name || ' ' || c.last_name AS customer,
       COUNT(*) AS transfers, SUM(t.amount) AS total_sent
FROM bank_transaction t
JOIN account_holder ah ON ah.account_id = t.debit_account_id AND ah.holder_role = 'PRIMARY'
JOIN customer c        ON c.customer_id = ah.customer_id
WHERE t.txn_type = 'TRANSFER' AND t.status = 'COMPLETED'
  AND t.created_at >= TIMESTAMPTZ '2026-08-03' AND t.created_at < TIMESTAMPTZ '2026-11-01'
GROUP BY c.customer_id, c.first_name, c.last_name
ORDER BY total_sent DESC LIMIT 10;

ROLLBACK;
\echo 'Rolled back: temporary indexes removed and the BRIN index restored.'


\echo
\echo '===================================================================='
\echo 'G. WRITE OVERHEAD: every INSERT must also update every index'
\echo '===================================================================='
\echo 'Copy 200,000 transactions into an empty table, 3 times without the'
\echo 'Portfolio 2 indexes and 3 times with them, and compare the average.'

DROP TABLE IF EXISTS perf_txn_copy;
CREATE TABLE perf_txn_copy (LIKE bank_transaction);
CREATE TEMP TABLE write_test (setup text, run int, ms numeric);

DO $$
DECLARE
    t0 timestamptz;
    i  int;
BEGIN
    FOR i IN 1..3 LOOP
        TRUNCATE perf_txn_copy;
        t0 := clock_timestamp();
        INSERT INTO perf_txn_copy SELECT * FROM bank_transaction WHERE txn_id <= 200000;
        INSERT INTO write_test VALUES ('no secondary indexes', i,
                                       extract(epoch FROM clock_timestamp() - t0) * 1000);
    END LOOP;

    CREATE INDEX ON perf_txn_copy (debit_account_id,  created_at);
    CREATE INDEX ON perf_txn_copy (credit_account_id, created_at);
    CREATE INDEX ON perf_txn_copy (created_at) WHERE status = 'PENDING';
    CREATE INDEX ON perf_txn_copy USING brin (created_at);

    FOR i IN 1..3 LOOP
        TRUNCATE perf_txn_copy;
        t0 := clock_timestamp();
        INSERT INTO perf_txn_copy SELECT * FROM bank_transaction WHERE txn_id <= 200000;
        INSERT INTO write_test VALUES ('with Portfolio 2 indexes', i,
                                       extract(epoch FROM clock_timestamp() - t0) * 1000);
    END LOOP;
END $$;

SELECT setup,
       round(avg(ms))                         AS avg_ms_per_200k_rows,
       round(avg(ms) * 1000 / 200000, 2)      AS avg_microseconds_per_row,
       array_agg(round(ms) ORDER BY run)      AS individual_runs_ms
FROM write_test
GROUP BY setup
ORDER BY avg_ms_per_200k_rows;

DROP TABLE perf_txn_copy;
