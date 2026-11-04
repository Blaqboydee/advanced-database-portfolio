-- =====================================================================
-- OwoTrust Digital Bank (simulated) - Portfolio 1
-- 03_constraint_tests.sql : proves the constraints enforce the business rules
--
-- Each test attempts an INVALID change and should be REJECTED with the
-- error named in its heading. The last test is a VALID change that must
-- succeed. Everything runs inside one transaction that is rolled back at
-- the end, so the seed data is left untouched.
--
-- psql's ON_ERROR_ROLLBACK wraps each statement in a savepoint, so one
-- failing statement does not abort the rest of the script.
-- =====================================================================

\set ON_ERROR_ROLLBACK on
\set VERBOSITY default
BEGIN;

\echo '--- T01 Duplicate BVN (candidate key)                -> expect unique_violation'
INSERT INTO customer (bvn, first_name, last_name, phone, date_of_birth)
VALUES ('22100000001', 'Copy', 'Cat', '+2348099999999', '1990-01-01');

\echo '--- T02 BVN must be exactly 11 digits                 -> expect check_violation'
INSERT INTO customer (bvn, first_name, last_name, phone, date_of_birth)
VALUES ('2210000', 'Short', 'Bvn', '+2348099999998', '1990-01-01');

\echo '--- T03 Phone must be +234 followed by 10 digits      -> expect check_violation'
INSERT INTO customer (bvn, first_name, last_name, phone, date_of_birth)
VALUES ('22199999999', 'Bad', 'Phone', '08031234567', '1990-01-01');

\echo '--- T04 Unknown KYC tier (foreign key)                -> expect foreign_key_violation'
INSERT INTO customer (bvn, first_name, last_name, phone, date_of_birth, kyc_tier)
VALUES ('22199999998', 'No', 'Tier', '+2348099999997', '1990-01-01', 4);

\echo '--- T05 Account with an unknown product type (FK)     -> expect foreign_key_violation'
INSERT INTO account (account_number, type_code, branch_id)
VALUES ('3019999999', 'GOLD_NGN', 1);

\echo '--- T06 Savings balance below zero (no overdraft)     -> expect check_violation chk_account_balance_floor'
UPDATE account SET balance = -1 WHERE account_number = '3010000001';

\echo '--- T07 Current account beyond its overdraft limit    -> expect check_violation chk_account_balance_floor'
UPDATE account SET balance = -100000.01 WHERE account_number = '3010000002';

\echo '--- T08 CLOSED account without closed_at              -> expect check_violation chk_account_closed_state'
UPDATE account SET status = 'CLOSED' WHERE account_number = '3010000001';

\echo '--- T09 Second PRIMARY holder on the same account     -> expect unique_violation uq_account_single_primary_holder'
INSERT INTO account_holder (account_id, customer_id, holder_role)
SELECT a.account_id, c.customer_id, 'PRIMARY'
FROM account a, customer c
WHERE a.account_number = '3010000004' AND c.bvn = '22100000015';

\echo '--- T10 Transfer to the same account                  -> expect check_violation chk_txn_distinct_accounts'
INSERT INTO bank_transaction (reference, txn_type, channel, debit_account_id, credit_account_id, amount)
VALUES ('TEST0010', 'TRANSFER', 'MOBILE', 1, 1, 1000);

\echo '--- T11 DEPOSIT that also debits an account          -> expect check_violation chk_txn_legs'
INSERT INTO bank_transaction (reference, txn_type, channel, debit_account_id, credit_account_id, amount)
VALUES ('TEST0011', 'DEPOSIT', 'MOBILE', 2, 1, 1000);

\echo '--- T12 Zero / negative amount                        -> expect check_violation'
INSERT INTO bank_transaction (reference, txn_type, channel, credit_account_id, amount)
VALUES ('TEST0012', 'DEPOSIT', 'MOBILE', 1, -500);

\echo '--- T13 REVERSAL that does not say what it reverses   -> expect check_violation chk_txn_reversal_link'
INSERT INTO bank_transaction (reference, txn_type, channel, debit_account_id, credit_account_id, amount)
VALUES ('TEST0013', 'REVERSAL', 'SYSTEM', 1, 2, 1000);

\echo '--- T14 Reversing the same transaction twice          -> expect unique_violation on reverses_txn_id'
INSERT INTO bank_transaction (reference, txn_type, channel, debit_account_id, credit_account_id,
                              amount, status, reverses_txn_id, completed_at)
SELECT 'TEST0014', 'REVERSAL', 'SYSTEM', o.credit_account_id, o.debit_account_id,
       o.amount, 'COMPLETED', o.txn_id, now()
FROM bank_transaction o WHERE o.reference = 'OTB2609280033';

\echo '--- T15 FAILED transaction with no failure_reason     -> expect check_violation chk_txn_failure_reason'
INSERT INTO bank_transaction (reference, txn_type, channel, credit_account_id, amount, status)
VALUES ('TEST0015', 'DEPOSIT', 'MOBILE', 1, 1000, 'FAILED');

\echo '--- T16 COMPLETED transaction with no completed_at    -> expect check_violation chk_txn_completed_at'
INSERT INTO bank_transaction (reference, txn_type, channel, credit_account_id, amount, status)
VALUES ('TEST0016', 'DEPOSIT', 'MOBILE', 1, 1000, 'COMPLETED');

\echo '--- T17 Branch (over-the-counter) txn with no teller  -> expect check_violation chk_txn_branch_teller'
INSERT INTO bank_transaction (reference, txn_type, channel, credit_account_id, amount)
VALUES ('TEST0017', 'DEPOSIT', 'BRANCH', 1, 1000);

\echo '--- T18 Duplicate transaction reference (idempotency) -> expect unique_violation'
INSERT INTO bank_transaction (reference, txn_type, channel, credit_account_id, amount)
VALUES ('OTB2609010002', 'DEPOSIT', 'MOBILE', 1, 500000);

\echo '--- T19 Delete a customer who still holds accounts    -> expect foreign_key_violation'
DELETE FROM customer WHERE bvn = '22100000001';

\echo '--- T20 Delete an account still referenced by holders/transactions -> expect foreign_key_violation'
DELETE FROM account WHERE account_number = '3010000020';

\echo '--- T21 VALID pending transfer                        -> expect INSERT 0 1 (success)'
INSERT INTO bank_transaction (reference, txn_type, channel, debit_account_id, credit_account_id, amount, narration)
SELECT 'TEST0021', 'TRANSFER', 'MOBILE', d.account_id, c.account_id, 5000, 'Valid test transfer'
FROM account d, account c
WHERE d.account_number = '3010000001' AND c.account_number = '3010000003';

ROLLBACK;
\echo '--- All changes rolled back; seed data unchanged.'
