# Portfolio 2 – Query Processing and Optimisation

- **Case study:** OwoTrust Digital Bank (same schema as [Portfolio 1](../portfolio-1-database-design/README.md))
- **DBMS:** PostgreSQL 16.15 (Docker), default configuration
- **Data volume:** 50,015 customers · 60,020 accounts · **1,060,052 transactions** (204 MB)

| File | Purpose |
|---|---|
| [sql/01_bulk_data.sql](sql/01_bulk_data.sql) | Generates the large, realistic dataset (reproducible with `setseed`) |
| [sql/02_workload.sql](sql/02_workload.sql) | The 11 queries being optimised. Each is written once and run in 3 modes. |
| [sql/03_indexes.sql](sql/03_indexes.sql) | 6 targeted indexes + 1 extended statistics object, each justified |
| [sql/04_advanced.sql](sql/04_advanced.sql) | Planner statistics, the `NOT IN` trap, `work_mem`, materialized view |
| [sql/05_index_tradeoffs.sql](sql/05_index_tradeoffs.sql) | What indexes cost: storage, alternatives, write overhead |
| [benchmark.py](benchmark.py) | Runs the workload 5× and records the median execution time |
| [run_all.sh](run_all.sh) | Rebuilds everything from scratch and regenerates `evidence/` (~35 s) |
| [evidence/](evidence/) | All query results, execution plans and measurements |

---

## 1. How PostgreSQL processes a query

1. **Parse.** The SQL text is checked for syntax and turned into a parse tree.
2. **Analyse and rewrite.** Table and column names are resolved, and views are expanded.
3. **Plan (optimise).** The **cost-based optimiser** enumerates alternative plans and estimates the cost of each. Costs are measured in units of page reads and CPU work.
   - Scan methods: sequential, index, bitmap, index-only.
   - Join methods: nested loop, hash, merge.
   - Aggregation: hash or sort-based.
   - Parallelism.

   The estimates depend on **statistics** that `ANALYZE` collects into `pg_stats`: row counts, number of distinct values, most common values, histograms, and physical-order correlation. The cheapest plan wins.
4. **Execute.** The plan tree runs. Each node pulls rows from its children.

**How to read the plans in `evidence/`.**
- `cost=a..b` is the planner's *estimate*. `actual time=a..b` is the measured time in ms.
- `rows=` appears in both, so the estimate and the reality can be compared. A big gap between them is the most common cause of a bad plan, and this portfolio shows three examples (§5).
- `loops=` is the number of times a node ran.
- `Buffers: shared hit` is pages found in memory, and `read` is pages fetched from disk or the OS cache.

---

## 2. Test data

[01_bulk_data.sql](sql/01_bulk_data.sql) adds bulk data on top of the Portfolio 1 sample. It loads in about 16 s with **every CHECK and FK constraint enforced on every row**.

The data is realistic in the ways that change query plans:

| Property | How it was generated | Why it matters for plans |
|---|---|---|
| **Skewed activity** | Debit account = `power(random(), 2)`. The top 10% of accounts make **32.5%** of debits, and the busiest account (a "POS merchant") has **3,086** transactions, against a median of 9. | The planner has to handle both very busy and quiet accounts (§5.1). |
| **Growing volume** | Transaction time = `power(random(), 0.8)`. Quarterly volume rises from 81k (2025 Q1) to 167k (2026 Q3). | Recent date ranges hold more rows. |
| **Arrival order** | Rows are inserted in `created_at` order, as in a live system. | `created_at` has a physical correlation of **1.000**, which is what makes BRIN work (§6). |
| **Status mix** | 98% COMPLETED, 1.8% FAILED, **220 PENDING** (only in the last week) | A partial index pays off (Q5). |
| **Valid balances** | Each account gets an opening deposit sized so that its *running* balance never goes below zero. | The statements in Q2 make sense. |

---

## 3. Method

