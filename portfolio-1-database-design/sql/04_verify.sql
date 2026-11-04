-- =====================================================================
-- OwoTrust Digital Bank (simulated) - Portfolio 1
-- 04_verify.sql : structural and data checks after schema + seed load
-- =====================================================================

SET timezone = 'Africa/Lagos';
\pset footer on

\echo '=== 1. Tables in the schema ==='
\dt

\echo '=== 2. Row counts ==='
SELECT 'kyc_tier' AS table_name, COUNT(*) AS rows FROM kyc_tier
UNION ALL SELECT 'branch',           COUNT(*) FROM branch
UNION ALL SELECT 'employee',         COUNT(*) FROM employee
UNION ALL SELECT 'customer',         COUNT(*) FROM customer
UNION ALL SELECT 'account_type',     COUNT(*) FROM account_type
UNION ALL SELECT 'account',          COUNT(*) FROM account
UNION ALL SELECT 'account_holder',   COUNT(*) FROM account_holder
UNION ALL SELECT 'bank_transaction', COUNT(*) FROM bank_transaction;

\echo '=== 3. Table definitions with keys and constraints ==='
\d account
\d account_holder
\d bank_transaction

\echo '=== 4. All declared constraints (PK, UNIQUE, FK, CHECK) ==='
SELECT conrelid::regclass AS table_name,
       conname            AS constraint_name,
       CASE contype WHEN 'p' THEN 'PRIMARY KEY' WHEN 'u' THEN 'UNIQUE'
                    WHEN 'f' THEN 'FOREIGN KEY' WHEN 'c' THEN 'CHECK' END AS type
FROM pg_constraint
WHERE connamespace = 'public'::regnamespace
ORDER BY conrelid::regclass::text, contype, conname;

\echo '=== 5. Balance audit: stored balance vs balance derived from posted transactions ==='
\echo '    (any row returned here would indicate an inconsistency)'
SELECT a.account_number, a.balance AS stored_balance, d.derived_balance
FROM account a
CROSS JOIN LATERAL (
    SELECT COALESCE(SUM(CASE WHEN t.credit_account_id = a.account_id THEN t.amount ELSE -t.amount END), 0)
           AS derived_balance
    FROM bank_transaction t
    WHERE t.status IN ('COMPLETED','REVERSED')
      AND a.account_id IN (t.debit_account_id, t.credit_account_id)
) d
WHERE a.balance <> d.derived_balance;

\echo '=== 6. Customer portfolio view (joins across 5 tables) ==='
SELECT c.first_name || ' ' || c.last_name AS customer,
       c.kyc_tier,
       a.account_number,
       at.type_name,
       at.currency,
       ah.holder_role,
       b.branch_name,
       a.status,
       a.balance
FROM customer c
JOIN account_holder ah ON ah.customer_id = c.customer_id
JOIN account a         ON a.account_id   = ah.account_id
JOIN account_type at   ON at.type_code   = a.type_code
JOIN branch b          ON b.branch_id    = a.branch_id
ORDER BY c.customer_id, a.account_number;

\echo '=== 7. Transaction status summary (per currency - NGN and USD must not be added together) ==='
SELECT t.txn_type, t.status, at.currency, COUNT(*) AS txns, SUM(t.amount) AS total_amount
FROM bank_transaction t
JOIN account a       ON a.account_id = COALESCE(t.debit_account_id, t.credit_account_id)
JOIN account_type at ON at.type_code = a.type_code
GROUP BY t.txn_type, t.status, at.currency
ORDER BY t.txn_type, t.status, at.currency;

\echo '=== 8. Reversal pair ==='
SELECT r.reference AS reversal_ref, o.reference AS original_ref, o.status AS original_status,
       r.amount, r.narration
FROM bank_transaction r
JOIN bank_transaction o ON o.txn_id = r.reverses_txn_id;
