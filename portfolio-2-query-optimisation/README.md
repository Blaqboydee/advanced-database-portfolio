# Portfolio 2 – Query Processing and Optimisation

**Status:** Planned

Planned scope, using the OwoTrust schema from Portfolio 1:

- Generate a large synthetic dataset (hundreds of thousands of transactions) with `generate_series`.
- Write realistic queries: an account statement with a running balance (window function), monthly volume per channel, top customers by value, and dormant-account detection.
- Capture `EXPLAIN (ANALYZE, BUFFERS)` plans before and after indexing: foreign-key indexes, a composite index, a partial index on `PENDING` transactions and a covering index.
- Optimise the two-column statement lookup (`debit_account_id = X OR credit_account_id = X`), comparing a BitmapOr plan with a `UNION ALL` rewrite.
- Write a short performance analysis of the results.