1. **One source of truth for the queries.** [02_workload.sql](sql/02_workload.sql) prefixes every query with a psql variable `:EXPLAIN`. Running the file with `EXPLAIN=` gives the results. Running it with `EXPLAIN='EXPLAIN (ANALYZE, BUFFERS)'` gives the plans. The "before" and "after" plans are therefore guaranteed to come from identical SQL.
2. **Baseline.** Only the indexes from Portfolio 1's PRIMARY KEY and UNIQUE constraints exist. Fresh `VACUUM ANALYZE`.
3. **Optimise.** Run [03_indexes.sql](sql/03_indexes.sql). Every index is tied to the queries it serves.
4. **Measure.** [benchmark.py](benchmark.py) runs the workload once to warm the cache, then **5 more times**, and records the **median** server-side execution time. It uses `EXPLAIN (ANALYZE, TIMING OFF)`, because per-node timing adds measurable overhead. For example, Q1 measured 88 ms with per-node timing but 51 ms without, because it times 1 million loop iterations.
5. **Environment:** Apple M4, Docker with 10 CPUs and 8 GB RAM, PostgreSQL defaults (`shared_buffers` 128 MB, `work_mem` 4 MB, up to 2 parallel workers per query). See [00_environment.txt](evidence/00_environment.txt).

Timings vary by about ±10% between runs. The evidence files contain the exact figures of the recorded run.

---

## 4. Workload and results

Source: [evidence/06_benchmark_summary.md](evidence/06_benchmark_summary.md). Query results are in [02_query_results.txt](evidence/02_query_results.txt), and plans are in [03_plans_before_indexing.txt](evidence/03_plans_before_indexing.txt) and [05_plans_after_indexing.txt](evidence/05_plans_after_indexing.txt).

| Query | Business purpose | Before (ms) | After (ms) | Speed-up | Key technique |
|---|---|---:|---:|---:|---|
| Q1 | App: last 20 transactions of the busiest account | 50.9 | 3.61 | 14× | Two composite B-trees, BitmapOr |
| Q1b | Q1 rewritten as `UNION ALL` | 91.2 | 1.42 | 64× | Query rewrite |
| **Q1c** | Q1b with the account id passed as a value | 32.1 | **0.019** | **1,690×** | Statistics-aware plan |
| Q2 | Monthly statement with running balance (window function) | 73.9 | 0.33 | 222× | Composite B-trees |
| Q3 | Login by e-mail, case-insensitive | 10.1 | 0.014 | 721× | Expression index |
| Q4 | All accounts of a customer (by BVN) | 0.66 | 0.029 | 23× | Foreign-key index |
| Q5 | Fraud queue: oldest 50 PENDING | 20.3 | 0.025 | 811× | Partial index |
| Q6 | Top 10 senders, last 90 days | 69.2 | 64.2 | 1.1× | BRIN (little gain, see §5.6) |
| Q7 | Dashboard: monthly volume per channel | 306.1 | 278.5 | 1.1× | Index does not help |
| **Q7b** | Q7 rewritten + extended statistics | 233.5 | **60.2** | **3.9×** | Extended statistics |
| Q8 | Dormant accounts per branch (`NOT EXISTS`) | 72.6 | 27.3 | 2.7× | Mixed anti-join strategies |

All rewritten queries were checked against the originals and return **identical rows**: Q1 = Q1b = Q1c, and Q7 = Q7b.

---

## 5. Analysis

### 5.1 Q1 / Q1b / Q1c: the "recent transactions" screen

**Before indexing.** The account is found via its unique index, but every transaction then has to be checked against `debit_account_id = X OR credit_account_id = X`. The plan shows a sequential scan with **"Rows Removed by Join Filter: 1,056,966"**.

**Q1 after indexing.** The planner uses *both* new indexes and combines them with a **BitmapOr**. The OR across two columns is the cost of the single-row debit/credit design chosen in Portfolio 1 §4.7, and this is how the database copes with it. However, it still fetches **all 3,086** of the merchant's transactions (2,828 heap pages) and sorts them only to keep 20.

**Q1b (UNION ALL rewrite).** Each branch can now read its own index in `created_at` order. Before indexing, the rewrite was **slower** (91 vs 51 ms) because it scanned the table twice. *A rewrite only helps when the indexes it relies on exist.*

**Q1c: the most instructive result.** Q1b still did a bitmap scan and a sort. Its plan shows **`rows=19` estimated against 3,074 actual**. Because the account id came from a CTE, its value was unknown at planning time, so the planner assumed an *average* account. In Q1c the id is written as a value. The planner then finds account 21 in `pg_stats.most_common_vals` at **0.31% of all rows**, and chooses an **Index Scan Backward that stops after 20 entries**. The result is 0.019 ms, against 50.9 ms originally.

- **Lesson:** the planner is only as good as its row estimates.
- **Practical rule:** the mobile app already knows the `account_id` after login, so it should pass that value directly. With prepared statements, PostgreSQL uses value-specific ("custom") plans for the first five executions and may then switch to a generic plan. For a column as skewed as this one, `plan_cache_mode = force_custom_plan` keeps per-value plans.

