# Portfolio 3 – Transactions and Concurrency

- **Case study:** OwoTrust Digital Bank (schema and sample data from [Portfolio 1](../portfolio-1-database-design/README.md))
- **DBMS:** PostgreSQL 16 (Docker). Concurrency is driven with `dblink` (two real sessions) and `pgbench` (16 concurrent clients).

| File | Purpose |
|---|---|
| [sql/01_transaction_objects.sql](sql/01_transaction_objects.sql) | `transfer_funds()` (safe), `transfer_funds_naive()` (unsafe, for comparison), audit trigger, rule triggers, deferred constraint |
| [sql/02_acid_demos.sql](sql/02_acid_demos.sql) | D1–D7: COMMIT, ROLLBACK, atomicity, savepoints, rule failures, idempotency, deferred constraint |
| [sql/03_concurrency_anomalies.sql](sql/03_concurrency_anomalies.sql) | S1–S5: two sessions, step by step: dirty read, non-repeatable read, phantom, lost update, write skew, deadlock |
| [sql/04_stress_setup.sql](sql/04_stress_setup.sql), [sql/05_stress_check.sql](sql/05_stress_check.sql), [stress/](stress/) | Concurrent stress test with pgbench, and the integrity checks run after it |
| [durability_crash_test.sh](durability_crash_test.sh) | Kills the database mid-transaction and checks what survives |
| [run_all.sh](run_all.sh) | Runs everything on a fresh database and regenerates `evidence/` (~1.5 min) |
| [MANUAL_DEMO.md](MANUAL_DEMO.md) | Two-terminal walkthrough for reproducing the anomalies by hand (screenshots) |
| [evidence/](evidence/) | Captured output of every experiment |

---

## 1. Concepts applied

**ACID** is what a bank relies on:
- **Atomicity:** a transfer debits *and* credits, or does neither.
- **Consistency:** constraints and rules always hold.
- **Isolation:** concurrent transfers do not corrupt each other.
- **Durability:** a confirmed transfer survives a crash.

Each property is demonstrated below.

**MVCC (multi-version concurrency control).** PostgreSQL never overwrites a row in place. An `UPDATE` creates a new row *version*. Each version is stamped with the transaction that created it (`xmin`) and the one that replaced it (`xmax`). Every statement reads from a *snapshot* that decides which versions are visible to it. As a result:
- **Readers never block writers, and writers never block readers.**
- **Writers block writers** that touch the same row, through row locks held until COMMIT or ROLLBACK.

**Isolation levels in PostgreSQL.** ✅ = prevented, ❌ = can happen; each result is shown in the evidence.

| Anomaly | READ UNCOMMITTED\* | READ COMMITTED (default) | REPEATABLE READ | SERIALIZABLE |
|---|:-:|:-:|:-:|:-:|
| Dirty read | ✅ (S1) | ✅ | ✅ | ✅ |
| Non-repeatable read | ❌ | ❌ (S2a) | ✅ (S2b) | ✅ |
| Phantom read | ❌ | ❌ (S2a) | ✅ (S2b) | ✅ |
| Lost update (read-modify-write) | ❌ | ❌ (S3a) | ✅ error + retry (S3d) | ✅ |
| Write skew | ❌ | ❌ | ❌ (S4a) | ✅ (S4b) |

\* PostgreSQL silently runs READ UNCOMMITTED as READ COMMITTED. Its REPEATABLE READ is *snapshot isolation*, which is stronger than the SQL standard requires because it also prevents phantoms. Its SERIALIZABLE is *Serializable Snapshot Isolation (SSI)*, which detects dangerous read/write dependency cycles and aborts one of the transactions involved.

**Row-lock modes used here.** Explicit locks and `UPDATE` both take row locks:

| Lock | Taken by | Conflicts with |
|---|---|---|
| `FOR UPDATE` | `SELECT … FOR UPDATE`, `DELETE`, updates of key columns | every other row lock, **including `FOR KEY SHARE`** |
| `FOR NO KEY UPDATE` | ordinary `UPDATE`, `SELECT … FOR NO KEY UPDATE` | itself and `FOR UPDATE`, `FOR SHARE` |
| `FOR KEY SHARE` | **foreign-key checks** on the referenced row | only `FOR UPDATE` |

