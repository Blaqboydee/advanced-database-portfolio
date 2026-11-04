-- Graph export: every completed transfer in October 2026 (Lagos time) becomes a TRANSFERRED relationship
COPY (SELECT t.reference, d.account_number AS from_account, c.account_number AS to_account, t.amount, t.channel,
             to_char(t.created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') AS at
      FROM bank_transaction t
      JOIN account d ON d.account_id = t.debit_account_id
      JOIN account c ON c.account_id = t.credit_account_id
      WHERE t.txn_type = 'TRANSFER' AND t.status = 'COMPLETED'
        AND t.created_at >= TIMESTAMPTZ '2026-10-01 00:00+01' AND t.created_at < TIMESTAMPTZ '2026-11-01 00:00+01'
      ORDER BY t.created_at) TO STDOUT WITH (FORMAT csv, HEADER);
