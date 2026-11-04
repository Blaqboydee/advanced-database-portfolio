-- Graph export: one Account node per account, with its primary holder (for the OWNS relationship)
COPY (SELECT a.account_number, ah.customer_id, a.type_code, a.status,
             to_char(a.opened_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') AS opened_at
      FROM account a JOIN account_holder ah ON ah.account_id = a.account_id AND ah.holder_role = 'PRIMARY'
      ORDER BY a.account_number) TO STDOUT WITH (FORMAT csv, HEADER);
