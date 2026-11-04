-- =====================================================================
-- OwoTrust Digital Bank (simulated) - Portfolio 2
-- 02_workload.sql : the query workload being optimised
--
-- Each query is written ONCE here and run in three modes by run_all.sh,
-- controlled by the psql variable EXPLAIN that prefixes every query:
--   -v EXPLAIN=                               -> normal results
--   -v EXPLAIN='EXPLAIN (ANALYZE, BUFFERS)'   -> execution plans (before / after indexing)
--   -v EXPLAIN='EXPLAIN (ANALYZE, TIMING OFF)' -> used by benchmark.py for timings
-- The "### Qn" markers let benchmark.py match timings to queries.
-- =====================================================================

SET timezone = 'Africa/Lagos';

-- query parameters (realistic values chosen from the generated data)
\set merchant_acct  '3100000001'
\set personal_acct  '3100000100'
\set login_email    'Hauwa.Okonkwo1000@Example.com'
\set customer_bvn   '22200000100'

\echo '### Q1  Mobile app: 20 most recent transactions of an account (OR on two columns)'
:EXPLAIN
SELECT t.created_at, t.reference, t.txn_type, t.channel,
       CASE WHEN t.credit_account_id = a.account_id THEN 'CR' ELSE 'DR' END AS dr_cr,
       t.amount, t.status
FROM account a
JOIN bank_transaction t
  ON t.debit_account_id = a.account_id OR t.credit_account_id = a.account_id
WHERE a.account_number = :'merchant_acct'
ORDER BY t.created_at DESC
LIMIT 20;

\echo '### Q1b Same result as Q1, rewritten as UNION ALL of two ordered branches'
:EXPLAIN
WITH a AS (SELECT account_id FROM account WHERE account_number = :'merchant_acct')
SELECT * FROM (
    (SELECT t.created_at, t.reference, t.txn_type, t.channel, 'DR' AS dr_cr, t.amount, t.status
     FROM bank_transaction t JOIN a ON t.debit_account_id = a.account_id
     ORDER BY t.created_at DESC LIMIT 20)
    UNION ALL
    (SELECT t.created_at, t.reference, t.txn_type, t.channel, 'CR' AS dr_cr, t.amount, t.status
     FROM bank_transaction t JOIN a ON t.credit_account_id = a.account_id
     ORDER BY t.created_at DESC LIMIT 20)
) recent
ORDER BY created_at DESC
LIMIT 20;

-- The mobile app already holds the account_id after login. Look it up once
-- here so that Q1c contains the actual value, as a prepared statement would.
SELECT account_id AS merchant_id FROM account WHERE account_number = :'merchant_acct' \gset

\echo '### Q1c Same as Q1b, but the account_id is passed as a value (planner can use per-value statistics)'
:EXPLAIN
SELECT * FROM (
    (SELECT t.created_at, t.reference, t.txn_type, t.channel, 'DR' AS dr_cr, t.amount, t.status
     FROM bank_transaction t WHERE t.debit_account_id = :merchant_id
     ORDER BY t.created_at DESC LIMIT 20)
    UNION ALL
    (SELECT t.created_at, t.reference, t.txn_type, t.channel, 'CR' AS dr_cr, t.amount, t.status
     FROM bank_transaction t WHERE t.credit_account_id = :merchant_id
     ORDER BY t.created_at DESC LIMIT 20)
) recent
ORDER BY created_at DESC
LIMIT 20;

\echo '### Q2  Monthly statement (October 2026) with opening and running balance'
:EXPLAIN
WITH acct AS (
    SELECT account_id FROM account WHERE account_number = :'personal_acct'
), legs AS (
    SELECT t.txn_id, t.created_at, t.reference, t.narration,
           CASE WHEN t.credit_account_id = acct.account_id THEN t.amount ELSE -t.amount END AS delta
    FROM bank_transaction t
    JOIN acct ON t.debit_account_id = acct.account_id OR t.credit_account_id = acct.account_id
    WHERE t.status IN ('COMPLETED','REVERSED')
), opening AS (
    SELECT COALESCE(SUM(delta), 0) AS balance FROM legs WHERE created_at < TIMESTAMPTZ '2026-10-01'
)
SELECT l.created_at::date AS value_date, l.reference, l.narration,
       CASE WHEN l.delta < 0 THEN -l.delta END AS debit,
       CASE WHEN l.delta > 0 THEN  l.delta END AS credit,
       o.balance + SUM(l.delta) OVER (ORDER BY l.created_at, l.txn_id) AS running_balance
