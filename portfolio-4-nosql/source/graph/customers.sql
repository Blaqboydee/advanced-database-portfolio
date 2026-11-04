-- Graph export: one Customer node per customer (no BVN/phone: the fraud graph does not need PII)
COPY (SELECT customer_id, first_name || ' ' || last_name AS name, kyc_tier,
             to_char(created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') AS created_at
      FROM customer ORDER BY customer_id) TO STDOUT WITH (FORMAT csv, HEADER);
