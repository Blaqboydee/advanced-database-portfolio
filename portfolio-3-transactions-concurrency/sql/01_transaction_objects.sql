-- =====================================================================
-- OwoTrust Digital Bank (simulated) - Portfolio 3
-- 01_transaction_objects.sql : database objects that make money movement
--                              safe under concurrency
-- Run AFTER Portfolio 1's 01_schema.sql and 02_seed_data.sql.
--
--   1. audit_log table + trigger         (every balance/status change is recorded)
--   2. business-rule triggers            (Portfolio 1 §3.4 rules 2 and 3)
--   3. transfer_funds()                  (the SAFE transfer: locking, validation,
--                                         savepoint, idempotency)
--   4. transfer_funds_naive()            (a deliberately UNSAFE version, used
--                                         only to demonstrate lost updates)
-- =====================================================================

\set ON_ERROR_STOP on

-- supports the "spent today" query inside transfer_funds()
CREATE INDEX IF NOT EXISTS ix_txn_debit_acct_created ON bank_transaction (debit_account_id, created_at);

-- references for transfers created by transfer_funds() when the caller gives none
CREATE SEQUENCE IF NOT EXISTS txn_ref_seq;


-- ---------------------------------------------------------------------
-- 1. AUDIT LOG
--    Written by a trigger, so it is part of the SAME transaction as the
--    change: if the transaction rolls back, its audit rows disappear too.
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS audit_log;
CREATE TABLE audit_log (
    audit_id    BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    changed_at  TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    db_user     TEXT        NOT NULL DEFAULT current_user,
    txid        BIGINT      NOT NULL DEFAULT txid_current(),   -- which database transaction made the change
    table_name  TEXT        NOT NULL,
    row_key     TEXT        NOT NULL,
    action      TEXT        NOT NULL,
    old_values  JSONB,
    new_values  JSONB
);

CREATE OR REPLACE FUNCTION trg_audit_account() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO audit_log (table_name, row_key, action, old_values, new_values)
    VALUES ('account', NEW.account_number, TG_OP,
            jsonb_build_object('balance', OLD.balance, 'status', OLD.status, 'overdraft_limit', OLD.overdraft_limit),
            jsonb_build_object('balance', NEW.balance, 'status', NEW.status, 'overdraft_limit', NEW.overdraft_limit));
    RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS audit_account_changes ON account;
CREATE TRIGGER audit_account_changes
    AFTER UPDATE OF balance, status, overdraft_limit ON account
    FOR EACH ROW
    WHEN (OLD.balance IS DISTINCT FROM NEW.balance
       OR OLD.status IS DISTINCT FROM NEW.status
       OR OLD.overdraft_limit IS DISTINCT FROM NEW.overdraft_limit)
    EXECUTE FUNCTION trg_audit_account();


-- ---------------------------------------------------------------------
-- 2a. Rule: an overdraft is only allowed on products that permit one.
--     (Needs a look-up in account_type, so a CHECK constraint cannot do it.)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_check_overdraft_product() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.overdraft_limit > 0 AND NOT (SELECT allows_overdraft FROM account_type WHERE type_code = NEW.type_code) THEN
        RAISE EXCEPTION 'Account %: product % does not allow an overdraft', NEW.account_number, NEW.type_code
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS check_overdraft_product ON account;
CREATE TRIGGER check_overdraft_product
    BEFORE INSERT OR UPDATE OF overdraft_limit, type_code ON account
    FOR EACH ROW EXECUTE FUNCTION trg_check_overdraft_product();


-- ---------------------------------------------------------------------
-- 2b. Rule: every account must have a PRIMARY holder.
--     The account row is inserted BEFORE its holder row, so checking
--     immediately would always fail. A DEFERRABLE INITIALLY DEFERRED
--     constraint trigger postpones the check until COMMIT, when both rows
--     must exist.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_account_needs_primary_holder() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM account_holder
                   WHERE account_id = NEW.account_id AND holder_role = 'PRIMARY') THEN
        RAISE EXCEPTION 'Account % has no PRIMARY holder at commit time', NEW.account_number
            USING ERRCODE = 'integrity_constraint_violation';
    END IF;
    RETURN NULL;
END $$;

DROP TRIGGER IF EXISTS account_needs_primary_holder ON account;
CREATE CONSTRAINT TRIGGER account_needs_primary_holder
    AFTER INSERT ON account
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION trg_account_needs_primary_holder();