FROM legs l CROSS JOIN opening o
WHERE l.created_at >= TIMESTAMPTZ '2026-10-01' AND l.created_at < TIMESTAMPTZ '2026-11-01'
ORDER BY l.created_at, l.txn_id;

\echo '### Q3  Login: find a customer by e-mail, case-insensitive'
:EXPLAIN
SELECT customer_id, first_name, last_name, kyc_tier, status
FROM customer
WHERE lower(email) = lower(:'login_email');

\echo '### Q4  Customer-service screen: all accounts of a customer, looked up by BVN'
:EXPLAIN
SELECT c.first_name || ' ' || c.last_name AS customer, a.account_number, at.type_name,
       ah.holder_role, a.status, a.balance
FROM customer c
JOIN account_holder ah ON ah.customer_id = c.customer_id
JOIN account a         ON a.account_id   = ah.account_id
JOIN account_type at   ON at.type_code   = a.type_code
WHERE c.bvn = :'customer_bvn'
ORDER BY a.account_number;

\echo '### Q5  Fraud-review queue: oldest 50 PENDING transactions'
:EXPLAIN
SELECT txn_id, reference, created_at, channel, debit_account_id, credit_account_id, amount
FROM bank_transaction
WHERE status = 'PENDING'
ORDER BY created_at
LIMIT 50;

\echo '### Q6  Compliance: top 10 customers by value transferred out in the last 90 days'
:EXPLAIN
SELECT c.customer_id, c.first_name || ' ' || c.last_name AS customer,
       COUNT(*) AS transfers, SUM(t.amount) AS total_sent
FROM bank_transaction t
JOIN account_holder ah ON ah.account_id = t.debit_account_id AND ah.holder_role = 'PRIMARY'
JOIN customer c        ON c.customer_id = ah.customer_id
WHERE t.txn_type = 'TRANSFER'
  AND t.status   = 'COMPLETED'
  AND t.created_at >= TIMESTAMPTZ '2026-08-03'
  AND t.created_at <  TIMESTAMPTZ '2026-11-01'
GROUP BY c.customer_id, c.first_name, c.last_name
ORDER BY total_sent DESC
LIMIT 10;

\echo '### Q7  Management dashboard: monthly volume and value per channel, Jan-Oct 2026'
:EXPLAIN
SELECT to_char(date_trunc('month', created_at), 'YYYY-MM') AS month, channel,
       COUNT(*) AS txns, SUM(amount) AS total_value
FROM bank_transaction
WHERE status = 'COMPLETED'
  AND created_at >= TIMESTAMPTZ '2026-01-01'
  AND created_at <  TIMESTAMPTZ '2026-11-01'
GROUP BY 1, 2
ORDER BY 1, 2;

\echo '### Q7b Same result as Q7: group on an immutable month expression, format the text after aggregating'
:EXPLAIN
SELECT to_char(m.month, 'YYYY-MM') AS month, m.channel, m.txns, m.total_value
FROM (
    SELECT date_trunc('month', created_at AT TIME ZONE 'Africa/Lagos') AS month, channel,
           COUNT(*) AS txns, SUM(amount) AS total_value
    FROM bank_transaction
    WHERE status = 'COMPLETED'
      AND created_at >= TIMESTAMPTZ '2026-01-01'
      AND created_at <  TIMESTAMPTZ '2026-11-01'
    GROUP BY 1, 2
) m
ORDER BY m.month, m.channel;

\echo '### Q8  Dormancy report: ACTIVE accounts per branch with no posted activity since 1 May 2026'
:EXPLAIN
SELECT b.branch_name, COUNT(*) AS dormant_accounts
FROM account a
JOIN branch b ON b.branch_id = a.branch_id
WHERE a.status = 'ACTIVE'
  AND NOT EXISTS (SELECT 1 FROM bank_transaction t
                  WHERE t.debit_account_id = a.account_id
                    AND t.status IN ('COMPLETED','REVERSED')
                    AND t.created_at >= TIMESTAMPTZ '2026-05-01')
  AND NOT EXISTS (SELECT 1 FROM bank_transaction t
                  WHERE t.credit_account_id = a.account_id
                    AND t.status IN ('COMPLETED','REVERSED')
                    AND t.created_at >= TIMESTAMPTZ '2026-05-01')
GROUP BY b.branch_name
ORDER BY dormant_accounts DESC;
