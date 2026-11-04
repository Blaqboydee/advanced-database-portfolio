#!/usr/bin/env bash
# =====================================================================
# OwoTrust Digital Bank (simulated) - Portfolio 5
# postgres/01_replication_demo.sh : streaming replication, consistency and
#                                   availability trade-offs
#   R1 topology               R5 synchronous replication switched on
#   R2 replication of a write  R6 the cost of synchronous commit (pgbench)
#   R3 replicas are read-only  R7 synchronous standby fails: writes block
#   R4 stale read on a lagging async replica   R8 quorum commit keeps writes available
# Requires the cluster from docker-compose.cluster.yml with cluster_setup.sql loaded.
# =====================================================================
set -uo pipefail

sql() {  # sql <primary|replica1|replica2> "<SQL>" [psql options]
    local node=$1; shift; local q=$1; shift
    echo "[$node] $(echo "$q" | tr -s ' \n' ' ')"
    docker exec "dist-pg-$node" psql -X -U owotrust -d owotrust_bank "$@" -c "$q" 2>&1 | sed 's/^/    /'
}
hdr() { echo; echo "======================================================================"; echo "$*"; echo "======================================================================"; }
say() { echo "  $*"; }
replication_status() {
    sql primary "SELECT application_name, state, sync_state,
                        pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) AS bytes_behind,
                        write_lag, flush_lag, replay_lag
                 FROM pg_stat_replication ORDER BY application_name;"
}

echo "-- run at $(date '+%Y-%m-%d %H:%M:%S %Z')"

hdr "R1. TOPOLOGY: one primary streaming its write-ahead log (WAL) to two hot standbys"
replication_status
sql replica1 "SELECT pg_is_in_recovery() AS replica1_is_standby, pg_last_wal_replay_lsn() AS replayed_up_to;"
sql replica2 "SELECT pg_is_in_recovery() AS replica2_is_standby, pg_last_wal_replay_lsn() AS replayed_up_to;"
sql primary "SELECT slot_name, active, wal_status FROM pg_replication_slots ORDER BY slot_name;"

hdr "R2. A DEPOSIT ON THE PRIMARY APPEARS ON BOTH REPLICAS"
say "Both replicas start polling for reference REPL-0001 BEFORE it exists; then the primary commits it."
tmp=$(mktemp -d)
for r in replica1 replica2; do
    docker exec dist-pg-$r psql -X -At -U owotrust -d owotrust_bank \
        -c "SELECT '$r: ' || wait_until_visible('REPL-0001')" > "$tmp/$r" 2>&1 &
done
sleep 1
sql primary "SELECT post_deposit('3010000001', 25000, 'REPL-0001') AS committed_on_primary;"
wait
cat "$tmp/replica1" "$tmp/replica2" | sed 's/^/    /'
replication_status

hdr "R3. REPLICAS ARE READ-ONLY"
sql replica1 "SELECT post_deposit('3010000001', 1, 'REPL-WRITE-TRY');"
say "-> every write must go to the primary; replicas can only serve reads."

hdr "R4. STALE READ: an asynchronous replica can return OLD data"
say "Replay on replica2 is paused to simulate a replica that has fallen behind (slow network or disk)."
sql replica2 "SELECT pg_wal_replay_pause();"
sql primary "SELECT post_deposit('3010000003', 70000, 'REPL-0002') AS committed_on_primary;"
sql primary  "SELECT balance AS balance_on_primary FROM account WHERE account_number = '3010000003';"
sql replica1 "SELECT balance AS balance_on_replica1 FROM account WHERE account_number = '3010000003';"
sql replica2 "SELECT balance AS balance_on_replica2 FROM account WHERE account_number = '3010000003';"
replication_status
say "-> replica2 shows the balance WITHOUT the N70,000 deposit: a customer routed to it"
say "   would see money 'missing'. The data is eventually consistent, not immediately."
sql replica2 "SELECT pg_wal_replay_resume();"
sleep 1
sql replica2 "SELECT balance AS balance_on_replica2_after_catching_up FROM account WHERE account_number = '3010000003';"

hdr "R5. SYNCHRONOUS REPLICATION: COMMIT waits until replica1 confirms it has the WAL"
sql primary "ALTER SYSTEM SET synchronous_standby_names = 'FIRST 1 (replica1)';"
sql primary "SELECT pg_reload_conf();"
sleep 1
replication_status
say "-> replica1 is now 'sync': a commit is reported to the client only after replica1 has"
say "   flushed it to disk. If the primary is lost, replica1 has every confirmed transaction (RPO = 0)."

hdr "R6. THE PRICE OF CONSISTENCY: deposit throughput, 8 clients, three commit modes"
say "3 rounds; within each round the modes run one after another for 6 s each, so background"
say "load on the laptop affects all modes alike. The MEDIAN of the 3 rounds is reported."
bench() {  # bench <synchronous_standby_names> <synchronous_commit>  -> prints "tps latency_ms"
    docker exec dist-pg-primary psql -X -q -U owotrust -d owotrust_bank \
        -c "ALTER SYSTEM SET synchronous_standby_names = '$1'" \
        -c "ALTER SYSTEM SET synchronous_commit = '$2'" -c "SELECT pg_reload_conf()" > /dev/null
    sleep 1
    docker exec dist-pg-primary pgbench -n -U owotrust -c 8 -j 4 -T 6 \
        -f /portfolio/portfolio-5-distributed-cloud/postgres/pgbench_deposit.sql owotrust_bank 2>&1 \
      | awk '/latency average/ {lat=$4} /^tps/ {tps=$3} END {print tps, lat}'
}
labels=("ASYNC (no synchronous standby)"
        "SYNC  remote flush (replica1 has it on disk)"
        "SYNC  remote apply (replica1 can already READ it)")
