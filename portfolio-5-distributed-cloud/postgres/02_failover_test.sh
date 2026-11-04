#!/usr/bin/env bash
# =====================================================================
# OwoTrust Digital Bank (simulated) - Portfolio 5
# postgres/02_failover_test.sh : lose the primary DURING live traffic, promote
#                                the synchronous replica, measure RPO and RTO
#
#  1. A client posts deposits non-stop. Every deposit the primary CONFIRMS
#     is written to an "acknowledged" log on the client side.
#  2. The primary is killed with SIGKILL (no clean shutdown).
#  3. replica1 (the synchronous standby) is promoted to primary.
#  4. RPO check: is every acknowledged deposit present on the new primary?
#  5. RTO: how long from the crash until deposits are accepted again?
#  6. replica2 is re-pointed to follow the new primary.
# Requires: cluster up, cluster_setup.sql loaded, synchronous_standby_names = 'FIRST 1 (replica1)'.
# =====================================================================
set -uo pipefail

sql() {
    local node=$1; shift; local q=$1; shift
    echo "[$node] $(echo "$q" | tr -s ' \n' ' ')"
    docker exec "dist-pg-$node" psql -X -U owotrust -d owotrust_bank "$@" -c "$q" 2>&1 | sed 's/^/    /'
}
hdr() { echo; echo "======================================================================"; echo "$*"; echo "======================================================================"; }
say() { echo "  $*"; }
now_ms() { python3 -c 'import time; print(int(time.time() * 1000))'; }

echo "-- run at $(date '+%Y-%m-%d %H:%M:%S %Z')"

hdr "F1. BEFORE: replica1 is the synchronous standby"
sql primary "SELECT application_name, state, sync_state FROM pg_stat_replication ORDER BY 1;"
sql primary "SHOW synchronous_standby_names;"

hdr "F2. LIVE TRAFFIC: a client posts deposits FO-000001, FO-000002, ... non-stop"
# The client runs inside replica2's container (any machine with psql would do) and
# connects to the primary over the Docker network. A deposit is appended to
# /tmp/acked.txt ONLY when the primary has confirmed its commit.
docker exec dist-pg-replica2 bash -c 'rm -f /tmp/acked.txt /tmp/client.log'
docker exec -d dist-pg-replica2 bash -c '
  for i in $(seq 1 100000); do
    ref=$(printf "FO-%06d" $i)
    if psql -X -q -At -h pg-primary -U owotrust -d owotrust_bank \
         -c "SELECT post_deposit('"'"'3010000001'"'"', 100, '"'"'$ref'"'"')" >/dev/null 2>>/tmp/client.log; then
      echo "$ref" >> /tmp/acked.txt
    else
      echo "$(date +%T.%N | cut -c1-12) client: write $ref FAILED" >> /tmp/client.log; break
    fi
  done'
sleep 4
say "deposits acknowledged so far: $(docker exec dist-pg-replica2 bash -c 'wc -l < /tmp/acked.txt' | tr -d ' ')"

hdr "F3. CRASH: the primary is killed while the client is writing"
t_crash=$(now_ms)
docker kill --signal=SIGKILL dist-pg-primary > /dev/null
say "dist-pg-primary killed at $(date '+%H:%M:%S'); container state: $(docker inspect -f '{{.State.Status}}' dist-pg-primary)"
sleep 1
say "client side (the last lines of its log):"
docker exec dist-pg-replica2 bash -c 'tail -3 /tmp/client.log' | sed 's/^/    /'
acked=$(docker exec dist-pg-replica2 bash -c 'wc -l < /tmp/acked.txt' | tr -d ' ')
last_acked=$(docker exec dist-pg-replica2 bash -c 'tail -1 /tmp/acked.txt')
say "deposits the client was told SUCCEEDED: $acked (last one: $last_acked)"

hdr "F4. FAILOVER: promote replica1 (the synchronous standby) to primary"
sql replica1 "SELECT pg_is_in_recovery() AS still_a_standby;"
sql replica1 "SELECT pg_promote(wait => true) AS promoted;"
until docker exec dist-pg-replica1 psql -X -q -At -U owotrust -d owotrust_bank \
        -c "SELECT post_deposit('3010000001', 100, 'FO-AFTER-FAILOVER')" > /dev/null 2>&1; do sleep 0.2; done
