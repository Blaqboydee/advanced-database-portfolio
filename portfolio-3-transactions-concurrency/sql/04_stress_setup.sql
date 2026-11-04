-- =====================================================================
-- OwoTrust Digital Bank (simulated) - Portfolio 3
-- 04_stress_setup.sql : prepare a concurrent stress test and record a baseline
-- Run on a fresh Portfolio 1 database + 01_transaction_objects.sql,
-- then run pgbench with ../stress/pgbench_transfer_*.sql, then 05_stress_check.sql.
-- =====================================================================

-- maps 1..16 to the 16 ACTIVE naira accounts of the sample data
-- (USD, FROZEN and CLOSED accounts are left out)
CREATE OR REPLACE FUNCTION stress_account(n int) RETURNS char(10)
LANGUAGE sql IMMUTABLE AS $$
    SELECT (ARRAY['3010000001','3010000002','3010000003','3010000004','3010000005','3010000006',
                  '3010000007','3010000009','3010000010','3010000011','3010000012','3010000014',
                  '3010000015','3010000017','3010000018','3010000019'])[n]::char(10)
$$;

DROP TABLE IF EXISTS stress_baseline;
CREATE TABLE stress_baseline AS
SELECT (SELECT SUM(balance) FROM account
        WHERE account_number IN (SELECT stress_account(n) FROM generate_series(1, 16) n)) AS total_money,
       (SELECT MAX(txn_id) FROM bank_transaction)                                         AS last_txn_id,
       (SELECT deadlocks FROM pg_stat_database WHERE datname = current_database())        AS deadlocks,
       clock_timestamp()                                                                  AS taken_at;

SELECT 'baseline' AS snapshot, total_money AS total_money_in_16_accounts, deadlocks AS deadlocks_so_far
FROM stress_baseline;