This difference turned out to matter a great deal (§5).

---

## 2. `transfer_funds()`: the safe way to move money

[sql/01_transaction_objects.sql](sql/01_transaction_objects.sql)

```
transfer_funds(from, to, amount, channel, narration, reference)
 1. Idempotency: if `reference` already exists, return the original result and post nothing.
 2. BEGIN inner block  ── PL/pgSQL runs this as a SAVEPOINT
 3.   Lock both accounts  FOR NO KEY UPDATE, ordered by account_id  ── prevents deadlocks
 4.   Validate: both ACTIVE, same currency                          ── rules 4 and 5 (Portfolio 1 §3.4)
 5.   Lock the paying customer's row; sum today's debits;
      check the KYC daily limit                                     ── rule 1, and prevents write skew
 6.   Check funds against balance + overdraft
 7.   INSERT the COMPLETED transaction; UPDATE both balances        ── all or nothing
 8. EXCEPTION: rule broken → roll back to the savepoint, INSERT a FAILED row with the reason
```

The remaining rules from Portfolio 1 §3.4 that a CHECK constraint couldn't express are now enforced as well:

| Rule | Mechanism |
|---|---|
| 1. KYC daily debit limit | `transfer_funds()` step 5, with the customer row locked |
| 2. Every account has a PRIMARY holder | **Deferred** constraint trigger, checked at COMMIT (D7) |
| 3. Overdraft only on products that allow it | `BEFORE` trigger looking up `account_type` (D7c) |
| 4. Same currency on both sides | `transfer_funds()` step 4 |
| 5. No postings to FROZEN/CLOSED accounts | `transfer_funds()` step 4 |
| 6. Stored balance = transaction history | Balance and transaction row change in one transaction; verified after every experiment (0 mismatches) |

An **audit trigger** writes every balance or status change to `audit_log`, together with the database transaction id. The audit rows belong to the *same* transaction as the change, so a rolled-back transfer leaves no audit trail (D2).

---

## 3. Single-session demonstrations: [evidence/02_acid_demos_output.txt](evidence/02_acid_demos_output.txt)

| # | Demonstration | What the evidence shows |
|---|---|---|
| D1 | **COMMIT** | ₦25,000 moves from 3010000001 to 3010000003. Both audit rows carry the same transaction id. |
| D2 | **ROLLBACK** | Inside the transaction, the new balances are visible. After `ROLLBACK`, the balances, transaction rows and audit rows are all back to the D1 state. |
| D3 | **Atomicity on error** | The credit succeeds, then the debit violates `chk_account_balance_floor`. Later statements are refused with "current transaction is aborted", and `COMMIT` is turned into `ROLLBACK`. The successful credit is undone too, so **half a transfer never survives**. |
| D4 | **SAVEPOINT** | A payroll batch of 3 payments. Payment 2 (₦2.5M) exceeds balance + overdraft, and `ROLLBACK TO SAVEPOINT payment_2` undoes only that payment. Payments 1 and 3 commit. |
| D5 | **Business rules** | Frozen account, insufficient funds, USD→NGN transfer, and the Tier-1 daily limit (₦30k OK, then +₦25k > ₦50k): each produces a FAILED row with the reason, and **no money moves**. |
| D6 | **Idempotency** | The same request reference is sent twice, simulating an app retry after a timeout. Money moves **once**, and the retry returns the original outcome. |
| D7 | **Deferred constraint** | Account + holder in one transaction: the commit succeeds. Account without a holder: the commit fails and the transaction is rolled back. Overdraft on a savings product: rejected by the trigger. |

Final check after all demos: **0 accounts** whose stored balance differs from the transaction history.

---

## 4. Concurrency anomalies, two sessions step by step: [evidence/03_concurrency_anomalies_output.txt](evidence/03_concurrency_anomalies_output.txt)

`dblink` opens two independent connections, `session_A` and `session_B`, and the script decides the exact order of every step, so each anomaly reproduces on every run. When a session blocks, the evidence shows the server's own view from `pg_stat_activity` / `pg_blocking_pids()`. For example:

