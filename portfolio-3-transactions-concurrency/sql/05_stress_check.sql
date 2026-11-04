-- =====================================================================
-- OwoTrust Digital Bank (simulated) - Portfolio 3
-- 05_stress_check.sql : did the concurrent run keep the books correct?
--
-- Transfers only move money BETWEEN the 16 accounts, so whatever happens:
--   (1) the total money in the 16 accounts must not change, and
--   (2) every stored balance must still equal the balance implied by
--       the transaction history.
-- =====================================================================

\echo 'Transfers posted during the run, by outcome:'
SELECT status, COUNT(*) AS transfers, SUM(amount) AS total_amount
FROM bank_transaction
WHERE txn_id > (SELECT last_txn_id FROM stress_baseline)
GROUP BY status ORDER BY status;

\echo 'Most common failure reasons (business rules enforced under load):'
SELECT regexp_replace(failure_reason, '[0-9.,]+', 'n', 'g') AS failure_reason, COUNT(*) AS transfers
FROM bank_transaction
WHERE txn_id > (SELECT last_txn_id FROM stress_baseline) AND status = 'FAILED'
GROUP BY 1 ORDER BY 2 DESC;

\echo 'CHECK 1: money conservation (difference must be 0)'
SELECT b.total_money                         AS total_before,
       now_.total_money                      AS total_after,
       now_.total_money - b.total_money      AS money_created_or_destroyed
FROM stress_baseline b,
     LATERAL (SELECT SUM(balance) AS total_money FROM account
              WHERE account_number IN (SELECT stress_account(n) FROM generate_series(1, 16) n)) now_;

\echo 'CHECK 2: stored balance vs transaction history (mismatches must be 0)'
SELECT a.account_number, a.balance AS stored_balance, COALESCE(d.derived, 0) AS balance_from_history,
       a.balance - COALESCE(d.derived, 0) AS difference
FROM account a
LEFT JOIN (SELECT account_id, SUM(delta) AS derived
           FROM (SELECT credit_account_id AS account_id,  amount AS delta FROM bank_transaction
                 WHERE status IN ('COMPLETED','REVERSED') AND credit_account_id IS NOT NULL
                 UNION ALL
                 SELECT debit_account_id,  -amount FROM bank_transaction
                 WHERE status IN ('COMPLETED','REVERSED') AND debit_account_id IS NOT NULL) legs
           GROUP BY account_id) d ON d.account_id = a.account_id
WHERE a.balance <> COALESCE(d.derived, 0)
ORDER BY a.account_number;

\echo 'CHECK 3: deadlocks detected by PostgreSQL during the run'
SELECT s.deadlocks - b.deadlocks AS deadlocks_during_run
FROM pg_stat_database s, stress_baseline b
WHERE s.datname = current_database();
