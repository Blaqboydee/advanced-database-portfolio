-- =====================================================================
-- OwoTrust Digital Bank (simulated) - Portfolio 1: Database Design
-- 01_schema.sql : relational schema, keys and constraints
-- DBMS          : PostgreSQL 16
--
-- Re-runnable: drops and recreates every table.
-- Foreign keys use the default NO ACTION (behaves like RESTRICT) on
-- delete: financial records are never hard-deleted, they are closed or
-- reversed through status changes instead.
-- =====================================================================

DROP TABLE IF EXISTS bank_transaction CASCADE;
DROP TABLE IF EXISTS account_holder   CASCADE;
DROP TABLE IF EXISTS account          CASCADE;
DROP TABLE IF EXISTS account_type     CASCADE;
DROP TABLE IF EXISTS customer         CASCADE;
DROP TABLE IF EXISTS employee         CASCADE;
DROP TABLE IF EXISTS branch           CASCADE;
DROP TABLE IF EXISTS kyc_tier         CASCADE;


-- ---------------------------------------------------------------------
-- KYC_TIER: lookup table for the CBN three-tier KYC framework (simplified).
-- Limits depend on the tier, not on the customer, so they live here (3NF).
-- ---------------------------------------------------------------------
CREATE TABLE kyc_tier (
    tier_level         SMALLINT      PRIMARY KEY CHECK (tier_level BETWEEN 1 AND 3),
    description        VARCHAR(120)  NOT NULL,
    daily_debit_limit  NUMERIC(18,2) NOT NULL CHECK (daily_debit_limit > 0),
    max_balance        NUMERIC(18,2)          CHECK (max_balance > 0)   -- NULL = no cap (Tier 3)
);


-- ---------------------------------------------------------------------
-- BRANCH: physical branches; every account is domiciled at one branch.
-- ---------------------------------------------------------------------
CREATE TABLE branch (
    branch_id     INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    branch_code   CHAR(3)      NOT NULL UNIQUE CHECK (branch_code ~ '^[0-9]{3}$'),
    branch_name   VARCHAR(100) NOT NULL,
    address_line  VARCHAR(200) NOT NULL,
    city          VARCHAR(60)  NOT NULL,
    state         VARCHAR(60)  NOT NULL,
    opened_on     DATE         NOT NULL
);


-- ---------------------------------------------------------------------
-- EMPLOYEE: bank staff (tellers, managers, compliance, auditors).
-- ---------------------------------------------------------------------
CREATE TABLE employee (
    employee_id   INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    staff_number  CHAR(7)      NOT NULL UNIQUE CHECK (staff_number ~ '^OT[0-9]{5}$'),
    branch_id     INT          NOT NULL REFERENCES branch (branch_id),
    first_name    VARCHAR(50)  NOT NULL,
    last_name     VARCHAR(50)  NOT NULL,
    email         VARCHAR(120) NOT NULL UNIQUE,
    role          VARCHAR(20)  NOT NULL
                  CHECK (role IN ('TELLER','CUSTOMER_SERVICE','BRANCH_MANAGER',
                                  'COMPLIANCE_OFFICER','AUDITOR')),
    hired_on      DATE         NOT NULL,
    is_active     BOOLEAN      NOT NULL DEFAULT TRUE
);


