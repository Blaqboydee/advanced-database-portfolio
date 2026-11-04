-- =====================================================================
-- OwoTrust Digital Bank (simulated) - Portfolio 2
-- 01_bulk_data.sql : generate a realistic, large dataset for performance work
--
-- Run AFTER Portfolio 1's 01_schema.sql and 02_seed_data.sql.
-- Adds:   50,000 customers, 60,000 accounts, ~1,060,000 transactions
--
-- Realism choices (they matter for query plans):
--   * Activity is SKEWED: a minority of accounts (merchants, salary
--     accounts) generate most debits - like real banks.
--   * Volume GROWS over time (Jan 2025 -> Oct 2026), so recent months are
--     busier than old ones.
--   * Rows are inserted in created_at order, as they would arrive in a
--     live system, so the table is physically ordered by time.
--   * Each account gets an opening deposit large enough that its running
--     balance never goes below zero.
--   * setseed() makes the "random" data identical on every run.
-- =====================================================================

\set ON_ERROR_STOP on
\timing on
SET timezone = 'Africa/Lagos';
SELECT setseed(0.2026);

\set n_customers 50000
\set n_accounts  60000
\set n_txns      1000000

-- ---------------------------------------------------------------------
-- 1. Customers
-- ---------------------------------------------------------------------
INSERT INTO customer (bvn, first_name, last_name, email, phone, date_of_birth,
                      city, state, kyc_tier, status, created_at)
SELECT (22200000000 + g)::text,
       fn, ln,
       lower(fn || '.' || ln || g) || '@example.com',
       '+23481' || lpad(g::text, 8, '0'),
       DATE '1960-01-01' + floor(r_dob * 16000)::int,
       (ARRAY['Ikeja','Lekki','Surulere','Yaba','Abuja','Ibadan','Port Harcourt','Kano',
              'Enugu','Benin City','Abeokuta','Kaduna','Owerri','Jos','Ilorin'])[loc],
       (ARRAY['Lagos','Lagos','Lagos','Lagos','FCT','Oyo','Rivers','Kano',
              'Enugu','Edo','Ogun','Kaduna','Imo','Plateau','Kwara'])[loc],
       CASE WHEN r_tier < 0.25 THEN 1 WHEN r_tier < 0.65 THEN 2 ELSE 3 END,
       'ACTIVE',
       TIMESTAMPTZ '2024-11-01' + r_created * INTERVAL '29 days'
FROM (
    SELECT g,
           (ARRAY['Adebayo','Chioma','Emeka','Fatima','Ngozi','Tunde','Aisha','Ifeoma','Musa','Bola',
                  'Kelechi','Yetunde','Ibrahim','Amaka','Segun','Zainab','Obinna','Funmi','Uche','Hauwa',
                  'Tobi','Chidi','Halima','Femi','Nneka','Sani','Kemi','Ikenna','Bisi','Yusuf'])[1 + floor(random() * 30)::int] AS fn,
           (ARRAY['Okafor','Adeyemi','Bello','Eze','Ogunleye','Abubakar','Nwosu','Okoro','Balogun','Danjuma',
                  'Obi','Adebayo','Ibrahim','Uche','Afolabi','Mohammed','Nnamdi','Ojo','Okonkwo','Lawal',
                  'Akande','Ekwueme','Garba','Oladipo','Ume','Yakubu','Ajayi','Onyeka','Salami','Etim'])[1 + floor(random() * 30)::int] AS ln,
           1 + floor(random() * 15)::int AS loc,
           random() AS r_dob, random() AS r_tier, random() AS r_created
    FROM generate_series(1, :n_customers) AS g
) s
ORDER BY g;

SELECT min(customer_id) AS first_cust FROM customer WHERE bvn LIKE '222%' \gset

-- ---------------------------------------------------------------------
-- 2. Accounts (85% savings, 15% current) and their primary holders.
--    Customers 1-10,000 of the bulk set get a second account.
-- ---------------------------------------------------------------------
SELECT array_agg(branch_id ORDER BY branch_id)     AS branch_ids FROM branch \gset
SELECT array_agg(employee_id ORDER BY employee_id) AS staff_ids
FROM employee WHERE role IN ('TELLER','CUSTOMER_SERVICE','BRANCH_MANAGER') \gset

