-- Graph export: completed ATM/POS withdrawals in October 2026 (the CASHED_OUT relationship)
COPY (SELECT t.reference, d.account_number AS account, t.amount, t.channel,
             to_char(t.created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') AS at
      FROM bank_transaction t JOIN account d ON d.account_id = t.debit_account_id
      WHERE t.txn_type = 'WITHDRAWAL' AND t.status = 'COMPLETED' AND t.channel IN ('ATM', 'POS')
        AND t.created_at >= TIMESTAMPTZ '2026-10-01 00:00+01' AND t.created_at < TIMESTAMPTZ '2026-11-01 00:00+01'
      ORDER BY t.created_at) TO STDOUT WITH (FORMAT csv, HEADER);
