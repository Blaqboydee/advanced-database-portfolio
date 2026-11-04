# Portfolio 3 – Transactions and Concurrency

**Status:** Planned

Planned scope, using the OwoTrust schema from Portfolio 1:

- A fund-transfer stored procedure that commits on success and rolls back on failure (insufficient funds, frozen account, KYC daily limit).
- Savepoints, and reversing a failed transaction.
- Concurrency problems reproduced in two sessions: a lost update caused by concurrent withdrawals, and a deadlock caused by opposite-direction transfers.
- Control mechanisms: `SELECT … FOR UPDATE`, consistent lock ordering, and `READ COMMITTED` vs `REPEATABLE READ` vs `SERIALIZABLE`.
- Enforcing the multi-row business rules listed in Portfolio 1 §3.4, plus an audit trigger.
