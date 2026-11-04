-- =====================================================================
-- OwoTrust Digital Bank (simulated) - Portfolio 4
-- 01_prepare_source_data.sql : extra source data in PostgreSQL (the system
--                              of record) before exporting to the NoSQL stores
-- Run AFTER Portfolio 1 (schema + seed) and Portfolio 2 (01_bulk_data.sql).
--
--   1. customer_device : mobile devices seen by the app (device fingerprint)
--   2. A money-mule fraud ring hidden in the normal October 2026 traffic:
--        - two scam victims send money to mule accounts
--        - the money is layered mule1 -> mule2 -> mule3 -> mule4, loops back
--          to mule1, and is cashed out at ATMs by mule5
--        - all five mules registered their accounts from the SAME phone
-- =====================================================================

\set ON_ERROR_STOP on
SET timezone = 'Africa/Lagos';
SELECT setseed(0.4);

-- ---------------------------------------------------------------------
-- 1. Devices. Most customers use 1 device and 30% use 2. One family of
--    3 legitimate customers shares a tablet (a harmless shared device,
--    useful for discussing false positives).
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS customer_device;
CREATE TABLE customer_device (
    customer_id INT         NOT NULL REFERENCES customer (customer_id),
    device_id   VARCHAR(20) NOT NULL,
    platform    VARCHAR(10) NOT NULL CHECK (platform IN ('ANDROID','IOS','WEB')),
    first_seen  TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (customer_id, device_id)
);

INSERT INTO customer_device (customer_id, device_id, platform, first_seen)
SELECT c.customer_id,
       'dev-' || substr(md5(c.customer_id::text || '-' || d.n), 1, 12),
       CASE WHEN random() < 0.70 THEN 'ANDROID' WHEN random() < 0.85 THEN 'IOS' ELSE 'WEB' END,
       c.created_at + random() * INTERVAL '30 days'
FROM customer c
CROSS JOIN LATERAL generate_series(1, CASE WHEN c.customer_id % 10 < 3 THEN 2 ELSE 1 END) AS d(n);

INSERT INTO customer_device (customer_id, device_id, platform, first_seen)
SELECT customer_id, 'dev-family-tab01', 'ANDROID', TIMESTAMPTZ '2025-06-01'
FROM customer WHERE bvn IN ('22200012001', '22200012002', '22200012003');

-- ---------------------------------------------------------------------
-- 2. The fraud ring: five recently opened Tier-1 accounts
-- ---------------------------------------------------------------------
INSERT INTO customer (bvn, first_name, last_name, phone, date_of_birth, city, state, kyc_tier, created_at)
VALUES ('22900000001', 'Tobi',   'Adekunle', '+2348099000001', '2001-03-14', 'Ikeja', 'Lagos', 1, '2026-10-18 21:02'),
       ('22900000002', 'Chuka',  'Emenike',  '+2348099000002', '2000-11-02', 'Ikeja', 'Lagos', 1, '2026-10-18 21:15'),
       ('22900000003', 'Bayo',   'Lawson',   '+2348099000003', '2002-07-30', 'Yaba',  'Lagos', 1, '2026-10-19 08:40'),
       ('22900000004', 'Ese',    'Okoro',    '+2348099000004', '1999-01-21', 'Yaba',  'Lagos', 1, '2026-10-19 09:05'),
       ('22900000005', 'Danjuma','Ali',      '+2348099000005', '2001-09-09', 'Ikeja', 'Lagos', 1, '2026-10-19 09:30');

INSERT INTO account (account_number, type_code, branch_id, status, opened_at)
SELECT '39000000' || right(c.bvn, 2), 'SAV_NGN', (SELECT branch_id FROM branch WHERE branch_code = '002'),
       'ACTIVE', c.created_at + INTERVAL '5 minutes'
FROM customer c WHERE c.bvn LIKE '229%' ORDER BY c.bvn;

INSERT INTO account_holder (account_id, customer_id, holder_role, added_at)
SELECT a.account_id, c.customer_id, 'PRIMARY', a.opened_at
FROM customer c JOIN account a ON a.account_number = '39000000' || right(c.bvn, 2)
WHERE c.bvn LIKE '229%';

-- every mule registered from the same phone, and each also has its own device
INSERT INTO customer_device (customer_id, device_id, platform, first_seen)
SELECT customer_id, 'dev-7f3a9c11e2b4', 'ANDROID', created_at FROM customer WHERE bvn LIKE '229%'
UNION ALL
SELECT customer_id, 'dev-' || substr(md5('mule' || customer_id), 1, 12), 'ANDROID', created_at + INTERVAL '2 days'
FROM customer WHERE bvn LIKE '229%';