```
[B] UPDATE account SET balance = balance - 50000 WHERE account_number = '3010000003'  =>  ... BLOCKED (still waiting after 0.5 s)
      lock monitor: session_B is waiting (Lock / transactionid), blocked by session_A
```

| # | Scenario (bank framing) | Result |
|---|---|---|
| S1 | A teller's uncommitted ₦1M credit; B reads at READ UNCOMMITTED | B immediately sees the **old** committed balance, with no wait and no dirty read. `xmax` on the row B reads equals A's transaction id: B is reading the old *version* that A is replacing. |
| S2a | Auditor (READ COMMITTED) totals deposits twice while a ₦100k deposit commits | The total changes by ₦100,000 and the transaction count goes 48 → 49 **within one transaction**: a non-repeatable read and a phantom. |
| S2b | Same, auditor at REPEATABLE READ | Both reads agree: one snapshot for the whole report. The deposit is visible only after the auditor's transaction ends. |
| S3a | Two ATM withdrawals (₦100k + ₦50k) from ₦450,000, read-modify-write | Final balance **₦400,000 instead of ₦300,000**: ₦100k lost. |
| S3b | Fix 1: `SET balance = balance - x` | B blocks on A's row lock, then applies its change to the committed row: ₦300,000 ✅ |
| S3c | Fix 2: `SELECT … FOR UPDATE` (pessimistic) | B's read blocks until A commits, then sees ₦350,000: ₦300,000 ✅ |
| S3d | Fix 3: REPEATABLE READ (optimistic) | B gets *"could not serialize access due to concurrent update"*. The retry reads ₦350,000: ₦300,000 ✅ |
| S4a | Write skew: savings + current must stay ≥ 0 (₦699,900 together); concurrent withdrawals of ₦340k and ₦400k at REPEATABLE READ | Both commit, and the combined balance is **−₦40,100**. Each session wrote a *different* row, so snapshot isolation saw no conflict. |
| S4b | Same at SERIALIZABLE | B's COMMIT fails with *"could not serialize access due to read/write dependencies among transactions"*. The combined balance stays ₦359,900 ✅ |
| S5a | Opposite-direction transfers, naive lock order | **Deadlock detected** after `deadlock_timeout` (1 s). PostgreSQL aborts A as the victim, and B completes. |
| S5b | Same, using `transfer_funds()` | B queues behind A for the *first* lock (lowest account id), so no cycle can form. Both complete with no deadlock ✅ |

---

## 5. Stress test: 16 concurrent clients

[evidence/04](evidence/04_stress_naive_output.txt), [05](evidence/05_stress_safe_output.txt), [06](evidence/06_stress_v1_FOR_UPDATE_deadlocks.txt)

The two-session demos show *that* anomalies exist. The stress test shows whether the controls hold up under real load. `pgbench` runs 16 concurrent clients, each sending random transfers (₦100–₦2,000) between the 16 active naira accounts. Because transfers only move money **between** those accounts, two invariants must hold, however the transfers interleave:

1. **The total money across the 16 accounts never changes.**
2. **Every stored balance equals the balance implied by the transaction history.**

| Version | Transfers | Money created from nothing | Balance mismatches | Deadlocks | Throughput |
|---|---:|---:|---:|---:|---:|
| `transfer_funds_naive()`: read, compute, write back, no locks | 960 | **+₦93,314** ❌ | **16 of 16** ❌ | 81 | 13 tps |
| `transfer_funds()` v1: `FOR UPDATE` locks | 4,000 | ₦0 ✅ | 0 ✅ | **146** ⚠️ | 52 tps |
| `transfer_funds()` **v2: `FOR NO KEY UPDATE` locks** | 4,000 | **₦0** ✅ | **0** ✅ | **0** ✅ | **8,052 tps** |