### 5.2 Q2: statement with running balance

This query uses a CTE, a window function (`SUM(...) OVER (ORDER BY created_at, txn_id)`) and an opening balance derived from history. It needs all of the account's posted transactions. The two composite indexes reduce that from a 1-million-row scan to **177 rows** via BitmapOr: **222× faster**.

### 5.3 Q3: login by e-mail (expression index)

Portfolio 1 already had a `UNIQUE` index on `email`, but `WHERE lower(email) = …` **cannot use it**. The index stores `email`, not `lower(email)`, so the plan was a sequential scan over 50,015 customers.

`CREATE UNIQUE INDEX … (lower(email))` makes the lookup a single index probe (**721× faster**). It also fixes a data-quality gap: `Ada@x.com` and `ada@x.com` can no longer both be registered.

### 5.4 Q4: the column order of a composite key matters

`account_holder` has `PRIMARY KEY (account_id, customer_id)`. Before indexing, the planner still used that index for `customer_id = ?`, but because `customer_id` is the *second* column it had to read the **entire index** (the plan shows ~1,100 cost units for 2 rows). PostgreSQL 16 cannot "skip-scan" to a second column.

A dedicated foreign-key index on `customer_id` turns this into a direct lookup (**23×**). PostgreSQL does not index foreign keys automatically, so each one has to be considered deliberately.

### 5.5 Q5: partial index for the fraud queue

Only 220 of 1,060,052 rows (0.02%) are PENDING. A partial index `ON (created_at) WHERE status = 'PENDING'` stores only those rows, at **16 kB**. A full index on `(status, created_at)` would serve the same query but takes **41 MB** (§6). The query goes from a parallel sequential scan to reading 50 index entries in order: **811×**.

### 5.6 Q6: analytics over many rows (where indexes stop helping)

The BRIN index does work. The plan reads **2,884 of 17,092 heap pages** ("Heap Blocks: lossy=2884") instead of all of them. But the time is spent joining and aggregating **91,812 rows** across 36,630 customers, so the overall gain is small (1.1×).

Two follow-up experiments both showed **no meaningful gain**:
- **A B-tree instead of BRIN** ([08_index_tradeoffs.sql](evidence/08_index_tradeoffs_output.txt), F3): 65.0 ms, against 64.2 ms with BRIN. The B-tree is about 1,000× larger.
- **`work_mem = 64MB`** ([07_advanced_output.txt](evidence/07_advanced_output.txt), C3): this removed a small 1.6 MB disk spill in the HashAggregate (Batches 5 → 1). The recorded run went from 71.8 to 61.3 ms, but in an earlier run the two were equal (63.1 vs 62.6 ms). The gain is therefore within single-run noise and small next to the cost of the joins.

*Measuring rather than assuming:* not every plausible tuning step pays off. For this kind of report, the right tool is a summary table or a materialized view (§5.7).

### 5.7 Q7 / Q7b: the dashboard, cardinality estimation, extended statistics and a materialized view

Q7 aggregates about **521,000 rows** (half the table), so indexes cannot help much (1.1×). The plan showed two deeper problems:

1. **The sort spilled to disk** ("external merge, Disk: 15 MB") because `work_mem` is 4 MB. With `SET LOCAL work_mem = '64MB'` it sorts in memory instead ("quicksort, 36 MB"): **367 → 240 ms** in the recorded run (advanced output, C1/C2).
2. The **real cause** is a misestimate: **523,867 estimated groups against 70 actual**. The planner cannot estimate how many distinct values `to_char(date_trunc('month', created_at))` produces. Expecting half a million groups, it rejected a hash table and chose sort-then-group.

The **Q7b** fix has two parts:
- **Rewrite:** group by `date_trunc('month', created_at AT TIME ZONE 'Africa/Lagos')`, and call `to_char` on only the 70 result rows instead of 521,000 input rows. The `AT TIME ZONE` makes the expression `IMMUTABLE`, which is a requirement for the next step.
- **`CREATE STATISTICS st_txn_month_channel ON (that expression), channel`:** after `ANALYZE`, `pg_stats_ext_exprs` shows **n_distinct = 23** months. The estimate becomes 155 groups, and the planner switches to a **parallel Partial HashAggregate**.

Result: **60 ms**, against 306 ms for the original. That is 5× faster, with no extra memory and no index.