-- ---------------------------------------------------------------------
-- 3. transfer_funds(): the SAFE way to move money
--
--  * Locks both accounts in a fixed global order (lowest account_id first).
--    Every transfer takes its locks in the same order, so two transfers can
--    never wait for each other in a cycle, which means no deadlocks.
--  * Lock strength is FOR NO KEY UPDATE, not FOR UPDATE. We never change a
--    key, and FOR UPDATE also blocks the FOR KEY SHARE locks that
--    foreign-key checks take. The first version used FOR UPDATE and
--    deadlocked under load: a rejected transfer releases its locks (rollback
--    to savepoint), then its FAILED-row INSERT runs FK checks that lock the
--    two accounts in a different order. See evidence/06_stress_v1_*.txt.
--  * Locks the paying customer's row, so all debits of one customer are
--    serialised. Otherwise two concurrent transfers could both pass the
--    daily-limit check and together exceed it (write skew).
--  * Validates Portfolio 1 §3.4 rules 1, 4 and 5: KYC daily limit,
--    same currency, both accounts ACTIVE. Also checks funds/overdraft.
--  * Inserts the transaction and updates both balances inside an inner
--    BEGIN ... EXCEPTION block, which PL/pgSQL runs as a SAVEPOINT. If any
--    rule fails, everything since the savepoint is undone and a FAILED
--    transaction is recorded instead. No money moves.
--  * Idempotent: calling it again with the same reference returns the
--    original outcome instead of posting twice.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION transfer_funds(
    p_from      CHAR(10),
    p_to        CHAR(10),
    p_amount    NUMERIC(18,2),
    p_channel   VARCHAR(10)  DEFAULT 'MOBILE',
    p_narration VARCHAR(140) DEFAULT 'Transfer',
    p_reference VARCHAR(20)  DEFAULT NULL)
RETURNS TABLE (txn_reference VARCHAR, txn_status VARCHAR, message TEXT)
LANGUAGE plpgsql AS $$
DECLARE
    v_ref         VARCHAR(20) := COALESCE(p_reference, 'TRF' || lpad(nextval('txn_ref_seq')::text, 12, '0'));
    v_from        account%ROWTYPE;
    v_to          account%ROWTYPE;
    v_from_ccy    CHAR(3);
    v_to_ccy      CHAR(3);
    v_customer    INT;
    v_daily_limit NUMERIC(18,2);
    v_spent_today NUMERIC(18,2);
