-- =====================================================================
-- OwoTrust Digital Bank (simulated) - Portfolio 1
-- 02_seed_data.sql : small, hand-written, realistic sample data
--
-- All people, BVNs, phone numbers and account numbers are FICTIONAL.
-- E-mails use the reserved example.com / .example domains.
-- Foreign keys are resolved through natural keys (branch_code,
-- staff_number, bvn, account_number) instead of hard-coding surrogate IDs.
-- Larger volumes for performance testing are generated in Portfolio 2.
-- =====================================================================

SET timezone = 'Africa/Lagos';

BEGIN;

TRUNCATE bank_transaction, account_holder, account, account_type,
         customer, employee, branch, kyc_tier RESTART IDENTITY CASCADE;

-- ---------------------------------------------------------------------
-- KYC tiers (simplified from the CBN tiered-KYC framework)
-- ---------------------------------------------------------------------
INSERT INTO kyc_tier (tier_level, description, daily_debit_limit, max_balance) VALUES
    (1, 'Tier 1 - phone number and BVN only, low-value account',     50000.00,  300000.00),
    (2, 'Tier 2 - BVN and government ID verified',                   200000.00, 500000.00),
    (3, 'Tier 3 - full KYC including address verification',          5000000.00, NULL);

-- ---------------------------------------------------------------------
-- Branches
-- ---------------------------------------------------------------------
INSERT INTO branch (branch_code, branch_name, address_line, city, state, opened_on) VALUES
    ('001', 'Lagos Island Main',  '12 Marina Road',          'Lagos Island',  'Lagos',  '2019-03-01'),
    ('002', 'Ikeja',              '45 Allen Avenue',         'Ikeja',         'Lagos',  '2020-06-15'),
    ('003', 'Abuja Central',      '8 Ahmadu Bello Way',      'Abuja',         'FCT',    '2021-01-10'),
    ('004', 'Ibadan Ring Road',   '22 Ring Road',            'Ibadan',        'Oyo',    '2022-04-04'),
    ('005', 'Port Harcourt GRA',  '17 Aba Road',             'Port Harcourt', 'Rivers', '2023-09-01');

-- ---------------------------------------------------------------------
-- Employees
-- ---------------------------------------------------------------------
INSERT INTO employee (staff_number, branch_id, first_name, last_name, email, role, hired_on)
SELECT v.staff_number, b.branch_id, v.first_name, v.last_name, v.email, v.role, v.hired_on::date
FROM (VALUES
    ('OT00001', '001', 'Chinedu', 'Okafor',  'chinedu.okafor@owotrust.example',  'BRANCH_MANAGER',     '2019-02-15'),
    ('OT00002', '001', 'Funke',   'Adeyemi', 'funke.adeyemi@owotrust.example',   'TELLER',             '2019-03-01'),
    ('OT00003', '001', 'Ibrahim', 'Musa',    'ibrahim.musa@owotrust.example',    'COMPLIANCE_OFFICER', '2020-01-20'),
    ('OT00004', '002', 'Ngozi',   'Eze',     'ngozi.eze@owotrust.example',       'BRANCH_MANAGER',     '2020-06-01'),
    ('OT00005', '002', 'Tunde',   'Bakare',  'tunde.bakare@owotrust.example',    'TELLER',             '2020-06-15'),
    ('OT00006', '003', 'Aisha',   'Bello',   'aisha.bello@owotrust.example',     'BRANCH_MANAGER',     '2021-01-04'),
    ('OT00007', '003', 'Emeka',   'Nwosu',   'emeka.nwosu@owotrust.example',     'TELLER',             '2021-01-10'),
    ('OT00008', '004', 'Yetunde', 'Alabi',   'yetunde.alabi@owotrust.example',   'TELLER',             '2022-04-04'),
    ('OT00009', '005', 'Ebi',     'Douglas', 'ebi.douglas@owotrust.example',     'TELLER',             '2023-09-01'),
    ('OT00010', '001', 'Kemi',    'Oladipo', 'kemi.oladipo@owotrust.example',    'AUDITOR',            '2021-07-12'),
    ('OT00011', '002', 'Segun',   'Ojo',     'segun.ojo@owotrust.example',       'CUSTOMER_SERVICE',   '2022-11-01')
) AS v(staff_number, branch_code, first_name, last_name, email, role, hired_on)
JOIN branch b ON b.branch_code = v.branch_code
ORDER BY v.staff_number;

