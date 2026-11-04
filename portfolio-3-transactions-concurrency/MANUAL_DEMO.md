# Manual two-terminal demo (for screenshots)

The scripted evidence in `evidence/` is reproducible, but the assessor may also want to see the anomalies **live**. Open two terminal windows side by side, one for session **A** and one for session **B**, and type the statements in the order shown. Take a screenshot at each ⏸ point.

**Setup:** reset the sample data first, so the balances match the numbers below.

```bash
./portfolio-1-database-design/run_all.sh          # resets to the small sample dataset
docker exec -it owotrust-pg psql -U owotrust -d owotrust_bank     # run this in BOTH terminals
```

---

## Demo 1: lost update, then fixing it with `FOR UPDATE`

Account `3010000003` starts at ₦450,000. A withdraws ₦100,000 and B withdraws ₦50,000, so the correct final balance is ₦300,000.

### 1a. The anomaly

| Step | Terminal A | Terminal B |
|---|---|---|
| 1 | `BEGIN;` | |
| 2 | `SELECT balance FROM account WHERE account_number = '3010000003';` → 450000 | |
| 3 | | `BEGIN;` |
| 4 | | `SELECT balance FROM account WHERE account_number = '3010000003';` → 450000 |
| 5 | `UPDATE account SET balance = 350000 WHERE account_number = '3010000003';` | |
| 6 | `COMMIT;` | |
| 7 | | `UPDATE account SET balance = 400000 WHERE account_number = '3010000003';` |
| 8 | | `COMMIT;` |
| 9 | `SELECT balance FROM account WHERE account_number = '3010000003';` → **400000** ⏸ | |

₦100,000 has been lost. Reset before 1b: `UPDATE account SET balance = 450000 WHERE account_number = '3010000003';`

### 1b. The fix

| Step | Terminal A | Terminal B |
|---|---|---|
| 1 | `BEGIN;` | |
| 2 | `SELECT balance FROM account WHERE account_number = '3010000003' FOR UPDATE;` → 450000 | |
| 3 | | `BEGIN;` |
| 4 | | `SELECT balance FROM account WHERE account_number = '3010000003' FOR UPDATE;` → **hangs** ⏸ |
| 5 | `UPDATE account SET balance = 350000 WHERE account_number = '3010000003';` | |
| 6 | `COMMIT;` | B's query now returns **350000** ⏸ |
| 7 | | `UPDATE account SET balance = 300000 WHERE account_number = '3010000003';` |
| 8 | | `COMMIT;` |

While B is hanging at step 4, you can open a **third** terminal and see who is blocking whom:

```sql
SELECT pid, state, wait_event_type, pg_blocking_pids(pid) AS blocked_by, left(query, 60)
FROM pg_stat_activity WHERE datname = 'owotrust_bank' AND pid <> pg_backend_pid();
```

---

## Demo 2: write skew, REPEATABLE READ vs SERIALIZABLE

Rule: Adaeze's savings `3010000001` (₦450,000) plus her current account `3010000002` (₦249,900) must stay ≥ 0.

| Step | Terminal A | Terminal B |
|---|---|---|
| 1 | `BEGIN ISOLATION LEVEL REPEATABLE READ;` | |
| 2 | `SELECT SUM(balance) FROM account WHERE account_number IN ('3010000001','3010000002');` → 699900 | |
| 3 | | `BEGIN ISOLATION LEVEL REPEATABLE READ;` |
| 4 | | same `SELECT SUM(...)` → 699900 |
| 5 | `UPDATE account SET balance = balance - 340000 WHERE account_number = '3010000002';` | |
| 6 | | `UPDATE account SET balance = balance - 400000 WHERE account_number = '3010000001';` |
| 7 | `COMMIT;` | |
| 8 | | `COMMIT;` |
| 9 | `SELECT SUM(...)` → **−40100** ⏸ | |

Reset with `./portfolio-1-database-design/run_all.sh`, then repeat with `BEGIN ISOLATION LEVEL SERIALIZABLE;` in both terminals. At step 8, B fails with **"could not serialize access due to read/write dependencies among transactions"** ⏸.

---

Save screenshots in `portfolio-3-transactions-concurrency/evidence/screenshots/` and reference them in the LMS write-up.
