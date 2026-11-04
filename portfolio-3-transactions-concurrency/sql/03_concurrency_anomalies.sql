-- =====================================================================
-- OwoTrust Digital Bank (simulated) - Portfolio 3
-- 03_concurrency_anomalies.sql : two concurrent sessions, step by step
--
-- HOW THIS WORKS
--   dblink opens two independent database connections, "session_A" and
--   "session_B". They are real, separate PostgreSQL backends, exactly like
--   two bank tellers or two app servers. This script acts as the conductor
--   and decides the exact order of every step, so each anomaly is
--   reproduced deterministically on every run.
--
--   Output format, one line per step:   [A] <SQL sent to session A>  =>  <result>
--   demo_async() sends a statement that is expected to BLOCK. demo_waits()
--   then shows, from pg_stat_activity, which session waits for which lock.
--
--   S1  MVCC: no dirty reads, and readers do not block writers
--   S2  Non-repeatable read and phantom: READ COMMITTED vs REPEATABLE READ
--   S3  Lost update, and three ways to prevent it
--   S4  Write skew: REPEATABLE READ vs SERIALIZABLE
--   S5  Deadlock, and how transfer_funds() avoids it
-- =====================================================================

SET timezone = 'Africa/Lagos';
\set VERBOSITY terse
\pset footer off
CREATE EXTENSION IF NOT EXISTS dblink;

-- ---------------------------------------------------------------------
-- Conductor helpers
-- ---------------------------------------------------------------------
-- run one statement in session s and report what came back
CREATE OR REPLACE FUNCTION demo_step(s text, cmd text) RETURNS text
LANGUAGE plpgsql AS $$
DECLARE res text;
BEGIN
    IF cmd ~* '^\s*(select|with)\M' THEN
        SELECT string_agg(v, ', ') INTO res FROM dblink(s, cmd) AS t(v text);
        res := 'returns ' || COALESCE(res, '(no rows)');
    ELSE
        res := dblink_exec(s, cmd);
    END IF;
    RETURN format('[%s] %s  =>  %s', s, regexp_replace(cmd, '\s+', ' ', 'g'), res);
EXCEPTION WHEN OTHERS THEN
    RETURN format('[%s] %s  =>  ERROR: %s', s, regexp_replace(cmd, '\s+', ' ', 'g'), SQLERRM);
END $$;

-- send a statement without waiting for it to finish (it may block on a lock)
CREATE OR REPLACE FUNCTION demo_async(s text, cmd text) RETURNS text
LANGUAGE plpgsql AS $$
BEGIN
    PERFORM dblink_send_query(s, cmd);
    PERFORM pg_sleep(0.5);
    RETURN format('[%s] %s  =>  %s', s, regexp_replace(cmd, '\s+', ' ', 'g'),
                  CASE dblink_is_busy(s) WHEN 1 THEN '... BLOCKED (still waiting after 0.5 s)'
                                         ELSE '... completed within 0.5 s' END);
END $$;

-- collect the result of a statement previously sent with demo_async
CREATE OR REPLACE FUNCTION demo_result(s text) RETURNS text
LANGUAGE plpgsql AS $$
DECLARE res text;
BEGIN
    BEGIN
        SELECT string_agg(v, ', ') INTO res FROM dblink_get_result(s) AS t(v text);
    EXCEPTION WHEN OTHERS THEN
        res := 'ERROR: ' || SQLERRM;
    END;
    BEGIN   -- drain: dblink needs one more call that returns no rows
        PERFORM * FROM dblink_get_result(s) AS t(v text);
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
    RETURN format('[%s] (blocked statement has now finished)  =>  %s', s, res);
END $$;