-- ---------------------------------------------------------------------
-- Customers
-- ---------------------------------------------------------------------
INSERT INTO customer (bvn, first_name, last_name, email, phone, date_of_birth,
                      address_line, city, state, kyc_tier, status, created_at) VALUES
    ('22100000001', 'Adaeze',    'Okonkwo',   'adaeze.okonkwo@example.com',   '+2348030000001', '1988-04-12', '5 Admiralty Way',      'Lekki',         'Lagos',  3, 'ACTIVE',    '2026-08-20 09:30'),
    ('22100000002', 'Babatunde', 'Ogundipe',  'b.ogundipe@example.com',       '+2348030000002', '1979-11-30', '14 Awolowo Road',      'Ikoyi',         'Lagos',  3, 'ACTIVE',    '2026-08-21 09:00'),
    ('22100000003', 'Chiamaka',  'Obi',       'chiamaka.obi@example.com',     '+2348030000003', '1995-02-07', '3 Opebi Road',         'Ikeja',         'Lagos',  2, 'ACTIVE',    '2026-08-04 15:00'),
    ('22100000004', 'Damilola',  'Ogunleye',  NULL,                           '+2348030000004', '2003-06-21', NULL,                   NULL,            NULL,     1, 'ACTIVE',    '2026-08-29 08:00'),
    ('22100000005', 'Emmanuel',  'Okoro',     'emmanuel.okoro@example.com',   '+2348030000005', '1983-09-15', '21 Aminu Kano Crescent','Abuja',        'FCT',    3, 'ACTIVE',    '2026-08-27 09:00'),
    ('22100000006', 'Fatima',    'Abdullahi', 'fatima.abdullahi@example.com', '+2348030000006', '1992-01-25', '7 Gimbiya Street',     'Abuja',         'FCT',    2, 'ACTIVE',    '2026-08-30 10:00'),
    ('22100000007', 'Gbenga',    'Ajayi',     'gbenga.ajayi@example.com',     '+2348030000007', '1990-07-03', '11 Bodija Estate',     'Ibadan',        'Oyo',    2, 'ACTIVE',    '2026-08-31 09:00'),
    ('22100000008', 'Halima',    'Sani',      NULL,                           '+2348030000008', '2001-12-09', NULL,                   'Abuja',         'FCT',    1, 'ACTIVE',    '2026-08-31 11:00'),
    ('22100000009', 'Ifeanyi',   'Uche',      'ifeanyi.uche@example.com',     '+2348030000009', '1985-05-18', '9 Woji Road',          'Port Harcourt', 'Rivers', 3, 'ACTIVE',    '2026-08-26 09:00'),
    ('22100000010', 'Jumoke',    'Adebayo',   'jumoke.adebayo@example.com',   '+2348030000010', '1998-03-28', '4 Ring Road',          'Ibadan',        'Oyo',    2, 'ACTIVE',    '2026-09-01 09:00'),
    ('22100000011', 'Kelechi',   'Nnamdi',    'kelechi.nnamdi@example.com',   '+2348030000011', '1981-10-01', '30 Trans-Amadi Road',  'Port Harcourt', 'Rivers', 3, 'ACTIVE',    '2026-08-26 10:00'),
    ('22100000012', 'Lola',      'Bankole',   'lola.bankole@example.com',     '+2348030000012', '2000-08-14', NULL,                   'Ikeja',         'Lagos',  1, 'SUSPENDED', '2026-09-01 12:00'),
    ('22100000013', 'Musa',      'Danjuma',   'musa.danjuma@example.com',     '+2348030000013', '1993-04-04', '2 Wuse Zone 4',        'Abuja',         'FCT',    2, 'ACTIVE',    '2026-08-30 12:00'),
    ('22100000014', 'Nkechi',    'Ibe',       'nkechi.ibe@example.com',       '+2348030000014', '1987-12-22', '18 Bourdillon Road',   'Ikoyi',         'Lagos',  3, 'ACTIVE',    '2026-08-22 09:00'),
    ('22100000015', 'Oluwaseun', 'Akande',    'seun.akande@example.com',      '+2348030000015', '1991-06-06', '6 Isaac John Street',  'Ikeja',         'Lagos',  3, 'ACTIVE',    '2026-09-02 08:00');

