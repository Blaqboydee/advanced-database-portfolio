-- =====================================================================
-- OwoTrust Digital Bank (simulated) - Portfolio 3
-- 02_acid_demos.sql : COMMIT, ROLLBACK, atomicity, savepoints,
--                     business-rule failures, idempotency, deferred constraints
-- Run on a fresh Portfolio 1 database + 01_transaction_objects.sql.
-- (Single session. Concurrency is in 03_concurrency_anomalies.sql.)
-- =====================================================================

SET timezone = 'Africa/Lagos';
\set VERBOSITY terse

-- helper view used throughout: the balances we are watching
CREATE OR REPLACE TEMP VIEW watched AS
SELECT account_number, type_code, status, balance
FROM account
WHERE account_number IN ('3010000001','3010000003','3010000004','3010000018','3010000019')
ORDER BY account_number;


\echo
\echo '===================================================================='
\echo 'D1. COMMIT: a transfer becomes permanent and visible to everyone'
\echo '===================================================================='
\echo 'Before:'
SELECT * FROM watched;
BEGIN;
SELECT txid_current() AS this_transaction_id;
SELECT * FROM transfer_funds('3010000001', '3010000003', 25000, 'MOBILE', 'Rent share');
COMMIT;
\echo 'After COMMIT: 3010000001 -25,000 and 3010000003 +25,000'
SELECT * FROM watched;
\echo 'The audit trigger recorded both balance changes under the same transaction id:'
SELECT txid, row_key, old_values->>'balance' AS old_balance, new_values->>'balance' AS new_balance
FROM audit_log ORDER BY audit_id;


\echo
\echo '===================================================================='
\echo 'D2. ROLLBACK: the customer cancels before confirming, nothing is kept'
\echo '===================================================================='
BEGIN;
SELECT * FROM transfer_funds('3010000001', '3010000003', 100000, 'MOBILE', 'Cancelled transfer');
\echo 'Inside the transaction, this session already sees the new balances:'
SELECT * FROM watched;
ROLLBACK;
\echo 'After ROLLBACK: balances are back to the D1 values, and there is no transaction row and no audit row:'
SELECT * FROM watched;
SELECT COUNT(*) AS transactions_named_cancelled FROM bank_transaction WHERE narration = 'Cancelled transfer';
SELECT COUNT(*) AS audit_rows_total FROM audit_log;


\echo
\echo '===================================================================='
\echo 'D3. ATOMICITY: an error inside a transaction aborts ALL of it'
\echo '===================================================================='
\echo 'Manual transfer of N500,000 from savings 3010000006 (balance 77,000).'
\echo 'The credit is applied first, then the debit violates the balance CHECK.'
SELECT account_number, balance FROM account WHERE account_number IN ('3010000005','3010000006') ORDER BY 1;
BEGIN;
UPDATE account SET balance = balance + 500000 WHERE account_number = '3010000005';
UPDATE account SET balance = balance - 500000 WHERE account_number = '3010000006';
\echo 'Any further statement is refused until the transaction ends:'
SELECT 1 AS this_will_not_run;
\echo 'COMMIT on a failed transaction is turned into a ROLLBACK:'
COMMIT;
\echo 'The credit that DID succeed was undone as well (half a transfer never survives):'
SELECT account_number, balance FROM account WHERE account_number IN ('3010000005','3010000006') ORDER BY 1;


\echo
\echo '===================================================================='
\echo 'D4. SAVEPOINTS: a payroll batch where one payment fails'
\echo '===================================================================='
\echo 'The joint business account 3010000004 pays three people in one transaction.'
\echo 'Payment 2 (N2,500,000) is larger than balance + overdraft and is rejected;'
\echo 'ROLLBACK TO SAVEPOINT undoes only that payment, and the batch continues.'
SELECT account_number, balance, overdraft_limit FROM account WHERE account_number = '3010000004';
BEGIN;

SAVEPOINT payment_1;
INSERT INTO bank_transaction (reference, txn_type, channel, debit_account_id, credit_account_id, amount, status, narration, completed_at)
SELECT 'PAY2611040001', 'TRANSFER', 'WEB', d.account_id, c.account_id, 600000, 'COMPLETED', 'Salary - Nov', clock_timestamp()
FROM account d, account c WHERE d.account_number = '3010000004' AND c.account_number = '3010000018';
UPDATE account SET balance = balance - 600000 WHERE account_number = '3010000004';
UPDATE account SET balance = balance + 600000 WHERE account_number = '3010000018';
RELEASE SAVEPOINT payment_1;

SAVEPOINT payment_2;
INSERT INTO bank_transaction (reference, txn_type, channel, debit_account_id, credit_account_id, amount, status, narration, completed_at)
SELECT 'PAY2611040002', 'TRANSFER', 'WEB', d.account_id, c.account_id, 2500000, 'COMPLETED', 'Bonus - Nov', clock_timestamp()
FROM account d, account c WHERE d.account_number = '3010000004' AND c.account_number = '3010000019';
UPDATE account SET balance = balance - 2500000 WHERE account_number = '3010000004';
UPDATE account SET balance = balance + 2500000 WHERE account_number = '3010000019';
ROLLBACK TO SAVEPOINT payment_2;

