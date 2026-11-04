-- =====================================================================
-- OwoTrust Digital Bank (simulated) - Portfolio 4
-- 03_export_statements.sql : transactions -> monthly statement documents
--                            (MongoDB "bucket pattern")
--
-- One document per account per month, for August-October 2026. The
-- month's transactions are embedded as an array, with the running balance
-- after each one, plus opening/closing balances and totals. A statement is
-- then ONE document read, instead of the join + window function of
-- Portfolio 2's Q2. The bucket (one month) caps the array size, so
-- documents never grow without limit. That is the purpose of the pattern.
--
--   psql -At -v FETCH_COUNT=5000 -f 03_export_statements.sql > data/statements.ndjson
-- =====================================================================

SET timezone = 'UTC';

WITH legs AS (          -- every posted transaction, seen from each account it touched
    SELECT debit_account_id AS account_id, txn_id, reference, created_at, txn_type, channel, narration,
           'DR' AS dr_cr, amount, -amount AS delta
    FROM bank_transaction WHERE status IN ('COMPLETED','REVERSED') AND debit_account_id IS NOT NULL
    UNION ALL
    SELECT credit_account_id, txn_id, reference, created_at, txn_type, channel, narration,
           'CR', amount, amount
    FROM bank_transaction WHERE status IN ('COMPLETED','REVERSED') AND credit_account_id IS NOT NULL
), running AS (         -- running balance over the account's WHOLE history
    SELECT legs.*,
           SUM(delta) OVER (PARTITION BY account_id ORDER BY created_at, txn_id) AS balance_after,
           to_char(created_at AT TIME ZONE 'Africa/Lagos', 'YYYY-MM') AS month   -- bank months are Lagos time
    FROM legs
)
SELECT json_build_object(
           '_id',            a.account_number || ':' || r.month,
           'accountNumber',  a.account_number,
           'month',          r.month,
           'currency',       at.currency,
           'openingBalance', json_build_object('$numberDecimal',
                                 ((array_agg(r.balance_after - r.delta ORDER BY r.created_at, r.txn_id))[1])::text),
           'closingBalance', json_build_object('$numberDecimal',
                                 ((array_agg(r.balance_after ORDER BY r.created_at DESC, r.txn_id DESC))[1])::text),
           'totals', json_build_object(
               'credits', json_build_object('$numberDecimal', COALESCE(SUM(r.amount) FILTER (WHERE r.dr_cr = 'CR'), 0)::text),
               'debits',  json_build_object('$numberDecimal', COALESCE(SUM(r.amount) FILTER (WHERE r.dr_cr = 'DR'), 0)::text),
               'count',   COUNT(*)),
           'transactions', json_agg(json_build_object(
               'ref',          r.reference,
               'at',           json_build_object('$date', to_char(r.created_at, 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"')),
               'type',         r.txn_type,
               'channel',      r.channel,
               'drCr',         r.dr_cr,
               'amount',       json_build_object('$numberDecimal', r.amount::text),
               'narration',    r.narration,
               'balanceAfter', json_build_object('$numberDecimal', r.balance_after::text))
               ORDER BY r.created_at, r.txn_id))
FROM running r
JOIN account a       ON a.account_id = r.account_id
JOIN account_type at ON at.type_code = a.type_code
WHERE r.month BETWEEN '2026-08' AND '2026-10'
GROUP BY a.account_number, r.month, at.currency
ORDER BY a.account_number, r.month;