(The naive run is limited to 960 transfers because its deadlocks, each waiting 1 s to be detected, make it very slow. pgbench's `--max-tries=20` retried deadlock victims automatically, so every row above reached a final state.)

**The naive function is plainly wrong.** Lost updates silently created ₦93,314 that no transaction accounts for, and *every* account's balance disagrees with its history. Nothing raised an error, so this kind of bug can reach production unnoticed.

**Debugging v1: why did a lock-ordered function deadlock?** Version 1 locked accounts in `account_id` order and should never have deadlocked, yet 146 deadlocks occurred. The PostgreSQL server log (appended to [06_stress_v1_FOR_UPDATE_deadlocks.txt](evidence/06_stress_v1_FOR_UPDATE_deadlocks.txt)) gives the cause. Every deadlock involved:

```
CONTEXT:  SQL statement "SELECT 1 FROM ONLY "public"."account" x WHERE "account_id" = $1 FOR KEY SHARE OF x"
          SQL statement "INSERT INTO bank_transaction (...) VALUES (... 'FAILED' ...)"
```

The chain of events:
1. When a transfer breaks a rule (here, 751 hit the daily limit), the function rolls back to its savepoint. This **releases its row locks**.
2. It then inserts the FAILED record. That insert's foreign-key checks take `FOR KEY SHARE` locks on the two accounts, **credit account first**, which is outside my global lock order.
3. `FOR KEY SHARE` conflicts with the `FOR UPDATE` locks held by other transfers, so a cycle could form.

**Fix:** lock with **`FOR NO KEY UPDATE`**. That is the correct strength, because the function never changes a key, and it does **not** conflict with foreign-key checks.

Result: 0 deadlocks and 0 retries. Throughput rose **150-fold** (52 → 8,052 tps), because transfers no longer queue behind 1-second deadlock timeouts. The lesson: *correct lock ordering is not enough; the lock **strength** must also be the weakest one that is still correct.*

---

## 6. Durability: crash test

[evidence/07_durability_crash_test.txt](evidence/07_durability_crash_test.txt)

1. Commit transfer `DUR-TEST-COMMITTED` (₦12,345).
2. In another session, start transfer `DUR-TEST-IN-FLIGHT` (₦54,321) and leave it uncommitted. Other sessions do not see its balance changes.
3. **`docker kill --signal=SIGKILL`**: the server dies instantly, with no shutdown and no checkpoint, as in a power cut.
4. Restart. The server log shows:
   ```
   LOG:  database system was not properly shut down; automatic recovery in progress
   LOG:  redo starts at 0/…
   LOG:  redo done at 0/…
   LOG:  database system is ready to accept connections
   ```
5. Verified after recovery:
   - **`DUR-TEST-COMMITTED` is present.** Its commit record had been flushed to the write-ahead log (WAL) before the client was told "COMPLETED".
   - **`DUR-TEST-IN-FLIGHT` is absent**, with no half-applied balance changes.
   - **0 balance mismatches.**

---

## 7. Choosing isolation and locking for OwoTrust

| Workload | Choice | Why |
|---|---|---|
| Posting transfers, deposits, withdrawals | READ COMMITTED + explicit row locks in `transfer_funds()` | Locks only the rows involved, so it gives the highest throughput (8,052 tps) with proven correctness. No retry logic is needed. |
| Audit reports, statements, end-of-day totals | REPEATABLE READ (read-only) | One consistent snapshot for the whole report (S2b). Under MVCC it never blocks the tellers. |
| Rules spanning several rows that no single row lock covers (e.g. the combined-balance rule in S4) | SERIALIZABLE + automatic retry in the application | The only level that prevents write skew without hand-crafted locking. It costs some aborted transactions that must be retried. |

The daily-limit rule is a write-skew risk of the same kind as S4: two concurrent transfers could each pass the check. `transfer_funds()` prevents this without SERIALIZABLE by **locking the customer row**. All debits of one customer are serialised, so the check and the posting cannot interleave.

---

## 8. How to run

```bash
# from the repository root, with Docker Desktop running
docker compose up -d
./portfolio-3-transactions-concurrency/run_all.sh
```

This rebuilds the small Portfolio 1 database before each experiment and **kills and restarts the container** in the durability step. To reproduce the anomalies by hand in two terminals (for screenshots), follow [MANUAL_DEMO.md](MANUAL_DEMO.md).