**Materialized view** (advanced output, section D). The dashboard needs only ~155 numbers that change once a day, so pre-computing them in `mv_monthly_channel_stats` makes the page query **0.057 ms**.
- **Correctness:** the totals were verified to match the live query exactly (0 mismatches).
- **Cost:** the data is a *snapshot*, and `REFRESH MATERIALIZED VIEW CONCURRENTLY` takes about 0.3–0.5 s. That is acceptable for a nightly batch job, but not for real-time balances.

### 5.8 Q8: dormant accounts (anti-joins)

After indexing, the planner **mixes strategies** in one plan:
- The credit side uses a parallel **hash anti-join**, fed by a BRIN bitmap scan of transactions since May.
- For the 699 accounts that survive, the debit side uses a **nested-loop anti-join** that probes `ix_txn_debit_acct_created` (`loops=699`).

The planner chooses per join, based on how many rows it expects to reach each one: **2.7×** faster.

### 5.9 A correctness trap: `NOT IN` with NULLs (advanced output, section B)

Question: *how many accounts received no money in the last week?*

| Formulation | Answer |
|---|---:|
| `account_id NOT IN (SELECT credit_account_id …)` | **0** ❌ |
| `NOT EXISTS (SELECT 1 … WHERE credit_account_id = a.account_id)` | **50,164** ✅ |
| `NOT IN (… WHERE credit_account_id IS NOT NULL)` | 50,164 ✅ |

`credit_account_id` is NULL for withdrawals and fees. `x NOT IN (…, NULL)` evaluates to UNKNOWN, never TRUE, so the first query **silently returns nothing**. This is why all workload queries use `NOT EXISTS`.

`NOT EXISTS` is also safer for performance. It becomes an **anti-join**. `NOT IN` becomes a hashed subplan, which falls back to quadratic re-scanning if the subquery result does not fit in `work_mem`.

---

## 6. What the indexes cost ([08_index_tradeoffs_output.txt](evidence/08_index_tradeoffs_output.txt))

| Trade-off | Measurement |
|---|---|
| **Storage** | `bank_transaction` heap = 134 MB. Its indexes add up to about 135 MB, so they **double** the footprint. The two composite indexes are 32 MB each. The largest index is actually Portfolio 1's `UNIQUE(reference)` at **41 MB**: constraints have a physical cost too. |
| **Write speed** | Inserting 200,000 rows: **93 ms without** the Portfolio 2 indexes, **370 ms with** them. That is **0.47 → 1.85 µs per row, about 4× slower**, because every insert must also update every index. |
| **Partial vs full** | Partial PENDING index **16 kB** vs full `(status, created_at)` index **41 MB**: about 2,600× smaller, for the same Q5 benefit. |
| **BRIN vs B-tree** | BRIN on `created_at` **24 kB** vs B-tree **23 MB**: about 1,000× smaller, with equal Q6 speed. BRIN only works because `created_at` follows the physical order (correlation 1.000). On a randomly ordered column such as `debit_account_id` (correlation −0.004), it would be useless. |

**Design decision.** Indexes are added only where a workload query justifies them, not on every column. For a bank, the extra ~1.4 µs per inserted transaction is affordable. It is small next to the cost of committing each individual transaction to disk. Even so, each new index has to earn its place, because it slows every deposit, withdrawal and transfer. The "alternative" indexes in F1/F2 were built and measured inside a transaction and then **rolled back**, using PostgreSQL's transactional DDL.

---

## 7. Key lessons

1. **Indexes give huge gains for selective queries** (23×–1,690×) and **almost none for queries that read a large share of the table** (Q6, Q7).
2. **The planner is only as good as its row estimates.** Two of the biggest wins (Q1c, Q7b) came from fixing *estimates* (per-value statistics, expression statistics), not from adding indexes.
3. **A rewrite can make things worse** without the right indexes (Q1b before indexing).
4. **Choose the index type to match the data:** partial for rare values, expression for computed lookups, BRIN for naturally ordered time-series, composite with the right column order.
5. **Every index is paid for on every write.** Measure the cost as well as the benefit.
6. **Correctness comes first:** `NOT IN` with NULLs gives fast, wrong answers.

---

## 8. How to run

```bash
# from the repository root, with Docker Desktop running
docker compose up -d
./portfolio-2-query-optimisation/run_all.sh
```

This rebuilds the database from scratch (Portfolio 1 schema → bulk data → plans → indexes → plans → benchmarks → advanced → trade-offs) and rewrites every file in `evidence/`. It replaces the small Portfolio 1 dataset; run `portfolio-1-database-design/run_all.sh` to restore it.
