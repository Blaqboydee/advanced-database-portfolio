-- =====================================================================
-- OwoTrust Digital Bank (simulated) - Portfolio 2
-- 04_advanced.sql : optimisation techniques beyond adding indexes
-- Run AFTER 03_indexes.sql.
--
--   A. Planner statistics: why Q1b and Q1c get different plans
--   B. Correctness trap: NOT IN vs NOT EXISTS when NULLs are present
--   C. Memory: work_mem and the disk spills seen in Q6 / Q7
--   D. Materialized view for the Q7 dashboard
-- =====================================================================

SET timezone = 'Africa/Lagos';
SET statement_timeout = '60s';   -- safety net: nothing in this script should come close


\echo
\echo '===================================================================='
\echo 'A. PLANNER STATISTICS (collected by ANALYZE, stored in pg_stats)'
\echo '===================================================================='
\echo 'n_distinct = estimated number of distinct debit accounts.'
\echo 'most_common_vals/freqs = the busiest accounts and their share of rows.'
\echo 'correlation = how closely the physical row order follows the column order (1 = perfectly).'
SELECT attname,
       n_distinct,
       (most_common_vals::text::text[])[1:5] AS top5_values,
       most_common_freqs[1:5]                AS top5_share_of_rows,
       round(correlation::numeric, 3)        AS physical_order_correlation
FROM pg_stats
WHERE tablename = 'bank_transaction' AND attname IN ('debit_account_id', 'created_at', 'amount');

\echo
\echo 'Extended (expression) statistics created in 03_indexes.sql: the planner now'
\echo 'knows the month expression has only a few hundred distinct values.'
SELECT statistics_name, expr, n_distinct
FROM pg_stats_ext_exprs
WHERE statistics_name = 'st_txn_month_channel';

\echo
\echo 'A1. Account id taken from a CTE (unknown when the plan is made):'
\echo '    the planner assumes an AVERAGE account (~19 rows) and chooses bitmap scan + sort.'
EXPLAIN (ANALYZE, BUFFERS)
WITH a AS (SELECT account_id FROM account WHERE account_number = '3100000001')
SELECT t.created_at, t.reference, t.amount
FROM bank_transaction t JOIN a ON t.debit_account_id = a.account_id
ORDER BY t.created_at DESC LIMIT 20;

\echo
\echo 'A2. Same query with the account id as a value (21):'
\echo '    the planner finds 21 in most_common_vals (see its share above), so it expects'
\echo '    thousands of rows, walks the index backwards and stops after 20 entries.'
EXPLAIN (ANALYZE, BUFFERS)
SELECT t.created_at, t.reference, t.amount
FROM bank_transaction t
WHERE t.debit_account_id = 21
ORDER BY t.created_at DESC LIMIT 20;


\echo
\echo '===================================================================='
\echo 'B. CORRECTNESS: NOT IN vs NOT EXISTS'
\echo '===================================================================='
\echo 'Question: how many accounts received NO money in the last week (since 25 Oct 2026)?'
\echo 'credit_account_id is NULL for withdrawals and fees, so the subquery contains NULLs.'
\echo
\echo 'B1. NOT IN: WRONG answer (0). "x NOT IN (..., NULL)" is never TRUE, only FALSE or UNKNOWN.'
SELECT COUNT(*) AS accounts_without_credits_NOT_IN
FROM account a
WHERE a.account_id NOT IN (SELECT t.credit_account_id FROM bank_transaction t
                           WHERE t.created_at >= TIMESTAMPTZ '2026-10-25');

\echo 'B2. NOT EXISTS: CORRECT answer, NULLs cannot match a join condition.'
SELECT COUNT(*) AS accounts_without_credits_NOT_EXISTS
FROM account a
WHERE NOT EXISTS (SELECT 1 FROM bank_transaction t
                  WHERE t.credit_account_id = a.account_id
                    AND t.created_at >= TIMESTAMPTZ '2026-10-25');

\echo 'B3. NOT IN can be repaired by excluding NULLs; it now agrees with B2.'
SELECT COUNT(*) AS accounts_without_credits_NOT_IN_fixed
FROM account a
WHERE a.account_id NOT IN (SELECT t.credit_account_id FROM bank_transaction t
                           WHERE t.created_at >= TIMESTAMPTZ '2026-10-25'
                             AND t.credit_account_id IS NOT NULL);

\echo
\echo 'B4. Plans: NOT EXISTS becomes an anti-join; NOT IN becomes a hashed subplan filter.'
\echo '    If the subquery result did not fit in work_mem, NOT IN would fall back to'
\echo '    re-scanning the subquery result for every account (quadratic time).'
EXPLAIN (COSTS OFF)
SELECT COUNT(*) FROM account a
WHERE NOT EXISTS (SELECT 1 FROM bank_transaction t
                  WHERE t.credit_account_id = a.account_id
                    AND t.created_at >= TIMESTAMPTZ '2026-10-25');
