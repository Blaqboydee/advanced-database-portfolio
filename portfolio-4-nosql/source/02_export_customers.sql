-- =====================================================================
-- OwoTrust Digital Bank (simulated) - Portfolio 4
-- 02_export_customers.sql : relational rows -> one MongoDB document per customer
--
-- Output: newline-delimited MongoDB Extended JSON ({"$date": ...} for dates,
-- {"$numberDecimal": ...} for money, so no precision is lost). Timestamps are
-- written in UTC (the trailing Z), hence SET timezone = 'UTC'. Run with:
--   psql -At -f 02_export_customers.sql > data/customers.ndjson
--
-- Mapping (relational -> document):
--   customer row                 -> the document itself (_id = customer_id)
--   name / contact / address     -> grouped sub-documents
--   kyc_tier + kyc_tier limits   -> "kyc" sub-document (denormalised limits)
--   KYC evidence (varies by tier)-> "kyc.documents" array of DIFFERENTLY-SHAPED items
--   account_holder + account     -> embedded "accounts" summaries (extended reference)
--   customer_device              -> embedded "devices" array
-- KYC document details do not exist in the relational schema. They are
-- generated deterministically from the tier, to show data whose shape
-- varies from customer to customer.
-- =====================================================================

SET timezone = 'UTC';

WITH docs AS (
    SELECT c.customer_id,
           json_build_object(
               '_id', c.customer_id,
               'bvn', c.bvn,
               'name', json_build_object('first', c.first_name, 'last', c.last_name),
               'contact', json_strip_nulls(json_build_object('phone', c.phone, 'email', c.email)),
               'dateOfBirth', json_build_object('$date', to_char(c.date_of_birth, 'YYYY-MM-DD"T00:00:00Z"')),
               'address', CASE WHEN c.city IS NOT NULL THEN
                   json_strip_nulls(json_build_object('line', c.address_line, 'city', c.city, 'state', c.state)) END,
               'status', c.status,
               'kyc', json_build_object(
                   'tier', c.kyc_tier,
                   'dailyDebitLimit', json_build_object('$numberDecimal', k.daily_debit_limit::text),
                   'maxBalance', CASE WHEN k.max_balance IS NOT NULL
                                      THEN json_build_object('$numberDecimal', k.max_balance::text) END,
                   'verifiedBy', CASE c.kyc_tier WHEN 1 THEN json_build_array('BVN', 'PHONE')
                                                 WHEN 2 THEN json_build_array('BVN', 'PHONE', 'NIN')
                                                 ELSE json_build_array('BVN', 'PHONE', 'NIN', 'ADDRESS') END,
                   -- documents have DIFFERENT fields depending on their type
                   'documents', CASE c.kyc_tier
                       WHEN 1 THEN json_build_array()
                       WHEN 2 THEN json_build_array(
                           json_build_object('type', 'NIN', 'number', '7' || lpad(c.customer_id::text, 10, '0'),
                                             'verifiedAt', json_build_object('$date', to_char(c.created_at, 'YYYY-MM-DD"T"HH24:MI:SS"Z"'))))
                       ELSE json_build_array(
                           json_build_object('type', 'NIN', 'number', '7' || lpad(c.customer_id::text, 10, '0'),
                                             'verifiedAt', json_build_object('$date', to_char(c.created_at, 'YYYY-MM-DD"T"HH24:MI:SS"Z"'))),
                           json_build_object('type', 'UTILITY_BILL',
                                             'issuer', (ARRAY['IKEDC','EKEDC','AEDC','IBEDC','PHED'])[1 + c.customer_id % 5],
                                             'billMonth', to_char(c.created_at - INTERVAL '1 month', 'YYYY-MM'),
                                             'addressMatched', c.customer_id % 23 <> 0),
                           CASE WHEN c.customer_id % 2 = 0 THEN
                               json_build_object('type', 'INTL_PASSPORT', 'number', 'A' || lpad((c.customer_id * 7)::text, 8, '0'),
                                                 'expiresOn', json_build_object('$date',
                                                     to_char(DATE '2025-01-01' + (c.customer_id * 37) % 2500, 'YYYY-MM-DD"T00:00:00Z"')))
                           ELSE
                               json_build_object('type', 'DRIVERS_LICENCE', 'number', 'LAG' || lpad(c.customer_id::text, 9, '0'),
                                                 'stateOfIssue', COALESCE(c.state, 'Lagos'),
                                                 'expiresOn', json_build_object('$date',
                                                     to_char(DATE '2025-01-01' + (c.customer_id * 53) % 2000, 'YYYY-MM-DD"T00:00:00Z"')))
                           END)
                   END),
               'accounts', (
                   SELECT json_agg(json_build_object(
                              'accountNumber', a.account_number,
                              'product', at.type_code,
                              'currency', at.currency,
                              'role', ah.holder_role,
                              'status', a.status,
                              'balance', json_build_object('$numberDecimal', a.balance::text),
                              'branch', json_build_object('code', b.branch_code, 'name', b.branch_name),
                              'openedAt', json_build_object('$date', to_char(a.opened_at, 'YYYY-MM-DD"T"HH24:MI:SS"Z"')))
                          ORDER BY a.account_number)
                   FROM account_holder ah
                   JOIN account a       ON a.account_id = ah.account_id
                   JOIN account_type at ON at.type_code = a.type_code
                   JOIN branch b        ON b.branch_id  = a.branch_id
                   WHERE ah.customer_id = c.customer_id),
               'devices', (
                   SELECT json_agg(json_build_object(
                              'deviceId', d.device_id, 'platform', d.platform,
                              'firstSeen', json_build_object('$date', to_char(d.first_seen, 'YYYY-MM-DD"T"HH24:MI:SS"Z"')))
                          ORDER BY d.first_seen)
                   FROM customer_device d WHERE d.customer_id = c.customer_id),
               'createdAt', json_build_object('$date', to_char(c.created_at, 'YYYY-MM-DD"T"HH24:MI:SS"Z"'))
           ) AS body
    FROM customer c
    JOIN kyc_tier k ON k.tier_level = c.kyc_tier
)
-- drop keys whose value is NULL: in a document an unknown field is simply absent
SELECT json_strip_nulls(body)
FROM docs
ORDER BY customer_id;