-- ---------------------------------------------------------------------
-- Account products
-- ---------------------------------------------------------------------
INSERT INTO account_type (type_code, type_name, currency, annual_interest_rate, minimum_balance, allows_overdraft) VALUES
    ('SAV_NGN', 'Savings Account',            'NGN', 4.00, 1000.00, FALSE),
    ('CUR_NGN', 'Current Account',            'NGN', 0.00, 5000.00, TRUE),
    ('DOM_USD', 'Domiciliary Account (USD)',  'USD', 0.50,  100.00, FALSE);

-- ---------------------------------------------------------------------
-- Accounts (balance starts at 0 and is derived from transactions below)
-- ---------------------------------------------------------------------
INSERT INTO account (account_number, type_code, branch_id, opened_by, overdraft_limit, status, opened_at, closed_at)
SELECT v.account_number, v.type_code, b.branch_id, e.employee_id, v.overdraft_limit,
       v.status, v.opened_at::timestamptz, v.closed_at::timestamptz
FROM (VALUES
    ('3010000001', 'SAV_NGN', '001', 'OT00002',      0, 'ACTIVE', '2026-08-20 10:00', NULL),
    ('3010000002', 'CUR_NGN', '001', 'OT00001', 100000, 'ACTIVE', '2026-08-20 10:30', NULL),
    ('3010000003', 'SAV_NGN', '001', 'OT00002',      0, 'ACTIVE', '2026-08-21 10:00', NULL),
    ('3010000004', 'CUR_NGN', '001', 'OT00001', 500000, 'ACTIVE', '2026-08-25 11:00', NULL),
    ('3010000005', 'SAV_NGN', '002', NULL,           0, 'ACTIVE', '2026-08-28 14:00', NULL),
    ('3010000006', 'SAV_NGN', '002', NULL,           0, 'ACTIVE', '2026-08-29 08:15', NULL),
    ('3010000007', 'SAV_NGN', '003', 'OT00007',      0, 'ACTIVE', '2026-08-27 10:00', NULL),
    ('3010000008', 'DOM_USD', '003', 'OT00007',      0, 'ACTIVE', '2026-08-27 10:20', NULL),
    ('3010000009', 'SAV_NGN', '003', NULL,           0, 'ACTIVE', '2026-08-30 10:15', NULL),
    ('3010000010', 'SAV_NGN', '004', 'OT00008',      0, 'ACTIVE', '2026-08-31 09:30', NULL),
    ('3010000011', 'SAV_NGN', '003', NULL,           0, 'ACTIVE', '2026-08-31 11:10', NULL),
    ('3010000012', 'SAV_NGN', '005', 'OT00009',      0, 'ACTIVE', '2026-08-26 09:30', NULL),
    ('3010000013', 'DOM_USD', '005', 'OT00009',      0, 'ACTIVE', '2026-08-26 09:45', NULL),
    ('3010000014', 'SAV_NGN', '004', NULL,           0, 'ACTIVE', '2026-09-01 09:10', NULL),
    ('3010000015', 'CUR_NGN', '005', 'OT00009', 200000, 'ACTIVE', '2026-08-26 10:30', NULL),
    ('3010000016', 'SAV_NGN', '002', NULL,           0, 'FROZEN', '2026-09-01 12:10', NULL),
    ('3010000017', 'SAV_NGN', '003', 'OT00007',      0, 'ACTIVE', '2026-08-30 12:30', NULL),
    ('3010000018', 'SAV_NGN', '001', 'OT00002',      0, 'ACTIVE', '2026-08-22 10:00', NULL),
    ('3010000019', 'SAV_NGN', '001', NULL,           0, 'ACTIVE', '2026-09-02 08:20', NULL),
    ('3010000020', 'SAV_NGN', '002', 'OT00005',      0, 'CLOSED', '2026-08-05 09:00', '2026-09-19 10:30')
) AS v(account_number, type_code, branch_code, staff_number, overdraft_limit, status, opened_at, closed_at)
JOIN branch b        ON b.branch_code  = v.branch_code
LEFT JOIN employee e ON e.staff_number = v.staff_number
ORDER BY v.account_number;

