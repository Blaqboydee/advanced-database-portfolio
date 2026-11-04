#!/usr/bin/env bash
# Runs every Portfolio 3 experiment on a fresh database and regenerates evidence/.
# Takes about 1 minute. Requires: docker compose up -d   (from the repository root)
#
# NOTE: step 6 deliberately CRASHES the database container (SIGKILL) and restarts it.
# evidence/06_stress_v1_FOR_UPDATE_deadlocks.txt is NOT regenerated: it records the
# first version of transfer_funds() (FOR UPDATE), which has since been fixed.
set -euo pipefail
cd "$(dirname "$0")"

P1=/portfolio/portfolio-1-database-design/sql
P3=/portfolio/portfolio-3-transactions-concurrency
# run psql inside the container and merge errors into the output there, so that
# ERROR lines appear exactly where they happened
psql_run() { docker exec owotrust-pg sh -c "psql -X -U owotrust -d owotrust_bank $* 2>&1"; }
stamp()    { echo "-- run at $(date '+%Y-%m-%d %H:%M:%S %Z')"; }
step()     { echo "==> $*"; }
rebuild()  {
    psql_run -q -v ON_ERROR_STOP=1 -f $P1/01_schema.sql | grep -v NOTICE || true
    psql_run -q -v ON_ERROR_STOP=1 -f $P1/02_seed_data.sql
    psql_run -v ON_ERROR_STOP=1 -f $P3/sql/01_transaction_objects.sql
}
stress() {  # $1 = naive | safe, $2 = transfers per client
    stamp
    rebuild > /dev/null
    psql_run -f $P3/sql/04_stress_setup.sql
    echo "--- pgbench: 16 concurrent clients x $2 transfers = $((16 * $2)) transfers"
    docker exec owotrust-pg sh -c "pgbench -n -U owotrust -c 16 -j 4 -t $2 --max-tries=20 \
        --failures-detailed -f $P3/stress/pgbench_transfer_$1.sql owotrust_bank 2>&1"
    psql_run -f $P3/sql/05_stress_check.sql
}

step "1/6 Fresh database + Portfolio 3 objects"
{ stamp; rebuild; } > evidence/01_objects_output.txt

step "2/6 ACID demos (commit, rollback, savepoints, rules, idempotency, deferred constraint)"
{ stamp; psql_run -f $P3/sql/02_acid_demos.sql; } > evidence/02_acid_demos_output.txt

step "3/6 Two-session concurrency anomalies (S1-S5)"
{ stamp; rebuild > /dev/null; psql_run -f $P3/sql/03_concurrency_anomalies.sql; } \
    > evidence/03_concurrency_anomalies_output.txt

step "4/6 Stress test: NAIVE transfer function (fewer transfers: its deadlocks make it very slow)"
stress naive 60 > evidence/04_stress_naive_output.txt

step "5/6 Stress test: SAFE transfer_funds()"
stress safe 250 > evidence/05_stress_safe_output.txt

step "6/6 Durability crash test (the container will be killed and restarted)"
{ rebuild > /dev/null; ./durability_crash_test.sh; } > evidence/07_durability_crash_test.txt 2>&1

echo
echo "Key results:"
for f in 04_stress_naive_output 05_stress_safe_output; do
    printf '  %-24s money created/destroyed = %s, deadlocks = %s, balance mismatches = %s\n' "$f" \
        "$(grep -A2 money_created evidence/$f.txt | tail -1 | awk -F'|' '{gsub(/ /,"",$3); print $3}')" \
        "$(grep -A2 deadlocks_during_run evidence/$f.txt | tail -1 | tr -d ' ')" \
        "$(grep -c '^ 3010' evidence/$f.txt || true)"
done
printf '  durability: committed transfer present after crash = %s, in-flight transfer present = %s\n' \
    "$(sed -n '/== 5. Verify/,$p' evidence/07_durability_crash_test.txt | grep -c '^ DUR-TEST-COMMITTED' || true)" \
    "$(sed -n '/== 5. Verify/,$p' evidence/07_durability_crash_test.txt | grep -c '^ DUR-TEST-IN-FLIGHT' || true)"
echo "Done. Evidence written to $(pwd)/evidence/"
