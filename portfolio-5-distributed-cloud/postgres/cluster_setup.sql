-- =====================================================================
-- OwoTrust Digital Bank (simulated) - Portfolio 5
-- postgres/cluster_setup.sql : helpers for the replication experiments
-- Run on the PRIMARY after Portfolio 1's schema + seed. Everything created
-- here is replicated to both standbys automatically: DDL is in the WAL too.
-- =====================================================================

CREATE SEQUENCE IF NOT EXISTS dist_ref_seq;

-- post a deposit: the transaction row and the balance change commit together
CREATE OR REPLACE FUNCTION post_deposit(p_account CHAR(10), p_amount NUMERIC(18,2), p_reference VARCHAR(20) DEFAULT NULL)
RETURNS VARCHAR LANGUAGE plpgsql AS $$
DECLARE v_ref VARCHAR(20) := COALESCE(p_reference, 'DST' || lpad(nextval('dist_ref_seq')::text, 12, '0'));
BEGIN
    INSERT INTO bank_transaction (reference, txn_type, channel, credit_account_id, amount, status, narration, completed_at)
    SELECT v_ref, 'DEPOSIT', 'MOBILE', account_id, p_amount, 'COMPLETED', 'Card funding', clock_timestamp()
    FROM account WHERE account_number = p_account;
    UPDATE account SET balance = balance + p_amount WHERE account_number = p_account;
    RETURN v_ref;
END $$;

-- run ON A REPLICA: wait until a transaction committed on the primary becomes
-- visible here, and report how long after the primary wrote it that happened
CREATE OR REPLACE FUNCTION wait_until_visible(p_reference VARCHAR(20), p_timeout_ms INT DEFAULT 5000)
RETURNS TEXT LANGUAGE plpgsql AS $$
DECLARE
    t0 TIMESTAMPTZ := clock_timestamp();
    v_written TIMESTAMPTZ;
BEGIN
    LOOP
        SELECT completed_at INTO v_written FROM bank_transaction WHERE reference = p_reference;
        IF FOUND THEN
            RETURN format('visible %s ms after the primary wrote it',
                          round((EXTRACT(EPOCH FROM clock_timestamp() - v_written) * 1000)::numeric, 2));
        END IF;
        IF clock_timestamp() - t0 > p_timeout_ms * INTERVAL '1 millisecond' THEN
            RETURN format('NOT visible after %s ms', p_timeout_ms);
        END IF;
        PERFORM pg_sleep(0.0005);
    END LOOP;
END $$;

SELECT 'primary ready: ' || COUNT(*) || ' accounts, ' || (SELECT COUNT(*) FROM bank_transaction) || ' transactions'
FROM account;