-- ---------------------------------------------------------------------
-- Account holders (3010000004 is a joint business account)
-- ---------------------------------------------------------------------
INSERT INTO account_holder (account_id, customer_id, holder_role, added_at)
SELECT a.account_id, c.customer_id, v.holder_role, a.opened_at
FROM (VALUES
    ('3010000001', '22100000001', 'PRIMARY'),
    ('3010000002', '22100000001', 'PRIMARY'),
    ('3010000003', '22100000002', 'PRIMARY'),
    ('3010000004', '22100000002', 'PRIMARY'),
    ('3010000004', '22100000014', 'JOINT'),
    ('3010000005', '22100000003', 'PRIMARY'),
    ('3010000006', '22100000004', 'PRIMARY'),
    ('3010000007', '22100000005', 'PRIMARY'),
    ('3010000008', '22100000005', 'PRIMARY'),
    ('3010000009', '22100000006', 'PRIMARY'),
    ('3010000010', '22100000007', 'PRIMARY'),
    ('3010000011', '22100000008', 'PRIMARY'),
    ('3010000012', '22100000009', 'PRIMARY'),
    ('3010000013', '22100000009', 'PRIMARY'),
    ('3010000014', '22100000010', 'PRIMARY'),
    ('3010000015', '22100000011', 'PRIMARY'),
    ('3010000016', '22100000012', 'PRIMARY'),
    ('3010000017', '22100000013', 'PRIMARY'),
    ('3010000018', '22100000014', 'PRIMARY'),
    ('3010000019', '22100000015', 'PRIMARY'),
    ('3010000020', '22100000003', 'PRIMARY')
) AS v(account_number, bvn, holder_role)
JOIN account  a ON a.account_number = v.account_number
JOIN customer c ON c.bvn            = v.bvn;

-- ---------------------------------------------------------------------
-- Transactions (Aug - Nov 2026). Posted rows get completed_at = created_at + 2s.
-- Includes: deposits, withdrawals, transfers, an overdraft drawdown,
-- monthly fees, two FAILED transfers, one PENDING transfer and (below)
-- a transfer that is later REVERSED.
-- ---------------------------------------------------------------------
INSERT INTO bank_transaction (reference, txn_type, channel, debit_account_id, credit_account_id,
                              amount, status, narration, initiated_by, failure_reason,
                              created_at, completed_at)
SELECT v.reference, v.txn_type, v.channel, d.account_id, c.account_id,
       v.amount, v.status, v.narration, e.employee_id, v.failure_reason,
       v.created_at::timestamptz,
       CASE WHEN v.status = 'COMPLETED' THEN v.created_at::timestamptz + INTERVAL '2 seconds' END