-- who is waiting for whom (from the server's point of view)
CREATE OR REPLACE FUNCTION demo_waits() RETURNS SETOF text
LANGUAGE sql AS $$
    SELECT format('      lock monitor: %s is waiting (%s / %s), blocked by %s',
                  a.application_name, a.wait_event_type, a.wait_event,
                  (SELECT string_agg(b.application_name, ', ')
                   FROM pg_stat_activity b WHERE b.pid = ANY (pg_blocking_pids(a.pid))))
    FROM pg_stat_activity a
    WHERE a.application_name IN ('session_A', 'session_B') AND a.wait_event_type = 'Lock';
$$;

-- after each scenario: put every balance back to the value its transaction history implies
CREATE OR REPLACE FUNCTION demo_reset_balances() RETURNS void
LANGUAGE sql AS $$
    UPDATE account a SET balance = COALESCE(d.derived, 0)
    FROM account a2
    LEFT JOIN (SELECT account_id, SUM(delta) AS derived
               FROM (SELECT credit_account_id AS account_id,  amount AS delta FROM bank_transaction
                     WHERE status IN ('COMPLETED','REVERSED') AND credit_account_id IS NOT NULL
                     UNION ALL
                     SELECT debit_account_id,  -amount FROM bank_transaction
                     WHERE status IN ('COMPLETED','REVERSED') AND debit_account_id IS NOT NULL) legs
               GROUP BY account_id) d ON d.account_id = a2.account_id
    WHERE a.account_id = a2.account_id AND a.balance <> COALESCE(d.derived, 0);
$$;

SELECT dblink_disconnect(c) FROM unnest(dblink_get_connections()) AS c;
SELECT dblink_connect('A', 'dbname=owotrust_bank user=owotrust application_name=session_A');
SELECT dblink_connect('B', 'dbname=owotrust_bank user=owotrust application_name=session_B');

\pset tuples_only on


\echo
\echo '===================================================================='
\echo 'S1. MVCC: NO DIRTY READS, AND READERS DO NOT BLOCK WRITERS'
\echo '===================================================================='
\echo 'A teller (A) starts crediting N1,000,000 but has not committed. An app'
\echo 'session (B) asks for READ UNCOMMITTED, the weakest level in the SQL standard.'
SELECT demo_step('A', 'BEGIN');
SELECT demo_step('A', $$SELECT 'A transaction id = ' || txid_current()$$);
SELECT demo_step('A', $$UPDATE account SET balance = balance + 1000000 WHERE account_number = '3010000001'$$);
SELECT demo_step('A', $$SELECT balance FROM account WHERE account_number = '3010000001'$$);
SELECT demo_step('B', 'BEGIN ISOLATION LEVEL READ UNCOMMITTED');
SELECT demo_step('B', $$SELECT balance || '  (row version: xmin=' || xmin || ', xmax=' || xmax || ')' FROM account WHERE account_number = '3010000001'$$);
\echo '  -> B sees the OLD committed balance immediately, without waiting. PostgreSQL'
\echo '     treats READ UNCOMMITTED as READ COMMITTED, so dirty reads are impossible.'
\echo '     xmax = A''s transaction id: B is reading the old row VERSION that A is replacing (MVCC).'
SELECT demo_step('A', 'ROLLBACK');
SELECT demo_step('B', 'COMMIT');


\echo
\echo '===================================================================='
\echo 'S2. NON-REPEATABLE READ and PHANTOM: READ COMMITTED vs REPEATABLE READ'
\echo '===================================================================='
\echo 'An auditor (B) reads the total NGN deposits and the number of posted'
\echo 'transactions twice in one transaction. In between, a deposit (A) commits.'
\echo
\echo 'S2a. Auditor at READ COMMITTED (the PostgreSQL default):'
SELECT demo_step('B', 'BEGIN ISOLATION LEVEL READ COMMITTED');
SELECT demo_step('B', $$SELECT SUM(balance) FROM account WHERE type_code <> 'DOM_USD'$$);
SELECT demo_step('B', $$SELECT COUNT(*) FROM bank_transaction WHERE status = 'COMPLETED'$$);
SELECT demo_step('A', $$BEGIN;
    INSERT INTO bank_transaction (reference, txn_type, channel, credit_account_id, amount, status, narration, initiated_by, completed_at)
    SELECT 'DEP-S2A', 'DEPOSIT', 'BRANCH', account_id, 100000, 'COMPLETED', 'Cash deposit',
           (SELECT employee_id FROM employee WHERE staff_number = 'OT00002'), clock_timestamp()
    FROM account WHERE account_number = '3010000019';
    UPDATE account SET balance = balance + 100000 WHERE account_number = '3010000019';
    COMMIT$$);
SELECT demo_step('B', $$SELECT SUM(balance) FROM account WHERE type_code <> 'DOM_USD'$$);
SELECT demo_step('B', $$SELECT COUNT(*) FROM bank_transaction WHERE status = 'COMPLETED'$$);
SELECT demo_step('B', 'COMMIT');
\echo '  -> Within ONE transaction the total changed by 100,000 (NON-REPEATABLE READ)'
\echo '     and a new row appeared (PHANTOM). Each statement sees the latest committed data.'
\echo
\echo 'S2b. Auditor at REPEATABLE READ:'
SELECT demo_step('B', 'BEGIN ISOLATION LEVEL REPEATABLE READ');
SELECT demo_step('B', $$SELECT SUM(balance) FROM account WHERE type_code <> 'DOM_USD'$$);
SELECT demo_step('B', $$SELECT COUNT(*) FROM bank_transaction WHERE status = 'COMPLETED'$$);
SELECT demo_step('A', $$BEGIN;
    INSERT INTO bank_transaction (reference, txn_type, channel, credit_account_id, amount, status, narration, initiated_by, completed_at)
    SELECT 'DEP-S2B', 'DEPOSIT', 'BRANCH', account_id, 100000, 'COMPLETED', 'Cash deposit',
           (SELECT employee_id FROM employee WHERE staff_number = 'OT00002'), clock_timestamp()
    FROM account WHERE account_number = '3010000019';
    UPDATE account SET balance = balance + 100000 WHERE account_number = '3010000019';
    COMMIT$$);
SELECT demo_step('B', $$SELECT SUM(balance) FROM account WHERE type_code <> 'DOM_USD'$$);
SELECT demo_step('B', $$SELECT COUNT(*) FROM bank_transaction WHERE status = 'COMPLETED'$$);
SELECT demo_step('B', 'COMMIT');
SELECT demo_step('B', $$SELECT SUM(balance) FROM account WHERE type_code <> 'DOM_USD'$$);
\echo '  -> B works on ONE snapshot taken at its first query: both reads agree, so the'
\echo '     audit report is internally consistent. The deposit is visible only after B commits.'


\echo
\echo '===================================================================='
\echo 'S3. LOST UPDATE: two ATM withdrawals from the same account at once'
\echo '===================================================================='
\echo 'Account 3010000003 starts at N450,000. A withdraws N100,000 and B withdraws'
\echo 'N50,000, so the correct final balance is N300,000. Each session reads the'
\echo 'balance, computes the new value in "application code", and writes it back.'
\echo
\echo 'S3a. The anomaly (READ COMMITTED, plain read-modify-write):'
SELECT demo_step('A', 'BEGIN');
SELECT demo_step('A', $$SELECT balance FROM account WHERE account_number = '3010000003'$$);
SELECT demo_step('B', 'BEGIN');
SELECT demo_step('B', $$SELECT balance FROM account WHERE account_number = '3010000003'$$);
SELECT demo_step('A', $$UPDATE account SET balance = 350000 WHERE account_number = '3010000003'$$);
SELECT demo_step('A', 'COMMIT');
SELECT demo_step('B', $$UPDATE account SET balance = 400000 WHERE account_number = '3010000003'$$);
SELECT demo_step('B', 'COMMIT');
SELECT demo_step('A', $$SELECT 'final balance = ' || balance FROM account WHERE account_number = '3010000003'$$);
\echo '  -> 400,000 instead of 300,000: A''s N100,000 withdrawal was LOST (overwritten by B).'
SELECT demo_reset_balances();

\echo
\echo 'S3b. Fix 1: let the database do the arithmetic (atomic UPDATE ... balance - x)'
SELECT demo_step('A', 'BEGIN');
SELECT demo_step('A', $$UPDATE account SET balance = balance - 100000 WHERE account_number = '3010000003'$$);
SELECT demo_step('B', 'BEGIN');
SELECT demo_async('B', $$UPDATE account SET balance = balance - 50000 WHERE account_number = '3010000003'$$);
SELECT demo_waits();
SELECT demo_step('A', 'COMMIT');
SELECT demo_result('B');
SELECT demo_step('B', 'COMMIT');
SELECT demo_step('A', $$SELECT 'final balance = ' || balance FROM account WHERE account_number = '3010000003'$$);
\echo '  -> B waited for A''s row lock, then re-read the committed row (350,000) and'
\echo '     subtracted from that: 300,000. Correct.'
SELECT demo_reset_balances();

\echo
\echo 'S3c. Fix 2: pessimistic locking with SELECT ... FOR UPDATE'
SELECT demo_step('A', 'BEGIN');
SELECT demo_step('A', $$SELECT balance FROM account WHERE account_number = '3010000003' FOR UPDATE$$);
SELECT demo_step('B', 'BEGIN');
SELECT demo_async('B', $$SELECT balance FROM account WHERE account_number = '3010000003' FOR UPDATE$$);
SELECT demo_waits();
SELECT demo_step('A', $$UPDATE account SET balance = 350000 WHERE account_number = '3010000003'$$);
SELECT demo_step('A', 'COMMIT');
SELECT demo_result('B');
SELECT demo_step('B', $$UPDATE account SET balance = 300000 WHERE account_number = '3010000003'$$);
SELECT demo_step('B', 'COMMIT');
SELECT demo_step('A', $$SELECT 'final balance = ' || balance FROM account WHERE account_number = '3010000003'$$);
\echo '  -> B''s read waited until A finished, so B computed from 350,000: 300,000. Correct.'
\echo '     transfer_funds() uses this approach.'
SELECT demo_reset_balances();

\echo
\echo 'S3d. Fix 3: optimistic, REPEATABLE READ detects the conflict and the app retries'
SELECT demo_step('A', 'BEGIN ISOLATION LEVEL REPEATABLE READ');
SELECT demo_step('A', $$SELECT balance FROM account WHERE account_number = '3010000003'$$);
SELECT demo_step('B', 'BEGIN ISOLATION LEVEL REPEATABLE READ');
SELECT demo_step('B', $$SELECT balance FROM account WHERE account_number = '3010000003'$$);
SELECT demo_step('A', $$UPDATE account SET balance = 350000 WHERE account_number = '3010000003'$$);
SELECT demo_step('A', 'COMMIT');
SELECT demo_step('B', $$UPDATE account SET balance = 400000 WHERE account_number = '3010000003'$$);
SELECT demo_step('B', 'ROLLBACK');
\echo '  -> B is refused ("could not serialize access due to concurrent update")'
\echo '     instead of silently overwriting A. The application retries B from the start:'
SELECT demo_step('B', 'BEGIN ISOLATION LEVEL REPEATABLE READ');
SELECT demo_step('B', $$SELECT balance FROM account WHERE account_number = '3010000003'$$);
SELECT demo_step('B', $$UPDATE account SET balance = 300000 WHERE account_number = '3010000003'$$);
SELECT demo_step('B', 'COMMIT');
SELECT demo_step('A', $$SELECT 'final balance = ' || balance FROM account WHERE account_number = '3010000003'$$);
SELECT demo_reset_balances();


\echo
\echo '===================================================================='
\echo 'S4. WRITE SKEW: REPEATABLE READ is not enough, SERIALIZABLE is'
\echo '===================================================================='
\echo 'Rule: Adaeze''s savings (3010000001) + current (3010000002) together must'
\echo 'never go below zero. Together they hold 699,900. At the same moment she'
\echo 'withdraws 340,000 from current (A) and 400,000 from savings (B). Each session'
\echo 'checks the combined balance, sees enough money, and updates a DIFFERENT row.'
\echo
\echo 'S4a. REPEATABLE READ:'
SELECT demo_step('A', 'BEGIN ISOLATION LEVEL REPEATABLE READ');
SELECT demo_step('A', $$SELECT SUM(balance) FROM account WHERE account_number IN ('3010000001','3010000002')$$);
SELECT demo_step('B', 'BEGIN ISOLATION LEVEL REPEATABLE READ');
SELECT demo_step('B', $$SELECT SUM(balance) FROM account WHERE account_number IN ('3010000001','3010000002')$$);
SELECT demo_step('A', $$UPDATE account SET balance = balance - 340000 WHERE account_number = '3010000002'$$);
SELECT demo_step('B', $$UPDATE account SET balance = balance - 400000 WHERE account_number = '3010000001'$$);
SELECT demo_step('A', 'COMMIT');
SELECT demo_step('B', 'COMMIT');
SELECT demo_step('A', $$SELECT 'combined balance now = ' || SUM(balance) FROM account WHERE account_number IN ('3010000001','3010000002')$$);
\echo '  -> Both committed and the combined balance is NEGATIVE: the rule is broken.'
\echo '     No row was written by both sessions, so snapshot isolation saw no conflict.'
SELECT demo_reset_balances();

\echo
\echo 'S4b. SERIALIZABLE (Serializable Snapshot Isolation):'
SELECT demo_step('A', 'BEGIN ISOLATION LEVEL SERIALIZABLE');
SELECT demo_step('A', $$SELECT SUM(balance) FROM account WHERE account_number IN ('3010000001','3010000002')$$);
SELECT demo_step('B', 'BEGIN ISOLATION LEVEL SERIALIZABLE');
SELECT demo_step('B', $$SELECT SUM(balance) FROM account WHERE account_number IN ('3010000001','3010000002')$$);
SELECT demo_step('A', $$UPDATE account SET balance = balance - 340000 WHERE account_number = '3010000002'$$);
SELECT demo_step('B', $$UPDATE account SET balance = balance - 400000 WHERE account_number = '3010000001'$$);
SELECT demo_step('A', 'COMMIT');
SELECT demo_step('B', 'COMMIT');
SELECT demo_step('A', $$SELECT 'combined balance now = ' || SUM(balance) FROM account WHERE account_number IN ('3010000001','3010000002')$$);
\echo '  -> PostgreSQL tracked what each transaction READ, detected the dangerous'
\echo '     read/write dependency cycle, and aborted B. Retrying B would re-read 359,900'
\echo '     and correctly refuse the N400,000 withdrawal.'
SELECT demo_step('B', 'ROLLBACK');
SELECT demo_reset_balances();


\echo
\echo '===================================================================='
\echo 'S5. DEADLOCK: two transfers in opposite directions'
\echo '===================================================================='
\echo 'S5a. Naive order (debit account first, then credit account):'
\echo '     A transfers 1 -> 3, B transfers 3 -> 1, at the same time.'
SELECT demo_step('A', 'BEGIN');
SELECT demo_step('A', $$UPDATE account SET balance = balance - 10000 WHERE account_number = '3010000001'$$);
SELECT demo_step('B', 'BEGIN');
SELECT demo_step('B', $$UPDATE account SET balance = balance - 20000 WHERE account_number = '3010000003'$$);
SELECT demo_async('A', $$UPDATE account SET balance = balance + 10000 WHERE account_number = '3010000003'$$);
SELECT demo_waits();
SELECT demo_async('B', $$UPDATE account SET balance = balance + 20000 WHERE account_number = '3010000001'$$);
\echo '  (A held 3010000001 and wanted 3010000003; B held 3010000003 and wanted 3010000001:'
\echo '   a cycle in which neither can proceed. A had been waiting longer, so A''s'
\echo '   deadlock_timeout (1 s) expired first: PostgreSQL found the cycle, aborted A as'
\echo '   the victim and released its lock, which is why B''s statement completed.)'
SELECT '   (conductor waits 1.5 s)' FROM pg_sleep(1.5);
SELECT demo_result('A');
SELECT demo_result('B');
SELECT demo_step('A', 'COMMIT');
SELECT demo_step('B', 'COMMIT');
\echo '  -> One transaction was chosen as the victim and rolled back; the other completed.'
SELECT demo_reset_balances();

\echo
\echo 'S5b. transfer_funds() locks accounts in account_id order, whichever direction:'
SELECT demo_step('A', 'BEGIN');
SELECT demo_step('A', $$SELECT txn_status || ': ' || message FROM transfer_funds('3010000001', '3010000003', 10000)$$);
SELECT demo_step('B', 'BEGIN');
SELECT demo_async('B', $$SELECT txn_status || ': ' || message FROM transfer_funds('3010000003', '3010000001', 20000)$$);
SELECT demo_waits();
SELECT demo_step('A', 'COMMIT');
SELECT demo_result('B');
SELECT demo_step('B', 'COMMIT');
\echo '  -> B queued behind A for the FIRST lock (account 1) instead of grabbing account 3,'
\echo '     so no cycle could form. Both transfers completed, with no deadlock and no retry.'


\pset tuples_only off
\echo
\echo '===================================================================='
\echo 'AFTER ALL SCENARIOS'
\echo '===================================================================='
SELECT dblink_disconnect('A'), dblink_disconnect('B');
SELECT deadlocks AS deadlocks_detected_in_this_database FROM pg_stat_database WHERE datname = current_database();
SELECT COUNT(*) AS accounts_where_balance_does_not_match_history
FROM account a
LEFT JOIN (SELECT account_id, SUM(delta) AS derived
           FROM (SELECT credit_account_id AS account_id,  amount AS delta FROM bank_transaction
                 WHERE status IN ('COMPLETED','REVERSED') AND credit_account_id IS NOT NULL
                 UNION ALL
                 SELECT debit_account_id,  -amount FROM bank_transaction
                 WHERE status IN ('COMPLETED','REVERSED') AND debit_account_id IS NOT NULL) legs
           GROUP BY account_id) d ON d.account_id = a.account_id
WHERE a.balance <> COALESCE(d.derived, 0);