INSERT INTO account (account_number, type_code, branch_id, opened_by, overdraft_limit, status, opened_at)
SELECT '31' || lpad(g::text, 8, '0'),
       CASE WHEN r_type < 0.15 THEN 'CUR_NGN' ELSE 'SAV_NGN' END,
       (:'branch_ids'::int[])[1 + floor(r_branch * 5)::int],
       CASE WHEN r_staff < 0.30   -- 30% opened in a branch, the rest on the mobile app (NULL)
            THEN (:'staff_ids'::int[])[1 + floor(r_staff / 0.30 * cardinality(:'staff_ids'::int[]))::int] END,
       CASE WHEN r_type < 0.15 THEN (ARRAY[0, 50000, 100000, 250000])[1 + floor(r_od * 4)::int] ELSE 0 END,
       'ACTIVE',
       TIMESTAMPTZ '2024-12-01' + r_opened * INTERVAL '29 days'
FROM (
    SELECT g, random() AS r_type, random() AS r_branch, random() AS r_staff,
           random() AS r_od, random() AS r_opened
    FROM generate_series(1, :n_accounts) AS g
) s
ORDER BY g;

SELECT min(account_id) AS first_acct FROM account WHERE account_number LIKE '31%' \gset

INSERT INTO account_holder (account_id, customer_id, holder_role, added_at)
SELECT a.account_id,
       :first_cust + ((a.account_id - :first_acct) % :n_customers),
       'PRIMARY',
       a.opened_at
FROM account a
WHERE a.account_number LIKE '31%';

-- ---------------------------------------------------------------------
-- 3. Generate 1,000,000 transactions into a staging table first.
--    debit side: skewed  -> power(random, 2) favours low account numbers
--    credit side: uniform
--    time: power(random, 0.8) favours recent dates (growing volume)
-- ---------------------------------------------------------------------
SELECT array_agg(employee_id ORDER BY employee_id) AS teller_ids
FROM employee WHERE role = 'TELLER' \gset

DROP TABLE IF EXISTS staging_txn;
CREATE TEMP TABLE staging_txn AS
WITH r AS MATERIALIZED (
    SELECT g, random() AS r_type, random() AS r_chan, random() AS r_status, random() AS r_amt,
              random() AS r_debit, random() AS r_credit, random() AS r_time, random() AS r_misc
    FROM generate_series(1, :n_txns) AS g
), typed AS (
    SELECT r.*,
           CASE WHEN r_type < 0.25 THEN 'DEPOSIT'
                WHEN r_type < 0.40 THEN 'WITHDRAWAL'
                WHEN r_type < 0.97 THEN 'TRANSFER'
                ELSE 'FEE' END AS txn_type,
           floor(power(r_debit, 2) * :n_accounts)::int AS debit_idx,
           floor(r_credit * :n_accounts)::int          AS credit_idx,
           TIMESTAMPTZ '2025-01-01' + power(r_time, 0.8)
               * (TIMESTAMPTZ '2026-11-01' - TIMESTAMPTZ '2025-01-01') AS created_at
    FROM r
)
SELECT 'BLK' || lpad(g::text, 10, '0') AS reference,
       txn_type,
       CASE txn_type
           WHEN 'DEPOSIT'    THEN CASE WHEN r_chan < 0.30 THEN 'BRANCH' ELSE 'MOBILE' END
           WHEN 'WITHDRAWAL' THEN CASE WHEN r_chan < 0.50 THEN 'ATM' WHEN r_chan < 0.85 THEN 'POS' ELSE 'BRANCH' END
           WHEN 'TRANSFER'   THEN CASE WHEN r_chan < 0.75 THEN 'MOBILE' WHEN r_chan < 0.87 THEN 'WEB' ELSE 'USSD' END
           ELSE 'SYSTEM' END AS channel,
       CASE WHEN txn_type IN ('WITHDRAWAL','TRANSFER','FEE') THEN :first_acct + debit_idx END AS debit_account_id,
       CASE WHEN txn_type = 'DEPOSIT'  THEN :first_acct + credit_idx
            WHEN txn_type = 'TRANSFER' THEN :first_acct
                 + CASE WHEN credit_idx = debit_idx THEN (credit_idx + 1) % :n_accounts ELSE credit_idx END
       END AS credit_account_id,
       CASE WHEN txn_type = 'FEE' THEN 50.00
            ELSE round((100 * exp(r_amt * ln(2000)))::numeric, -1) END AS amount,   -- log-uniform N100 - N200,000
       -- a small number of transfers from the last week are still awaiting review
       CASE WHEN txn_type = 'TRANSFER'   AND r_status < 0.03
                 AND created_at >= TIMESTAMPTZ '2026-10-25' THEN 'PENDING'
            WHEN txn_type IN ('TRANSFER','WITHDRAWAL') AND r_status < 0.027 THEN 'FAILED'
            ELSE 'COMPLETED' END AS status,
       r_status, r_misc, r_chan, created_at