FROM (VALUES
    ('OTB2608100001', 'DEPOSIT',    'BRANCH', NULL,         '3010000020',   20000.00, 'COMPLETED', 'Cash deposit',                  'OT00005', NULL,                 '2026-08-10 10:00'),
    ('OTB2609010002', 'DEPOSIT',    'BRANCH', NULL,         '3010000001',  500000.00, 'COMPLETED', 'Cash deposit',                  'OT00002', NULL,                 '2026-09-01 09:10'),
    ('OTB2609010003', 'DEPOSIT',    'BRANCH', NULL,         '3010000002', 1200000.00, 'COMPLETED', 'Cash deposit',                  'OT00002', NULL,                 '2026-09-01 09:40'),
    ('OTB2609010004', 'DEPOSIT',    'BRANCH', NULL,         '3010000003',  350000.00, 'COMPLETED', 'Cash deposit',                  'OT00002', NULL,                 '2026-09-01 10:05'),
    ('OTB2609010005', 'DEPOSIT',    'BRANCH', NULL,         '3010000004', 2500000.00, 'COMPLETED', 'Business capital lodgement',    'OT00002', NULL,                 '2026-09-01 11:20'),
    ('OTB2609020006', 'DEPOSIT',    'MOBILE', NULL,         '3010000005',  180000.00, 'COMPLETED', 'Card funding',                  NULL,      NULL,                 '2026-09-02 08:30'),
    ('OTB2609020007', 'DEPOSIT',    'MOBILE', NULL,         '3010000006',   45000.00, 'COMPLETED', 'Card funding',                  NULL,      NULL,                 '2026-09-02 12:00'),
    ('OTB2609020008', 'DEPOSIT',    'BRANCH', NULL,         '3010000007',  800000.00, 'COMPLETED', 'Cash deposit',                  'OT00007', NULL,                 '2026-09-02 14:15'),
    ('OTB2609020009', 'DEPOSIT',    'BRANCH', NULL,         '3010000008',    2500.00, 'COMPLETED', 'USD cash lodgement',            'OT00007', NULL,                 '2026-09-02 15:00'),
    ('OTB2609030010', 'DEPOSIT',    'MOBILE', NULL,         '3010000009',  150000.00, 'COMPLETED', 'Card funding',                  NULL,      NULL,                 '2026-09-03 09:00'),
    ('OTB2609030011', 'DEPOSIT',    'BRANCH', NULL,         '3010000010',  220000.00, 'COMPLETED', 'Cash deposit',                  'OT00008', NULL,                 '2026-09-03 10:30'),
    ('OTB2609030012', 'DEPOSIT',    'MOBILE', NULL,         '3010000011',   30000.00, 'COMPLETED', 'Card funding',                  NULL,      NULL,                 '2026-09-03 11:00'),
    ('OTB2609030013', 'DEPOSIT',    'BRANCH', NULL,         '3010000012',  950000.00, 'COMPLETED', 'Cash deposit',                  'OT00009', NULL,                 '2026-09-03 13:45'),
    ('OTB2609030014', 'DEPOSIT',    'BRANCH', NULL,         '3010000013',    4000.00, 'COMPLETED', 'USD cash lodgement',            'OT00009', NULL,                 '2026-09-03 14:10'),
    ('OTB2609040015', 'DEPOSIT',    'MOBILE', NULL,         '3010000014',  120000.00, 'COMPLETED', 'Card funding',                  NULL,      NULL,                 '2026-09-04 09:20'),
    ('OTB2609040016', 'DEPOSIT',    'BRANCH', NULL,         '3010000015', 3000000.00, 'COMPLETED', 'Cash deposit',                  'OT00009', NULL,                 '2026-09-04 10:00'),
    ('OTB2609040017', 'DEPOSIT',    'MOBILE', NULL,         '3010000016',   60000.00, 'COMPLETED', 'Card funding',                  NULL,      NULL,                 '2026-09-04 11:30'),
    ('OTB2609040018', 'DEPOSIT',    'MOBILE', NULL,         '3010000017',  175000.00, 'COMPLETED', 'Card funding',                  NULL,      NULL,                 '2026-09-04 12:00'),
    ('OTB2609050019', 'DEPOSIT',    'BRANCH', NULL,         '3010000018',  600000.00, 'COMPLETED', 'Cash deposit',                  'OT00002', NULL,                 '2026-09-05 09:00'),
    ('OTB2609050020', 'DEPOSIT',    'MOBILE', NULL,         '3010000019',  400000.00, 'COMPLETED', 'Card funding',                  NULL,      NULL,                 '2026-09-05 09:30'),
    ('OTB2609080021', 'TRANSFER',   'MOBILE', '3010000001', '3010000005',   50000.00, 'COMPLETED', 'Rent contribution',             NULL,      NULL,                 '2026-09-08 10:15'),
    ('OTB2609090022', 'WITHDRAWAL', 'ATM',    '3010000003', NULL,           40000.00, 'COMPLETED', 'ATM withdrawal',                NULL,      NULL,                 '2026-09-09 13:00'),
    ('OTB2609100023', 'TRANSFER',   'WEB',    '3010000004', '3010000018',  300000.00, 'COMPLETED', 'Supplier payment',              NULL,      NULL,                 '2026-09-10 16:20'),
    ('OTB2609120024', 'TRANSFER',   'MOBILE', '3010000015', '3010000012',  250000.00, 'COMPLETED', 'Family support',                NULL,      NULL,                 '2026-09-12 08:45'),
    ('OTB2609150025', 'WITHDRAWAL', 'BRANCH', '3010000007', NULL,          100000.00, 'COMPLETED', 'Cash withdrawal',               'OT00007', NULL,                 '2026-09-15 11:00'),
    ('OTB2609160026', 'TRANSFER',   'MOBILE', '3010000009', '3010000017',   20000.00, 'COMPLETED', 'Lunch refund',                  NULL,      NULL,                 '2026-09-16 14:30'),
    ('OTB2609180027', 'TRANSFER',   'USSD',   '3010000006', '3010000011',    5000.00, 'COMPLETED', 'Airtime money',                 NULL,      NULL,                 '2026-09-18 19:05'),
    ('OTB2609190028', 'WITHDRAWAL', 'BRANCH', '3010000020', NULL,           20000.00, 'COMPLETED', 'Account closure payout',        'OT00005', NULL,                 '2026-09-19 10:00'),
    ('OTB2609200029', 'TRANSFER',   'MOBILE', '3010000010', '3010000014',   15000.00, 'COMPLETED', 'School fees share',             NULL,      NULL,                 '2026-09-20 15:30'),
    ('OTB2609220030', 'TRANSFER',   'MOBILE', '3010000005', '3010000006',  500000.00, 'FAILED',    'Gadget purchase',               NULL,      'Insufficient funds', '2026-09-22 09:10'),
    ('OTB2609220031', 'TRANSFER',   'MOBILE', '3010000005', '3010000006',   25000.00, 'COMPLETED', 'Gadget purchase (deposit)',     NULL,      NULL,                 '2026-09-22 09:12'),
    ('OTB2609250032', 'TRANSFER',   'WEB',    '3010000002', '3010000019', 1250000.00, 'COMPLETED', 'Car purchase - uses overdraft', NULL,      NULL,                 '2026-09-25 17:40'),
    ('OTB2609280033', 'TRANSFER',   'MOBILE', '3010000012', '3010000001',   75000.00, 'COMPLETED', 'Payment (wrong beneficiary)',   NULL,      NULL,                 '2026-09-28 12:00'),
    ('OTB2609300034', 'FEE',        'SYSTEM', '3010000002', NULL,              50.00, 'COMPLETED', 'Card maintenance fee - Sep',    NULL,      NULL,                 '2026-09-30 23:59'),
    ('OTB2609300035', 'FEE',        'SYSTEM', '3010000004', NULL,              50.00, 'COMPLETED', 'Card maintenance fee - Sep',    NULL,      NULL,                 '2026-09-30 23:59'),
    ('OTB2609300036', 'FEE',        'SYSTEM', '3010000015', NULL,              50.00, 'COMPLETED', 'Card maintenance fee - Sep',    NULL,      NULL,                 '2026-09-30 23:59'),
    ('OTB2610010037', 'DEPOSIT',    'BRANCH', NULL,         '3010000002',  300000.00, 'COMPLETED', 'Cash deposit',                  'OT00002', NULL,                 '2026-10-01 09:00'),
    ('OTB2610030038', 'TRANSFER',   'MOBILE', '3010000019', '3010000003',  200000.00, 'COMPLETED', 'Loan repayment',                NULL,      NULL,                 '2026-10-03 11:11'),
    ('OTB2610050039', 'TRANSFER',   'MOBILE', '3010000018', '3010000004',  150000.00, 'COMPLETED', 'Capital top-up',                NULL,      NULL,                 '2026-10-05 13:00'),
    ('OTB2610070040', 'WITHDRAWAL', 'POS',    '3010000014', NULL,            8500.00, 'COMPLETED', 'POS purchase - Bodija market',  NULL,      NULL,                 '2026-10-07 10:20'),
    ('OTB2610090041', 'TRANSFER',   'MOBILE', '3010000013', '3010000008',     500.00, 'COMPLETED', 'USD transfer',                  NULL,      NULL,                 '2026-10-09 14:00'),
    ('OTB2610100042', 'TRANSFER',   'MOBILE', '3010000016', '3010000006',   10000.00, 'FAILED',    'Transfer',                      NULL,      'Account frozen',     '2026-10-10 09:30'),
    ('OTB2610120043', 'WITHDRAWAL', 'ATM',    '3010000017', NULL,           30000.00, 'COMPLETED', 'ATM withdrawal',                NULL,      NULL,                 '2026-10-12 18:00'),
    ('OTB2610150044', 'TRANSFER',   'MOBILE', '3010000007', '3010000009',   45000.00, 'COMPLETED', 'Contribution',                  NULL,      NULL,                 '2026-10-15 08:00'),
    ('OTB2610180045', 'DEPOSIT',    'MOBILE', NULL,         '3010000011',   15000.00, 'COMPLETED', 'Card funding',                  NULL,      NULL,                 '2026-10-18 12:30'),
    ('OTB2610200046', 'TRANSFER',   'USSD',   '3010000011', '3010000006',   12000.00, 'COMPLETED', 'Transport money',               NULL,      NULL,                 '2026-10-20 20:15'),
    ('OTB2610250047', 'TRANSFER',   'MOBILE', '3010000003', '3010000010',   60000.00, 'COMPLETED', 'Business support',              NULL,      NULL,                 '2026-10-25 10:00'),
    ('OTB2610310048', 'FEE',        'SYSTEM', '3010000002', NULL,              50.00, 'COMPLETED', 'Card maintenance fee - Oct',    NULL,      NULL,                 '2026-10-31 23:59'),
    ('OTB2610310049', 'FEE',        'SYSTEM', '3010000004', NULL,              50.00, 'COMPLETED', 'Card maintenance fee - Oct',    NULL,      NULL,                 '2026-10-31 23:59'),
    ('OTB2610310050', 'FEE',        'SYSTEM', '3010000015', NULL,              50.00, 'COMPLETED', 'Card maintenance fee - Oct',    NULL,      NULL,                 '2026-10-31 23:59'),
    ('OTB2611030051', 'TRANSFER',   'MOBILE', '3010000001', '3010000007',   30000.00, 'PENDING',   'Awaiting fraud review',         NULL,      NULL,                 '2026-11-03 21:55')
) AS v(reference, txn_type, channel, debit_acct, credit_acct, amount, status, narration, staff_number, failure_reason, created_at)
LEFT JOIN account  d ON d.account_number = v.debit_acct
LEFT JOIN account  c ON c.account_number = v.credit_acct
LEFT JOIN employee e ON e.staff_number   = v.staff_number
ORDER BY v.created_at, v.reference;

