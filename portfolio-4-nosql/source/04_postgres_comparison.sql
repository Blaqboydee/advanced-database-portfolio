-- =====================================================================
-- OwoTrust Digital Bank (simulated) - Portfolio 4
-- 04_postgres_comparison.sql : the same questions answered by PostgreSQL,
--                              to compare with MongoDB and Neo4j fairly
-- =====================================================================

SET timezone = 'Africa/Lagos';
\timing on

\echo '=== X1. Cross-check MongoDB M5: October 2026 debits by channel (must equal the MongoDB result) ==='
SELECT channel, COUNT(*) AS debits, SUM(amount) AS total
FROM bank_transaction
WHERE status IN ('COMPLETED','REVERSED') AND debit_account_id IS NOT NULL
  AND created_at >= TIMESTAMPTZ '2026-10-01 00:00+01' AND created_at < TIMESTAMPTZ '2026-11-01 00:00+01'
GROUP BY channel ORDER BY channel;

\echo '=== X2. Neo4j G1 in SQL: shared devices. A one-hop question is easy in SQL too ==='
SELECT d.device_id, COUNT(*) AS customers, string_agg(c.first_name || ' ' || c.last_name, ', ') AS names
FROM customer_device d JOIN customer c USING (customer_id)
GROUP BY d.device_id HAVING COUNT(*) >= 3
ORDER BY customers DESC;

\echo '=== X3. Neo4j G2 in SQL: money cycles of 3-6 hops within 24 hours (recursive CTE) ==='
WITH RECURSIVE oct AS (
    SELECT debit_account_id AS src, credit_account_id AS dst, amount, created_at
    FROM bank_transaction
    WHERE txn_type = 'TRANSFER' AND status = 'COMPLETED'
      AND created_at >= TIMESTAMPTZ '2026-10-01 00:00+01' AND created_at < TIMESTAMPTZ '2026-11-01 00:00+01'
), walk AS (
    -- every October transfer is a possible first hop
    SELECT src AS start_acct, dst AS current_acct, created_at AS first_at, created_at AS last_at,
           ARRAY[src, dst] AS path, ARRAY[amount]::numeric[] AS amounts, 1 AS hops
    FROM oct
    UNION ALL
    -- extend each walk by one later transfer out of its current account
    SELECT w.start_acct, o.dst, w.first_at, o.created_at,
           w.path || o.dst, w.amounts || o.amount, w.hops + 1
    FROM walk w
    JOIN oct o ON o.src = w.current_acct
              AND o.created_at > w.last_at
              AND o.created_at < w.first_at + INTERVAL '24 hours'
    WHERE w.hops < 6
      AND w.current_acct <> w.start_acct                       -- the cycle has already closed
      AND (o.dst = w.start_acct OR NOT o.dst = ANY (w.path))   -- no revisits, except closing the cycle
)
SELECT (SELECT array_agg(a.account_number ORDER BY p.ord)
        FROM unnest(w.path) WITH ORDINALITY AS p(id, ord) JOIN account a ON a.account_id = p.id) AS cycle,
       w.hops, w.amounts,
       round(EXTRACT(EPOCH FROM w.last_at - w.first_at) / 60) AS minutes_to_complete
FROM walk w
WHERE w.current_acct = w.start_acct AND w.hops >= 3;

\echo '=== X3 plan summary: how much work the recursive CTE did ==='
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY ON)
WITH RECURSIVE oct AS (
    SELECT debit_account_id AS src, credit_account_id AS dst, amount, created_at
    FROM bank_transaction
    WHERE txn_type = 'TRANSFER' AND status = 'COMPLETED'
      AND created_at >= TIMESTAMPTZ '2026-10-01 00:00+01' AND created_at < TIMESTAMPTZ '2026-11-01 00:00+01'
), walk AS (
    SELECT src AS start_acct, dst AS current_acct, created_at AS first_at, created_at AS last_at,
           ARRAY[src, dst] AS path, ARRAY[amount]::numeric[] AS amounts, 1 AS hops
    FROM oct
    UNION ALL
    SELECT w.start_acct, o.dst, w.first_at, o.created_at, w.path || o.dst, w.amounts || o.amount, w.hops + 1
    FROM walk w
    JOIN oct o ON o.src = w.current_acct AND o.created_at > w.last_at AND o.created_at < w.first_at + INTERVAL '24 hours'
    WHERE w.hops < 6 AND w.current_acct <> w.start_acct AND (o.dst = w.start_acct OR NOT o.dst = ANY (w.path))
)
SELECT COUNT(*) FILTER (WHERE current_acct = start_acct AND hops >= 3) AS cycles,
       COUNT(*) AS partial_paths_explored
FROM walk;