standby_names=("" "FIRST 1 (replica1)" "FIRST 1 (replica1)")
commit_modes=("on" "on" "remote_apply")
results=$(mktemp)
for round in 1 2 3; do
    for i in 0 1 2; do
        echo "${labels[$i]}|$round|$(bench "${standby_names[$i]}" "${commit_modes[$i]}")" >> "$results"
    done
done
python3 - "$results" <<'PY'
import statistics, sys
rows = [l.rstrip("\n").split("|") for l in open(sys.argv[1])]
order = list(dict.fromkeys(r[0] for r in rows))
base = None
print(f"  {'mode':<50} {'tps per round':<26} {'median tps':>10} {'median latency':>15} {'vs async':>9}")
for mode in order:
    runs = [r for r in rows if r[0] == mode]
    tps = [float(r[2].split()[0]) for r in runs]
    lat = [float(r[2].split()[1]) for r in runs]
    med = statistics.median(tps)
    base = base or med
    print(f"  {mode:<50} {', '.join(f'{t:,.0f}' for t in tps):<26} {med:>10,.0f} {statistics.median(lat):>12.2f} ms {100 * (med / base - 1):>+8.0f}%")
PY
rm -f "$results"
say "-> every synchronous commit pays an extra round trip to replica1 (and, for remote_apply,"
say "   waits for it to replay). Here all containers share one laptop, so the round trip is"
say "   tiny; between data centres it adds the network latency to EVERY commit."
docker exec dist-pg-primary psql -X -q -U owotrust -d owotrust_bank \
    -c "ALTER SYSTEM SET synchronous_standby_names = 'FIRST 1 (replica1)'" \
    -c "ALTER SYSTEM SET synchronous_commit = 'on'" -c "SELECT pg_reload_conf()" > /dev/null

hdr "R7. AVAILABILITY: the synchronous standby fails, and writes BLOCK"
docker stop dist-pg-replica1 > /dev/null && say "replica1 stopped (simulated server failure)"
sleep 1
replication_status
say "A client posts a deposit while the only synchronous standby is down:"
( docker exec dist-pg-primary psql -X -U owotrust -d owotrust_bank \
    -c "SELECT post_deposit('3010000005', 1000, 'REPL-0003');" > "$tmp/r7" 2>&1 ) &
sleep 3
say "3 seconds later the client has had no reply. What the server says that session is doing:"
sql primary "SELECT pid, wait_event_type, wait_event, round(EXTRACT(EPOCH FROM now() - query_start), 1) AS seconds_waiting,
                    left(query, 50) AS query
             FROM pg_stat_activity WHERE wait_event = 'SyncRep';"
say "statement_timeout cannot end this wait: PostgreSQL switches the timer off just before"
say "COMMIT, and the wait happens INSIDE the commit. (A first version of this script relied on"
say "it and waited almost 10 minutes.) An operator or watchdog has to cancel the session:"
sql primary "SELECT pg_cancel_backend(pid) AS cancelled FROM pg_stat_activity WHERE wait_event = 'SyncRep';"
wait
echo "[client] the reply the waiting client finally received:"
sed 's/^/    /' "$tmp/r7"
sql primary "SELECT reference, status FROM bank_transaction WHERE reference = 'REPL-0003';"
say "-> CONSISTENCY was chosen over AVAILABILITY: the primary would not confirm the commit"
say "   without its synchronous copy. The warning matters: the deposit IS committed locally,"
say "   so a client that gave up cannot know whether it happened. It must check by reference"
say "   before retrying, which is why idempotency keys matter (Portfolio 3 D6)."

hdr "R8. QUORUM COMMIT: ANY 1 of the two replicas is enough"
sql primary "ALTER SYSTEM SET synchronous_standby_names = 'ANY 1 (replica1, replica2)';"
sql primary "SELECT pg_reload_conf();"
sleep 1
sql primary "SELECT post_deposit('3010000005', 1000, 'REPL-0004') AS committed_with_replica2_ack;"
replication_status
say "-> with replica1 still down, replica2 acknowledges and writes continue: one failure is"
say "   tolerated without giving up durability."
docker start dist-pg-replica1 > /dev/null
until docker exec dist-pg-replica1 pg_isready -h 127.0.0.1 -q; do sleep 1; done
sleep 2
say "replica1 restarted. Its replication slot kept the WAL it missed, so it catches up on its own:"
replication_status
sql replica1 "SELECT reference FROM bank_transaction WHERE reference LIKE 'REPL-%' ORDER BY reference;"

# leave the cluster in the configuration the failover test expects
docker exec dist-pg-primary psql -X -q -U owotrust -d owotrust_bank \
    -c "ALTER SYSTEM SET synchronous_standby_names = 'FIRST 1 (replica1)'" -c "SELECT pg_reload_conf()" > /dev/null
rm -rf "$tmp"