-- ---------------------------------------------------------------------
-- Reverse the wrong-beneficiary transfer OTB2609280033:
-- insert a REVERSAL with the legs swapped, then mark the original REVERSED.
-- ---------------------------------------------------------------------
INSERT INTO bank_transaction (reference, txn_type, channel, debit_account_id, credit_account_id,
                              amount, status, narration, initiated_by, reverses_txn_id,
                              created_at, completed_at)
SELECT 'OTB2609280052', 'REVERSAL', 'SYSTEM', o.credit_account_id, o.debit_account_id,
       o.amount, 'COMPLETED', 'Reversal of ' || o.reference || ' (wrong beneficiary)',
       (SELECT employee_id FROM employee WHERE staff_number = 'OT00001'),
       o.txn_id, TIMESTAMPTZ '2026-09-28 16:30', TIMESTAMPTZ '2026-09-28 16:30:02'
FROM bank_transaction o
WHERE o.reference = 'OTB2609280033';

UPDATE bank_transaction
SET status = 'REVERSED'
WHERE reference = 'OTB2609280033';

-- ---------------------------------------------------------------------
-- Derive every stored balance from the posted transactions.
-- (In normal operation the balance is updated by the posting logic in
-- Portfolio 3; this one-off recomputation initialises the seed data.)
-- ---------------------------------------------------------------------
UPDATE account a
SET balance = (
    SELECT COALESCE(SUM(CASE WHEN t.credit_account_id = a.account_id THEN t.amount ELSE -t.amount END), 0)
    FROM bank_transaction t
    WHERE t.status IN ('COMPLETED','REVERSED')
      AND a.account_id IN (t.debit_account_id, t.credit_account_id)
);

COMMIT;