SAVEPOINT payment_3;
INSERT INTO bank_transaction (reference, txn_type, channel, debit_account_id, credit_account_id, amount, status, narration, completed_at)
SELECT 'PAY2611040003', 'TRANSFER', 'WEB', d.account_id, c.account_id, 150000, 'COMPLETED', 'Salary - Nov', clock_timestamp()
FROM account d, account c WHERE d.account_number = '3010000004' AND c.account_number = '3010000003';
UPDATE account SET balance = balance - 150000 WHERE account_number = '3010000004';
UPDATE account SET balance = balance + 150000 WHERE account_number = '3010000003';
RELEASE SAVEPOINT payment_3;

COMMIT;
\echo 'Result: payments 1 and 3 committed, payment 2 left no trace:'
SELECT reference, amount, status, narration FROM bank_transaction WHERE reference LIKE 'PAY26110400%' ORDER BY reference;
SELECT * FROM watched;


\echo
\echo '===================================================================='
\echo 'D5. BUSINESS-RULE FAILURES inside transfer_funds() (internal savepoint)'
\echo '===================================================================='
\echo 'Each call fails a different rule. The function rolls back to its internal'
\echo 'savepoint, records a FAILED transaction with the reason, and moves no money.'
SELECT 'frozen account'     AS scenario, * FROM transfer_funds('3010000016', '3010000006',  10000)
UNION ALL
SELECT 'insufficient funds',             * FROM transfer_funds('3010000011', '3010000006',  45000)
UNION ALL
SELECT 'currency mismatch',              * FROM transfer_funds('3010000008', '3010000007',    100)
UNION ALL
SELECT 'Tier-1 limit: first N30,000 OK', * FROM transfer_funds('3010000006', '3010000011',  30000)
UNION ALL
SELECT 'Tier-1 limit: next N25,000',     * FROM transfer_funds('3010000006', '3010000011',  25000)
UNION ALL
SELECT 'same account',                   * FROM transfer_funds('3010000001', '3010000001',   1000);
\echo 'FAILED attempts are kept for customer service and auditors:'
SELECT reference, amount, status, failure_reason FROM bank_transaction
WHERE status = 'FAILED' AND created_at >= date_trunc('day', now()) ORDER BY txn_id;


\echo
\echo '===================================================================='
\echo 'D6. IDEMPOTENCY: the app times out and re-sends the same request'
\echo '===================================================================='
SELECT balance AS balance_before FROM account WHERE account_number = '3010000019';
SELECT 'first attempt' AS attempt, * FROM transfer_funds('3010000019', '3010000003', 5000, 'MOBILE', 'Retry test', 'APP-REQ-000123');
SELECT 'retry'         AS attempt, * FROM transfer_funds('3010000019', '3010000003', 5000, 'MOBILE', 'Retry test', 'APP-REQ-000123');
\echo 'Money moved exactly once:'
SELECT balance AS balance_after FROM account WHERE account_number = '3010000019';
SELECT COUNT(*) AS rows_with_this_reference FROM bank_transaction WHERE reference = 'APP-REQ-000123';


\echo
\echo '===================================================================='
\echo 'D7. DEFERRED CONSTRAINT and trigger-enforced rules (Portfolio 1 §3.4)'
\echo '===================================================================='
\echo 'D7a. Account + its PRIMARY holder created in one transaction: the check'
\echo '     runs at COMMIT, when both rows exist, so the transaction succeeds.'
BEGIN;
INSERT INTO account (account_number, type_code, branch_id) VALUES ('3010000099', 'SAV_NGN', 1);
\echo '     (an account without a holder is tolerated for now, the check is deferred)'
INSERT INTO account_holder (account_id, customer_id, holder_role)
SELECT a.account_id, c.customer_id, 'PRIMARY' FROM account a, customer c
WHERE a.account_number = '3010000099' AND c.bvn = '22100000015';
COMMIT;

\echo 'D7b. Account created WITHOUT a holder: the deferred check fails at COMMIT,'
\echo '     so the whole transaction is rolled back.'
BEGIN;
INSERT INTO account (account_number, type_code, branch_id) VALUES ('3010000098', 'SAV_NGN', 1);
COMMIT;
SELECT account_number, (SELECT COUNT(*) FROM account_holder h WHERE h.account_id = a.account_id) AS holders
FROM account a WHERE account_number IN ('3010000098', '3010000099');

\echo 'D7c. Overdraft on a savings product is rejected by a trigger:'
UPDATE account SET overdraft_limit = 50000 WHERE account_number = '3010000001';


\echo
\echo '===================================================================='
\echo 'FINAL CHECK: stored balances still match the transaction history'
\echo '===================================================================='
SELECT COUNT(*) AS accounts_where_balance_does_not_match_history
FROM account a
LEFT JOIN (
    SELECT account_id, SUM(delta) AS derived
    FROM (SELECT credit_account_id AS account_id,  amount AS delta FROM bank_transaction
          WHERE status IN ('COMPLETED','REVERSED') AND credit_account_id IS NOT NULL
          UNION ALL
          SELECT debit_account_id,  -amount FROM bank_transaction
          WHERE status IN ('COMPLETED','REVERSED') AND debit_account_id IS NOT NULL) legs
    GROUP BY account_id
) d ON d.account_id = a.account_id
WHERE a.balance <> COALESCE(d.derived, 0);