-- the money movements (victims are two ordinary customers from the bulk data)
INSERT INTO bank_transaction (reference, txn_type, channel, debit_account_id, credit_account_id,
                              amount, status, narration, initiated_by, created_at, completed_at)
SELECT v.reference, v.txn_type, v.channel, d.account_id, c.account_id, v.amount, 'COMPLETED', v.narration,
       CASE WHEN v.channel = 'BRANCH' THEN (SELECT employee_id FROM employee WHERE staff_number = 'OT00005') END,
       v.at::timestamptz, v.at::timestamptz + INTERVAL '2 seconds'
FROM (VALUES
    -- victims are funded, then tricked into an "investment"
    ('OTB2610270091', 'DEPOSIT',    'MOBILE', NULL,         '3100000777', 250000, 'Salary October',          '2026-10-27 16:00'),
    ('OTB2610290093', 'DEPOSIT',    'MOBILE', NULL,         '3100004321', 100000, 'Card funding',            '2026-10-28 18:30'),
    ('OTB2610280092', 'TRANSFER',   'MOBILE', '3100000777', '3900000001', 180000, 'Investment - 40% weekly', '2026-10-28 09:14'),
    -- layering: rapid hops through the ring, each mule keeps a small cut
    ('OTB2610280094', 'TRANSFER',   'MOBILE', '3900000001', '3900000002', 175000, 'Payment',                 '2026-10-28 09:31'),
    ('OTB2610280095', 'TRANSFER',   'MOBILE', '3900000002', '3900000003', 170000, 'Payment',                 '2026-10-28 09:52'),
    ('OTB2610280096', 'TRANSFER',   'USSD',   '3900000003', '3900000004', 165000, 'Refund',                  '2026-10-28 10:15'),
    ('OTB2610280097', 'TRANSFER',   'MOBILE', '3900000004', '3900000005', 120000, 'Goods',                   '2026-10-28 10:20'),
    ('OTB2610280098', 'TRANSFER',   'MOBILE', '3900000004', '3900000001',  40000, 'Payment',                 '2026-10-28 10:40'),
    -- cash-out at ATMs
    ('OTB2610280099', 'WITHDRAWAL', 'ATM',    '3900000005', NULL,          20000, 'ATM withdrawal',          '2026-10-28 10:45'),
    ('OTB2610280100', 'WITHDRAWAL', 'ATM',    '3900000005', NULL,          20000, 'ATM withdrawal',          '2026-10-28 10:47'),
    ('OTB2610280101', 'WITHDRAWAL', 'ATM',    '3900000005', NULL,          20000, 'ATM withdrawal',          '2026-10-28 11:02'),
    ('OTB2610280102', 'WITHDRAWAL', 'ATM',    '3900000005', NULL,          20000, 'ATM withdrawal',          '2026-10-28 11:15'),
    ('OTB2610280103', 'WITHDRAWAL', 'ATM',    '3900000005', NULL,          20000, 'ATM withdrawal',          '2026-10-28 11:30'),
    -- a second victim the next day
    ('OTB2610290104', 'TRANSFER',   'MOBILE', '3100004321', '3900000002',  60000, 'Investment - 40% weekly', '2026-10-29 07:55')
) AS v(reference, txn_type, channel, debit_acct, credit_acct, amount, narration, at)
LEFT JOIN account d ON d.account_number = v.debit_acct
LEFT JOIN account c ON c.account_number = v.credit_acct
ORDER BY v.at;

-- keep stored balances equal to the transaction history for every affected account
UPDATE account a
SET balance = s.balance
FROM (SELECT account_id, SUM(delta) AS balance
      FROM (SELECT credit_account_id AS account_id,  amount AS delta FROM bank_transaction
            WHERE status IN ('COMPLETED','REVERSED') AND credit_account_id IS NOT NULL
            UNION ALL
            SELECT debit_account_id, -amount FROM bank_transaction
            WHERE status IN ('COMPLETED','REVERSED') AND debit_account_id IS NOT NULL) legs
      GROUP BY account_id) s
WHERE s.account_id = a.account_id
  AND a.account_number IN ('3100000777','3100004321','3900000001','3900000002',
                           '3900000003','3900000004','3900000005');

ANALYZE customer_device;
SELECT account_number, balance FROM account WHERE account_number LIKE '39%' OR account_number IN ('3100000777','3100004321')
ORDER BY account_number;
SELECT COUNT(*) AS devices, COUNT(DISTINCT device_id) AS distinct_devices FROM customer_device;