t_writable=$(now_ms)
sql replica1 "SELECT pg_is_in_recovery() AS still_a_standby,
                     pg_walfile_name(pg_current_wal_lsn()) AS current_wal_file,
                     ('x' || substr(pg_walfile_name(pg_current_wal_lsn()), 1, 8))::bit(32)::int AS timeline;"
say "-> the first 8 hex digits of the WAL file name are the TIMELINE: promotion started timeline 2,"
say "   so WAL written after the failover can never be confused with the old primary's."
say "RTO (crash -> first deposit accepted by the new primary): $(( t_writable - t_crash )) ms"
say "    (promotion here is triggered by this script straight away. In production a tool such as"
say "     Patroni must first DETECT the failure, typically after 10-30 s of missed heartbeats.)"

hdr "F5. RPO CHECK: is every acknowledged deposit on the new primary?"
docker exec dist-pg-replica2 bash -c 'cat /tmp/acked.txt' > /tmp/owotrust_acked.txt
docker cp /tmp/owotrust_acked.txt dist-pg-replica1:/tmp/acked.txt > /dev/null
rm -f /tmp/owotrust_acked.txt
sql replica1 "CREATE TEMP TABLE acked (reference text);
              COPY acked FROM '/tmp/acked.txt';
              SELECT (SELECT COUNT(*) FROM acked) AS acknowledged_to_client,
                     (SELECT COUNT(*) FROM acked a JOIN bank_transaction t ON t.reference = a.reference) AS present_on_new_primary,
                     (SELECT COUNT(*) FROM acked a WHERE NOT EXISTS
                         (SELECT 1 FROM bank_transaction t WHERE t.reference = a.reference)) AS LOST,
                     (SELECT COUNT(*) FROM bank_transaction WHERE reference LIKE 'FO-0%') AS fo_rows_on_new_primary;"
say "-> LOST = 0: no deposit that a customer was told had succeeded has disappeared (RPO = 0)."
say "   If fo_rows_on_new_primary is one more than acknowledged, that deposit committed but its"
say "   confirmation never reached the client: exactly the case idempotent retries must handle."
say "Balance check on the new primary (stored balance vs transaction history):"
sql replica1 "SELECT COUNT(*) AS accounts_where_balance_does_not_match_history
              FROM account a
              LEFT JOIN (SELECT account_id, SUM(delta) AS derived
                         FROM (SELECT credit_account_id AS account_id, amount AS delta FROM bank_transaction
                               WHERE status IN ('COMPLETED','REVERSED') AND credit_account_id IS NOT NULL
                               UNION ALL
                               SELECT debit_account_id, -amount FROM bank_transaction
                               WHERE status IN ('COMPLETED','REVERSED') AND debit_account_id IS NOT NULL) l
                         GROUP BY account_id) d ON d.account_id = a.account_id
              WHERE a.balance <> COALESCE(d.derived, 0);"
say "What the ASYNCHRONOUS replica2 had received when the primary died (it may be behind):"
sql replica2 "SELECT COUNT(*) AS fo_rows_on_replica2 FROM bank_transaction WHERE reference LIKE 'FO-0%';"

hdr "F6. RECONFIGURE: replica2 follows the new primary"
sql replica1 "SELECT pg_create_physical_replication_slot('replica2_slot');"
sql replica2 "ALTER SYSTEM SET primary_conninfo = 'host=pg-replica1 port=5432 user=replicator password=replicator_dev application_name=replica2';"
sql replica2 "SELECT pg_reload_conf();"
for _ in $(seq 1 30); do
    state=$(docker exec dist-pg-replica1 psql -X -At -U owotrust -d owotrust_bank \
            -c "SELECT state FROM pg_stat_replication WHERE application_name = 'replica2'")
    [ "$state" = streaming ] && break; sleep 1
done
sql replica1 "SELECT application_name, state, sync_state FROM pg_stat_replication;"
sql replica1 "SELECT post_deposit('3010000001', 100, 'FO-NEW-TIMELINE') AS written_on_new_primary;"
sleep 1
sql replica2 "SELECT reference FROM bank_transaction WHERE reference IN ('FO-AFTER-FAILOVER', 'FO-NEW-TIMELINE') ORDER BY 1;"
say "-> replica2 switched to the new timeline and replicates from replica1. The old primary"
say "   cannot simply restart: its WAL may contain un-replicated changes, so it must be rebuilt"
say "   with pg_rewind or a fresh pg_basebackup before rejoining as a standby."
say "   New primary: replica1 has no synchronous standby, so RPO is again > 0 until one is added."