EXPLAIN (COSTS OFF)
SELECT COUNT(*) FROM account a
WHERE a.account_id NOT IN (SELECT t.credit_account_id FROM bank_transaction t
                           WHERE t.created_at >= TIMESTAMPTZ '2026-10-25'
                             AND t.credit_account_id IS NOT NULL);


\echo
\echo '===================================================================='
\echo 'C. MEMORY: work_mem (default 4MB) and the disk spills in Q6 / Q7'
\echo '===================================================================='
\echo 'TIMING OFF is used so that per-node timing overhead does not distort the totals.'
\echo
\echo 'C1. Q7 with the default work_mem: the sort spills to disk ("external merge").'
SHOW work_mem;
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT to_char(date_trunc('month', created_at), 'YYYY-MM') AS month, channel,
       COUNT(*) AS txns, SUM(amount) AS total_value
FROM bank_transaction
WHERE status = 'COMPLETED'
  AND created_at >= TIMESTAMPTZ '2026-01-01' AND created_at < TIMESTAMPTZ '2026-11-01'
GROUP BY 1, 2 ORDER BY 1, 2;

\echo
\echo 'C2. Q7 with work_mem = 64MB for this transaction only (SET LOCAL):'
\echo '    the sort now fits in memory ("quicksort"). The plan is still sort-based,'
\echo '    because the planner estimates ~520,000 groups (actual: 70). That'
\echo '    misestimate, not memory, is the real problem; see Q7b and the extended'
\echo '    statistics in 03_indexes.sql.'
BEGIN;
SET LOCAL work_mem = '64MB';
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT to_char(date_trunc('month', created_at), 'YYYY-MM') AS month, channel,
       COUNT(*) AS txns, SUM(amount) AS total_value
FROM bank_transaction
WHERE status = 'COMPLETED'
  AND created_at >= TIMESTAMPTZ '2026-01-01' AND created_at < TIMESTAMPTZ '2026-11-01'
GROUP BY 1, 2 ORDER BY 1, 2;
COMMIT;

\echo
\echo 'C3. Q6 with the default work_mem and then with 64MB. Look at the HashAggregate'
\echo '    line ("Batches", "Disk Usage") and the Execution Time of each.'
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
BEGIN;
SET LOCAL work_mem = '64MB';
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
COMMIT;


\echo
\echo '===================================================================='
\echo 'D. MATERIALIZED VIEW for the Q7 dashboard'
\echo '===================================================================='
\echo 'Q7 must aggregate ~520,000 rows on every page load. The dashboard only needs'
\echo '~140 numbers per year that change once a day, so store them pre-computed.'

DROP MATERIALIZED VIEW IF EXISTS mv_monthly_channel_stats;

\timing on
CREATE MATERIALIZED VIEW mv_monthly_channel_stats AS
SELECT date_trunc('month', created_at AT TIME ZONE 'Africa/Lagos')::date AS month,
       channel,
       COUNT(*)    AS txns,
       SUM(amount) AS total_value
FROM bank_transaction
WHERE status = 'COMPLETED'
GROUP BY 1, 2;

-- a unique index is required for REFRESH ... CONCURRENTLY (readers are not blocked)
CREATE UNIQUE INDEX ux_mv_monthly_channel ON mv_monthly_channel_stats (month, channel);
\timing off

\echo
\echo 'D1. Dashboard query against the materialized view:'
EXPLAIN (ANALYZE, BUFFERS)
SELECT to_char(month, 'YYYY-MM') AS month, channel, txns, total_value
FROM mv_monthly_channel_stats
WHERE month >= DATE '2026-01-01' AND month < DATE '2026-11-01'
ORDER BY month, channel;

\echo
\echo 'D2. Same totals as the live query? (rows returned here = mismatches; expect 0)'
WITH live AS (
    SELECT date_trunc('month', created_at AT TIME ZONE 'Africa/Lagos')::date AS month, channel,
           COUNT(*) AS txns, SUM(amount) AS total_value
    FROM bank_transaction
    WHERE status = 'COMPLETED'
      AND created_at >= TIMESTAMPTZ '2026-01-01' AND created_at < TIMESTAMPTZ '2026-11-01'
    GROUP BY 1, 2
)
SELECT * FROM live
FULL JOIN (SELECT * FROM mv_monthly_channel_stats
           WHERE month >= DATE '2026-01-01' AND month < DATE '2026-11-01') mv
       USING (month, channel)
WHERE live.txns IS DISTINCT FROM mv.txns OR live.total_value IS DISTINCT FROM mv.total_value;

\echo
\echo 'D3. The price: the view is a snapshot. It must be refreshed (e.g. nightly batch job).'
\timing on
REFRESH MATERIALIZED VIEW CONCURRENTLY mv_monthly_channel_stats;
\timing off