-- ---------------------------------------------------------------------
-- CUSTOMER: account holders. BVN is a candidate key but NOT the primary
-- key: it is sensitive PII and should not be copied into every child
-- table as a foreign key. Phone/email can change, so they are not
-- suitable primary keys either -> surrogate customer_id.
-- ---------------------------------------------------------------------
CREATE TABLE customer (
    customer_id    INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    bvn            CHAR(11)     NOT NULL UNIQUE CHECK (bvn ~ '^[0-9]{11}$'),
    first_name     VARCHAR(50)  NOT NULL,
    last_name      VARCHAR(50)  NOT NULL,
    email          VARCHAR(120)          UNIQUE
                   CHECK (email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'),   -- optional for Tier 1
    phone          VARCHAR(14)  NOT NULL UNIQUE CHECK (phone ~ '^\+234[0-9]{10}$'),
    date_of_birth  DATE         NOT NULL CHECK (date_of_birth > DATE '1900-01-01'),
    address_line   VARCHAR(200),
    city           VARCHAR(60),
    state          VARCHAR(60),
    kyc_tier       SMALLINT     NOT NULL DEFAULT 1 REFERENCES kyc_tier (tier_level),
    status         VARCHAR(10)  NOT NULL DEFAULT 'ACTIVE'
                   CHECK (status IN ('ACTIVE','SUSPENDED','CLOSED')),
    created_at     TIMESTAMPTZ  NOT NULL DEFAULT now()
);


-- ---------------------------------------------------------------------
-- ACCOUNT_TYPE: product catalogue. Natural key (type_code) is used as the
-- PK because it is short, stable and meaningful. Currency, interest rate
-- and overdraft eligibility depend on the product, not the account (3NF).
-- ---------------------------------------------------------------------
CREATE TABLE account_type (
    type_code             VARCHAR(10)   PRIMARY KEY,
    type_name             VARCHAR(60)   NOT NULL UNIQUE,
    currency              CHAR(3)       NOT NULL CHECK (currency ~ '^[A-Z]{3}$'),
    annual_interest_rate  NUMERIC(5,2)  NOT NULL DEFAULT 0
                          CHECK (annual_interest_rate BETWEEN 0 AND 100),
    minimum_balance       NUMERIC(18,2) NOT NULL DEFAULT 0 CHECK (minimum_balance >= 0),
    allows_overdraft      BOOLEAN       NOT NULL DEFAULT FALSE
);


-- ---------------------------------------------------------------------
-- ACCOUNT: one row per bank account (10-digit NUBAN account number).
-- balance is a DELIBERATE, CONTROLLED denormalisation: it can be derived
-- from bank_transaction, but is stored so a debit can be authorised
-- without summing the whole history. Kept consistent by updating it in
-- the same ACID transaction that posts money (see Portfolio 3) and checked
-- by the audit query in 04_verify.sql.
-- ---------------------------------------------------------------------
CREATE TABLE account (
    account_id       INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    account_number   CHAR(10)      NOT NULL UNIQUE CHECK (account_number ~ '^[0-9]{10}$'),
    type_code        VARCHAR(10)   NOT NULL REFERENCES account_type (type_code),
    branch_id        INT           NOT NULL REFERENCES branch (branch_id),
    opened_by        INT                    REFERENCES employee (employee_id),  -- NULL = opened on the mobile app
    balance          NUMERIC(18,2) NOT NULL DEFAULT 0,
    overdraft_limit  NUMERIC(18,2) NOT NULL DEFAULT 0 CHECK (overdraft_limit >= 0),
    status           VARCHAR(10)   NOT NULL DEFAULT 'ACTIVE'
                     CHECK (status IN ('ACTIVE','DORMANT','FROZEN','CLOSED')),
    opened_at        TIMESTAMPTZ   NOT NULL DEFAULT now(),
    closed_at        TIMESTAMPTZ,

    -- an account may only go negative as far as its approved overdraft
    CONSTRAINT chk_account_balance_floor CHECK (balance >= -overdraft_limit),
    -- closed_at is set if and only if the account is CLOSED
    CONSTRAINT chk_account_closed_state  CHECK ((status = 'CLOSED') = (closed_at IS NOT NULL)),
    CONSTRAINT chk_account_close_order   CHECK (closed_at IS NULL OR closed_at >= opened_at)
);

COMMENT ON COLUMN account.balance IS
    'Derived value stored for performance; must equal SUM(credits) - SUM(debits) of posted transactions.';


-- ---------------------------------------------------------------------
-- ACCOUNT_HOLDER: resolves the M:N relationship between CUSTOMER and
-- ACCOUNT (joint accounts have several holders; a customer can hold
-- several accounts). Composite primary key.
-- ---------------------------------------------------------------------
CREATE TABLE account_holder (
    account_id   INT         NOT NULL REFERENCES account (account_id),
    customer_id  INT         NOT NULL REFERENCES customer (customer_id),
    holder_role  VARCHAR(10) NOT NULL DEFAULT 'PRIMARY'
                 CHECK (holder_role IN ('PRIMARY','JOINT')),
    added_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (account_id, customer_id)
);

-- at most ONE primary holder per account (partial unique index)
CREATE UNIQUE INDEX uq_account_single_primary_holder
    ON account_holder (account_id)
    WHERE holder_role = 'PRIMARY';


-- ---------------------------------------------------------------------
-- BANK_TRANSACTION: every money movement. Each row names the account it
-- debits and/or the account it credits:
--   DEPOSIT     -> credit only        WITHDRAWAL / FEE -> debit only
--   TRANSFER    -> debit and credit   REVERSAL         -> opposite legs of
--                                                          the original
-- Only rows with status COMPLETED or REVERSED have moved money.
-- Scope: transfers are between OwoTrust accounts of the same currency
-- (interbank NIP transfers and FX are out of scope).
-- ---------------------------------------------------------------------
CREATE TABLE bank_transaction (
    txn_id             BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    reference          VARCHAR(20)   NOT NULL UNIQUE,   -- business reference, also an idempotency key
    txn_type           VARCHAR(10)   NOT NULL
                       CHECK (txn_type IN ('DEPOSIT','WITHDRAWAL','TRANSFER','REVERSAL','FEE')),
    channel            VARCHAR(10)   NOT NULL
                       CHECK (channel IN ('BRANCH','MOBILE','WEB','USSD','ATM','POS','SYSTEM')),
    debit_account_id   INT                    REFERENCES account (account_id),
    credit_account_id  INT                    REFERENCES account (account_id),
    amount             NUMERIC(18,2) NOT NULL CHECK (amount > 0),
    status             VARCHAR(10)   NOT NULL DEFAULT 'PENDING'
                       CHECK (status IN ('PENDING','COMPLETED','FAILED','REVERSED')),
    narration          VARCHAR(140),
    initiated_by       INT                    REFERENCES employee (employee_id),  -- NULL = self-service
    reverses_txn_id    BIGINT                 UNIQUE REFERENCES bank_transaction (txn_id),
    failure_reason     VARCHAR(200),
    created_at         TIMESTAMPTZ   NOT NULL DEFAULT now(),
    completed_at       TIMESTAMPTZ,

    -- which legs each transaction type must have
    CONSTRAINT chk_txn_legs CHECK (
        (txn_type = 'DEPOSIT'             AND debit_account_id IS NULL     AND credit_account_id IS NOT NULL) OR
        (txn_type IN ('WITHDRAWAL','FEE') AND debit_account_id IS NOT NULL AND credit_account_id IS NULL)     OR
        (txn_type = 'TRANSFER'            AND debit_account_id IS NOT NULL AND credit_account_id IS NOT NULL) OR
        (txn_type = 'REVERSAL'            AND COALESCE(debit_account_id, credit_account_id) IS NOT NULL)
    ),
    -- cannot transfer to the same account
    CONSTRAINT chk_txn_distinct_accounts CHECK (debit_account_id <> credit_account_id),
    -- a REVERSAL must point at the transaction it reverses, and nothing else may
    CONSTRAINT chk_txn_reversal_link     CHECK ((txn_type = 'REVERSAL') = (reverses_txn_id IS NOT NULL)),
    -- completed_at is recorded exactly when money has moved
    CONSTRAINT chk_txn_completed_at      CHECK ((status IN ('COMPLETED','REVERSED')) = (completed_at IS NOT NULL)),
    CONSTRAINT chk_txn_completed_order   CHECK (completed_at IS NULL OR completed_at >= created_at),
    -- a failed transaction must say why
    CONSTRAINT chk_txn_failure_reason    CHECK (status <> 'FAILED' OR failure_reason IS NOT NULL),
    -- over-the-counter transactions must record the teller
    CONSTRAINT chk_txn_branch_teller     CHECK (channel <> 'BRANCH' OR initiated_by IS NOT NULL)
);

COMMENT ON TABLE bank_transaction IS
    'Money movements. Posted (balance-affecting) rows have status COMPLETED or REVERSED.';

-- NOTE: Apart from the indexes created automatically for PRIMARY KEY and
-- UNIQUE constraints, no secondary indexes are created here. PostgreSQL
-- does not index foreign keys automatically; that is left to Portfolio 2
-- so the effect of each index can be measured with EXPLAIN ANALYZE.
