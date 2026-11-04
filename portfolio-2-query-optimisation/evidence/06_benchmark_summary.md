-- run at 2026-11-04 03:16:29 WAT
| Query | Purpose | before (ms) | after (ms) | Speed-up |
|---|---|---:|---:|---:|
| Q1 | Mobile app: 20 most recent transactions of an account (OR on two columns) | 50.936 | 3.611 | 14.1x |
| Q1b | Same result as Q1, rewritten as UNION ALL of two ordered branches | 91.237 | 1.424 | 64.1x |
| Q1c | Same as Q1b, but the account_id is passed as a value (planner can use per-value statistics) | 32.111 | 0.019 | 1,690.1x |
| Q2 | Monthly statement (October 2026) with opening and running balance | 73.917 | 0.333 | 222.0x |
| Q3 | Login: find a customer by e-mail, case-insensitive | 10.090 | 0.014 | 720.7x |
| Q4 | Customer-service screen: all accounts of a customer, looked up by BVN | 0.660 | 0.029 | 22.8x |
| Q5 | Fraud-review queue: oldest 50 PENDING transactions | 20.274 | 0.025 | 811.0x |
| Q6 | Compliance: top 10 customers by value transferred out in the last 90 days | 69.171 | 64.187 | 1.1x |
| Q7 | Management dashboard: monthly volume and value per channel, Jan-Oct 2026 | 306.053 | 278.547 | 1.1x |
| Q7b | Same result as Q7: group on an immutable month expression, format the text after aggregating | 233.510 | 60.204 | 3.9x |
| Q8 | Dormancy report: ACTIVE accounts per branch with no posted activity since 1 May 2026 | 72.617 | 27.318 | 2.7x |

Median of 5 runs after one warm-up run; server-side execution time from EXPLAIN (ANALYZE, TIMING OFF).
