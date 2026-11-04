#!/usr/bin/env bash
# DURABILITY (the "D" in ACID): simulate a power failure.
#
#  1. Commit transfer DUR-TEST-COMMITTED.
#  2. Start transfer DUR-TEST-IN-FLIGHT in another session and leave it open.
#  3. Kill the database with SIGKILL (no clean shutdown, no checkpoint).
#  4. Restart. PostgreSQL replays its write-ahead log (WAL) on start-up.
#  5. Expect: the committed transfer survived, the in-flight one vanished,
#     and every balance still matches the transaction history.
#
# Usage: ./durability_crash_test.sh   (requires: docker compose up -d)
set -euo pipefail

SQL() { docker exec owotrust-pg psql -X -U owotrust -d owotrust_bank -c "$1" 2>&1; }

echo "-- run at $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo
echo "== 1. Commit a transfer (autocommit: committed as soon as it returns)"
SQL "SELECT * FROM transfer_funds('3010000001','3010000003', 12345, 'MOBILE', 'Durability test', 'DUR-TEST-COMMITTED');"

echo "== 2. Start a second transfer in another session and leave it UNCOMMITTED"
docker exec -d owotrust-pg psql -X -U owotrust -d owotrust_bank -c \
  "BEGIN; SELECT * FROM transfer_funds('3010000019','3010000018', 54321, 'MOBILE', 'Durability test', 'DUR-TEST-IN-FLIGHT'); SELECT pg_sleep(120); COMMIT;"
sleep 2
SQL "SELECT pid, state, left(query, 70) AS query FROM pg_stat_activity WHERE query LIKE 'BEGIN; SELECT * FROM transfer_funds%';"
SQL "SELECT account_number, balance FROM account WHERE account_number IN ('3010000001','3010000003','3010000018','3010000019') ORDER BY 1;"

echo "== 3. CRASH: kill the PostgreSQL server process with SIGKILL"
crash_time=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
docker kill --signal=SIGKILL owotrust-pg >/dev/null
echo "killed at ${crash_time}; container state: $(docker inspect -f '{{.State.Status}}' owotrust-pg)"

echo "== 4. Restart and wait until the database accepts connections"
docker start owotrust-pg >/dev/null
until docker exec owotrust-pg pg_isready -U owotrust -d owotrust_bank >/dev/null 2>&1; do sleep 1; done
echo "server log after restart (crash recovery):"
docker logs --since "${crash_time}" owotrust-pg 2>&1 \
  | grep -E 'not properly shut down|automatic recovery|redo starts|redo done|ready to accept' | sed 's/^/   /'

echo
echo "== 5. Verify"
SQL "SELECT reference, status, amount, completed_at FROM bank_transaction WHERE reference LIKE 'DUR-TEST-%' ORDER BY reference;"
SQL "SELECT account_number, balance FROM account WHERE account_number IN ('3010000001','3010000003','3010000018','3010000019') ORDER BY 1;"
SQL "SELECT COUNT(*) AS accounts_where_balance_does_not_match_history
     FROM account a
     LEFT JOIN (SELECT account_id, SUM(delta) AS derived
                FROM (SELECT credit_account_id AS account_id,  amount AS delta FROM bank_transaction
                      WHERE status IN ('COMPLETED','REVERSED') AND credit_account_id IS NOT NULL
                      UNION ALL
                      SELECT debit_account_id,  -amount FROM bank_transaction
                      WHERE status IN ('COMPLETED','REVERSED') AND debit_account_id IS NOT NULL) legs
                GROUP BY account_id) d ON d.account_id = a.account_id
     WHERE a.balance <> COALESCE(d.derived, 0);"
echo "Expected: DUR-TEST-COMMITTED present, DUR-TEST-IN-FLIGHT absent, 0 mismatches."
