-- =====================================================================
-- OwoTrust Digital Bank (simulated) - Portfolio 2
-- 03_indexes.sql : targeted indexes for the workload in 02_workload.sql
--
-- Before this script the only indexes are the ones PostgreSQL creates
-- automatically for PRIMARY KEY and UNIQUE constraints (Portfolio 1).
-- Each index below is justified by the query (Qn) it serves.
-- =====================================================================

\timing on

-- I1, I2: composite B-tree indexes on each side of a transaction.
--   * Leading column = the account, so "all transactions of account X"
--     becomes an index range scan instead of reading 1M rows.
--   * Second column = created_at, so rows come out already in time order:
--     Q1b can read just the newest 20 entries, and Q2/Q8 can apply their
--     date filters inside the index.
--   * They also index the two foreign keys to account. Without them,
--     closing or deleting an account would force a full scan of
--     bank_transaction to check the FK.
--   Serves: Q1, Q1b, Q2, Q6 (join), Q8
CREATE INDEX ix_txn_debit_acct_created  ON bank_transaction (debit_account_id,  created_at);
CREATE INDEX ix_txn_credit_acct_created ON bank_transaction (credit_account_id, created_at);

-- I3: expression index on lower(email). The UNIQUE index on email from
--   Portfolio 1 cannot be used for WHERE lower(email) = ..., because the
--   index stores the original text, not lower(text). Making it UNIQUE also
--   closes a design gap: 'Ada@x.com' and 'ada@x.com' can no longer both exist.
--   Serves: Q3
CREATE UNIQUE INDEX ux_customer_email_lower ON customer (lower(email));

-- I4: foreign-key index. account_holder's primary key is
--   (account_id, customer_id), which helps look-ups BY ACCOUNT but not BY
--   CUSTOMER, because customer_id is the second column.
--   Serves: Q4
CREATE INDEX ix_account_holder_customer ON account_holder (customer_id);

-- I5: PARTIAL index. Only about 0.02% of rows are PENDING, so the index
--   holds just those rows (a few kB) instead of all 1M (tens of MB).
--   Rows leave the index automatically when their status changes.
--   Serves: Q5
CREATE INDEX ix_txn_pending_created ON bank_transaction (created_at) WHERE status = 'PENDING';

-- I6: BRIN (Block Range INdex) on created_at. Transactions are inserted in
--   time order, so each block range of the table covers a narrow time
--   window. BRIN stores only the min/max created_at per range of 128 pages,
--   which makes it tiny compared with a B-tree. It lets date-range queries
--   skip whole sections of the table.
--   Serves: Q6, Q7 (see 05_index_tradeoffs.sql for the B-tree vs BRIN comparison)
CREATE INDEX brin_txn_created_at ON bank_transaction USING brin (created_at);

-- S1: EXTENDED STATISTICS (not an index). By default the planner cannot
--   estimate how many distinct values an expression such as
--   date_trunc('month', ...) produces, so it guessed ~520,000 groups for
--   Q7 when there are only 70. That made it reject an in-memory hash
--   aggregate. Expression statistics tell it the real number of months.
--   The expression must be IMMUTABLE, hence AT TIME ZONE instead of relying
--   on the session time zone.
--   Serves: Q7b
CREATE STATISTICS st_txn_month_channel
    ON (date_trunc('month', created_at AT TIME ZONE 'Africa/Lagos')), channel
    FROM bank_transaction;

-- refresh optimiser statistics so the planner knows about the new indexes
-- (ANALYZE also computes the extended statistics defined above)
ANALYZE bank_transaction;
ANALYZE customer;
ANALYZE account_holder;

\timing off
SELECT indexrelid::regclass AS index_name,
       indrelid::regclass   AS table_name,
       pg_size_pretty(pg_relation_size(indexrelid)) AS index_size
FROM pg_index
WHERE indexrelid::regclass::text IN ('ix_txn_debit_acct_created','ix_txn_credit_acct_created',
                                     'ux_customer_email_lower','ix_account_holder_customer',
                                     'ix_txn_pending_created','brin_txn_created_at')
ORDER BY pg_relation_size(indexrelid) DESC;