FROM typed;

-- fill in the remaining columns that depend on the values chosen above
ALTER TABLE staging_txn
    ADD COLUMN narration      VARCHAR(140),
    ADD COLUMN initiated_by   INT,
    ADD COLUMN failure_reason VARCHAR(200),
    ADD COLUMN completed_at   TIMESTAMPTZ;

UPDATE staging_txn SET
    narration = CASE
        WHEN txn_type = 'DEPOSIT'    AND channel = 'BRANCH' THEN 'Cash deposit'
        WHEN txn_type = 'DEPOSIT'                           THEN 'Card funding'
        WHEN txn_type = 'WITHDRAWAL' AND channel = 'ATM'    THEN 'ATM withdrawal'
        WHEN txn_type = 'WITHDRAWAL' AND channel = 'POS'    THEN 'POS purchase'
        WHEN txn_type = 'WITHDRAWAL'                        THEN 'Cash withdrawal'
        WHEN txn_type = 'FEE'                               THEN 'SMS alert and card maintenance fee'
        ELSE (ARRAY['Transfer','Rent','School fees','Family support','Business payment',
                    'Contribution','Utility bill','Salary advance'])[1 + floor(r_misc * 8)::int]
    END,
    initiated_by   = CASE WHEN channel = 'BRANCH'
                          THEN (:'teller_ids'::int[])[1 + floor(r_misc * cardinality(:'teller_ids'::int[]))::int] END,
    failure_reason = CASE WHEN status = 'FAILED'
                          THEN CASE WHEN r_status < 0.015 THEN 'Insufficient funds' ELSE 'Daily limit exceeded' END END,
    completed_at   = CASE WHEN status = 'COMPLETED' THEN created_at + (1 + r_misc * 5) * INTERVAL '1 second' END;

-- ---------------------------------------------------------------------
-- 4. Opening deposits: for every bulk account, compute the lowest point
--    its running balance would reach, and deposit enough on the opening
--    day to keep it at or above zero (plus a random buffer).
-- ---------------------------------------------------------------------
CREATE TEMP TABLE staging_opening AS
WITH legs AS (
    SELECT debit_account_id  AS account_id, created_at, reference, -amount AS delta
    FROM staging_txn WHERE status = 'COMPLETED' AND debit_account_id IS NOT NULL
    UNION ALL
    SELECT credit_account_id AS account_id, created_at, reference,  amount AS delta
    FROM staging_txn WHERE status = 'COMPLETED' AND credit_account_id IS NOT NULL
), running AS (
    SELECT account_id,
           SUM(delta) OVER (PARTITION BY account_id ORDER BY created_at, reference) AS running_balance
    FROM legs
), lowest AS (
    SELECT account_id, LEAST(MIN(running_balance), 0) AS lowest_balance
    FROM running GROUP BY account_id
)
SELECT a.account_id,
       a.opened_at,
       -COALESCE(l.lowest_balance, 0) + round((5000 + random() * 195000)::numeric, -2) AS amount