BEGIN
    -- idempotency: has this request already been processed?
    RETURN QUERY
        SELECT t.reference, t.status, 'Duplicate request - original outcome returned, nothing posted'::text
        FROM bank_transaction t WHERE t.reference = v_ref;
    IF FOUND THEN RETURN; END IF;

    IF p_from = p_to THEN
        RETURN QUERY SELECT v_ref, 'REJECTED'::varchar, 'Cannot transfer to the same account'::text;
        RETURN;
    END IF;

    BEGIN   -- inner block = SAVEPOINT
        -- (1) lock both accounts, always in account_id order
        PERFORM 1 FROM account a
        WHERE a.account_number IN (p_from, p_to)
        ORDER BY a.account_id
        FOR NO KEY UPDATE;

        SELECT * INTO v_from FROM account a WHERE a.account_number = p_from;
        SELECT * INTO v_to   FROM account a WHERE a.account_number = p_to;
        IF v_from.account_id IS NULL OR v_to.account_id IS NULL THEN
            RETURN QUERY SELECT v_ref, 'REJECTED'::varchar, 'Unknown account number'::text;
            RETURN;
        END IF;

        -- (2) account status and currency
        IF v_from.status <> 'ACTIVE' THEN
            RAISE EXCEPTION 'Debit account % is %', p_from, v_from.status;
        END IF;
        IF v_to.status <> 'ACTIVE' THEN
            RAISE EXCEPTION 'Credit account % is %', p_to, v_to.status;
        END IF;
        SELECT currency INTO v_from_ccy FROM account_type WHERE type_code = v_from.type_code;
        SELECT currency INTO v_to_ccy   FROM account_type WHERE type_code = v_to.type_code;
        IF v_from_ccy <> v_to_ccy THEN
            RAISE EXCEPTION 'Currency mismatch: % to %', v_from_ccy, v_to_ccy;
        END IF;

        -- (3) KYC daily limit, with the customer row locked (see header)
        SELECT c.customer_id, k.daily_debit_limit INTO v_customer, v_daily_limit
        FROM account_holder ah
        JOIN customer c ON c.customer_id = ah.customer_id
        JOIN kyc_tier k ON k.tier_level  = c.kyc_tier
        WHERE ah.account_id = v_from.account_id AND ah.holder_role = 'PRIMARY'
        FOR NO KEY UPDATE OF c;

        SELECT COALESCE(SUM(t.amount), 0) INTO v_spent_today
        FROM bank_transaction t
        JOIN account_holder ah ON ah.account_id = t.debit_account_id AND ah.holder_role = 'PRIMARY'
        WHERE ah.customer_id = v_customer
          AND t.status IN ('COMPLETED', 'PENDING')
          AND t.created_at >= date_trunc('day', now());

        IF v_spent_today + p_amount > v_daily_limit THEN
            RAISE EXCEPTION 'Daily limit exceeded: limit %, already spent today %', v_daily_limit, v_spent_today;
        END IF;

        -- (4) funds, including any approved overdraft
        IF v_from.balance - p_amount < -v_from.overdraft_limit THEN
            RAISE EXCEPTION 'Insufficient funds: available %', v_from.balance + v_from.overdraft_limit;
        END IF;

        -- (5) post: the record and both balances succeed or fail together
        INSERT INTO bank_transaction (reference, txn_type, channel, debit_account_id, credit_account_id,
                                      amount, status, narration, created_at, completed_at)
        VALUES (v_ref, 'TRANSFER', p_channel, v_from.account_id, v_to.account_id,
                p_amount, 'COMPLETED', p_narration, now(), clock_timestamp());

        UPDATE account SET balance = balance - p_amount WHERE account_id = v_from.account_id;
        UPDATE account SET balance = balance + p_amount WHERE account_id = v_to.account_id;

        RETURN QUERY SELECT v_ref, 'COMPLETED'::varchar,
                            format('%s moved from %s to %s', p_amount, p_from, p_to);

    EXCEPTION
        WHEN unique_violation THEN
            -- a concurrent call with the same reference won the race
            RETURN QUERY SELECT v_ref, 'DUPLICATE'::varchar, 'Duplicate request - already being processed'::text;
        WHEN raise_exception OR check_violation THEN
            -- the savepoint has undone the locks' work, the INSERT and both UPDATEs;
            -- record the failed attempt so the customer and auditors can see it
            INSERT INTO bank_transaction (reference, txn_type, channel, debit_account_id, credit_account_id,
                                          amount, status, narration, failure_reason, created_at)
            VALUES (v_ref, 'TRANSFER', p_channel, v_from.account_id, v_to.account_id,
                    p_amount, 'FAILED', p_narration, SQLERRM, now());
            RETURN QUERY SELECT v_ref, 'FAILED'::varchar, SQLERRM;
    END;
END $$;


-- ---------------------------------------------------------------------
-- 4. transfer_funds_naive(): DO NOT USE - demonstration only.
--    Reads the balances WITHOUT locking, computes the new balances in
--    "application code", then writes them back as absolute values. If
--    another transfer changes the same account in between, that change is
--    overwritten: a LOST UPDATE. It also updates the accounts in
--    debit-then-credit order, which allows deadlocks.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION transfer_funds_naive(p_from CHAR(10), p_to CHAR(10), p_amount NUMERIC(18,2))
RETURNS VARCHAR
LANGUAGE plpgsql AS $$
DECLARE
    v_ref      VARCHAR(20) := 'NAV' || lpad(nextval('txn_ref_seq')::text, 12, '0');
    v_from_id  INT;  v_from_bal NUMERIC(18,2);
    v_to_id    INT;  v_to_bal   NUMERIC(18,2);
BEGIN
    SELECT account_id, balance INTO v_from_id, v_from_bal FROM account WHERE account_number = p_from;  -- no lock
    SELECT account_id, balance INTO v_to_id,   v_to_bal   FROM account WHERE account_number = p_to;    -- no lock
    IF v_from_bal < p_amount THEN
        RETURN 'FAILED';
    END IF;

    INSERT INTO bank_transaction (reference, txn_type, channel, debit_account_id, credit_account_id,
                                  amount, status, narration, created_at, completed_at)
    VALUES (v_ref, 'TRANSFER', 'MOBILE', v_from_id, v_to_id, p_amount, 'COMPLETED', 'Naive transfer',
            now(), clock_timestamp());

    UPDATE account SET balance = v_from_bal - p_amount WHERE account_id = v_from_id;  -- stale value written
    UPDATE account SET balance = v_to_bal   + p_amount WHERE account_id = v_to_id;    -- stale value written
    RETURN 'COMPLETED';
END $$;

\echo 'Portfolio 3 objects created.'