FROM account a
LEFT JOIN lowest l ON l.account_id = a.account_id
WHERE a.account_number LIKE '31%';

-- ---------------------------------------------------------------------
-- 5. Load everything into bank_transaction in chronological order.
--    All CHECK and FOREIGN KEY constraints are enforced on every row.
-- ---------------------------------------------------------------------
INSERT INTO bank_transaction (reference, txn_type, channel, debit_account_id, credit_account_id,
                              amount, status, narration, initiated_by, failure_reason,
                              created_at, completed_at)
SELECT reference, txn_type, channel, debit_account_id, credit_account_id,
       amount, status, narration, initiated_by, failure_reason, created_at, completed_at
FROM (
    SELECT reference, txn_type, channel, debit_account_id, credit_account_id,
           amount, status, narration, initiated_by, failure_reason, created_at, completed_at
    FROM staging_txn
    UNION ALL
    SELECT 'OPN' || lpad(account_id::text, 10, '0'), 'DEPOSIT', 'MOBILE', NULL, account_id,
           amount, 'COMPLETED', 'Opening deposit', NULL, NULL,
           opened_at + INTERVAL '1 hour', opened_at + INTERVAL '1 hour 2 seconds'
    FROM staging_opening
) all_txns
ORDER BY created_at;

-- ---------------------------------------------------------------------
-- 6. Derive stored balances for the bulk accounts (set-based, one pass).
-- ---------------------------------------------------------------------
UPDATE account a
SET balance = s.balance
FROM (
    SELECT account_id, SUM(delta) AS balance
    FROM (
        SELECT credit_account_id AS account_id,  amount AS delta FROM bank_transaction
        WHERE status IN ('COMPLETED','REVERSED') AND credit_account_id IS NOT NULL
        UNION ALL
        SELECT debit_account_id  AS account_id, -amount AS delta FROM bank_transaction
        WHERE status IN ('COMPLETED','REVERSED') AND debit_account_id  IS NOT NULL
    ) legs
    GROUP BY account_id
) s
WHERE s.account_id = a.account_id
  AND a.account_number LIKE '31%';

DROP TABLE staging_txn;
DROP TABLE staging_opening;

-- refresh planner statistics and the visibility map after the bulk load
VACUUM ANALYZE;

-- ---------------------------------------------------------------------
-- 7. Summary of what was generated
-- ---------------------------------------------------------------------
\timing off
SELECT 'customer' AS table_name, COUNT(*) AS rows, pg_size_pretty(pg_total_relation_size('customer')) AS total_size FROM customer
UNION ALL SELECT 'account',          COUNT(*), pg_size_pretty(pg_total_relation_size('account'))          FROM account
UNION ALL SELECT 'account_holder',   COUNT(*), pg_size_pretty(pg_total_relation_size('account_holder'))   FROM account_holder
UNION ALL SELECT 'bank_transaction', COUNT(*), pg_size_pretty(pg_total_relation_size('bank_transaction')) FROM bank_transaction;

SELECT txn_type, status, COUNT(*) AS txns, round(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct
FROM bank_transaction GROUP BY txn_type, status ORDER BY txn_type, status;

-- skew check: share of all debits made by the busiest 10% of accounts
WITH per_acct AS (
    SELECT debit_account_id, COUNT(*) AS debits
    FROM bank_transaction WHERE debit_account_id IS NOT NULL GROUP BY debit_account_id
), ranked AS (
    SELECT debits, NTILE(10) OVER (ORDER BY debits DESC) AS decile FROM per_acct
)
SELECT round(100.0 * SUM(debits) FILTER (WHERE decile = 1) / SUM(debits), 1) AS pct_of_debits_by_top_10pct_accounts
FROM ranked;

-- growth check: transactions per quarter
SELECT to_char(date_trunc('quarter', created_at), 'YYYY "Q"Q') AS quarter, COUNT(*) AS txns
FROM bank_transaction GROUP BY 1 ORDER BY 1;
